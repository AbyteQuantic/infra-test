package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/feature/dynamodb/attributevalue"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
)

// eventMsg es el contrato del evento que entra por la API.
// El cliente DEBE mandar un "id" estable: es la clave de idempotencia.
// Como SQS reentrega el mismo cuerpo en cada reintento, ese id no cambia,
// así que podemos detectar duplicados sin problemas.
type eventMsg struct {
	ID        string          `json:"id"`
	Type      string          `json:"type"`
	ForceFail bool            `json:"forceFail"` // solo para la demo: fuerza un fallo
	Payload   json.RawMessage `json:"payload"`
}

// parseEvent valida el cuerpo del mensaje. Un cuerpo que no es JSON o que
// no trae "id" es "veneno": nunca se va a poder procesar bien, así que lo
// dejamos fallar a propósito para que SQS lo termine mandando a la DLQ.
func parseEvent(body string) (eventMsg, error) {
	var m eventMsg
	if err := json.Unmarshal([]byte(body), &m); err != nil {
		return m, fmt.Errorf("el cuerpo no es JSON válido: %w", err)
	}
	if m.ID == "" {
		return m, errors.New("falta el campo 'id' (necesario para idempotencia)")
	}
	return m, nil
}

// store abstrae DynamoDB para poder testear la lógica sin tocar la nube.
type store interface {
	// putIfNew escribe el evento solo si el id no existía todavía.
	// Devuelve isNew=false cuando el id ya estaba (es un duplicado).
	putIfNew(ctx context.Context, m eventMsg) (isNew bool, err error)
}

// ddbStore es la implementación real contra DynamoDB.
type ddbStore struct {
	client *dynamodb.Client
	table  string
}

func (s *ddbStore) putIfNew(ctx context.Context, m eventMsg) (bool, error) {
	item, err := attributevalue.MarshalMap(map[string]any{
		"id":          m.ID,
		"type":        m.Type,
		"payload":     string(m.Payload),
		"processedAt": time.Now().UTC().Format(time.RFC3339),
	})
	if err != nil {
		return false, err
	}

	// La condición attribute_not_exists(id) es lo que hace la escritura
	// idempotente: si el id ya está, DynamoDB rechaza el PutItem en vez de
	// pisar el dato. Es atómico, sin race conditions.
	_, err = s.client.PutItem(ctx, &dynamodb.PutItemInput{
		TableName:           aws.String(s.table),
		Item:                item,
		ConditionExpression: aws.String("attribute_not_exists(id)"),
	})
	if err != nil {
		var ccf *types.ConditionalCheckFailedException
		if errors.As(err, &ccf) {
			return false, nil // ya existía -> duplicado, todo bien
		}
		return false, err
	}
	return true, nil
}

// processOne tiene TODA la lógica de negocio y es la función que testeamos.
// Recibe el cuerpo del mensaje y el store; no sabe nada de SQS ni de Lambda.
func processOne(ctx context.Context, body string, s store) error {
	m, err := parseEvent(body)
	if err != nil {
		return err // veneno -> terminará en la DLQ
	}

	// Simulación de fallo para la demo (reintentos -> DLQ).
	// Va ANTES de escribir en la base a propósito: así cada reintento vuelve
	// a fallar y el mensaje termina en la DLQ, en vez de "auto-curarse".
	if m.ForceFail {
		return fmt.Errorf("forceFail activo para el evento %s", m.ID)
	}

	isNew, err := s.putIfNew(ctx, m)
	if err != nil {
		// Error transitorio (p.ej. DynamoDB con throttling): devolvemos error
		// para que SQS reintente. Si se vuelve permanente, cae en la DLQ.
		return fmt.Errorf("error guardando el evento %s: %w", m.ID, err)
	}
	if !isNew {
		log.Printf("evento %s ya estaba procesado, lo ignoro (idempotencia)", m.ID)
		return nil
	}

	log.Printf("evento %s procesado y guardado", m.ID)
	return nil
}

// processor es el store real; se inicializa una sola vez en el arranque en frío.
var processor store

// handler es el punto de entrada de Lambda para eventos de SQS.
// Usa ReportBatchItemFailures: si un mensaje del lote falla, solo ese vuelve
// a la cola, no todo el lote. Evita reprocesar mensajes que ya salieron bien.
func handler(ctx context.Context, e events.SQSEvent) (events.SQSEventResponse, error) {
	var resp events.SQSEventResponse
	for _, rec := range e.Records {
		if err := processOne(ctx, rec.Body, processor); err != nil {
			log.Printf("fallo procesando messageId=%s: %v", rec.MessageId, err)
			resp.BatchItemFailures = append(resp.BatchItemFailures, events.SQSBatchItemFailure{
				ItemIdentifier: rec.MessageId,
			})
		}
	}
	return resp, nil
}

func main() {
	cfg, err := config.LoadDefaultConfig(context.Background())
	if err != nil {
		log.Fatalf("no pude cargar la config de AWS: %v", err)
	}
	processor = &ddbStore{
		client: dynamodb.NewFromConfig(cfg),
		table:  os.Getenv("TABLE_NAME"),
	}
	lambda.Start(handler)
}
