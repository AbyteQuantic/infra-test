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

// eventMsg es el evento que entra por la API. El id lo pone el cliente y es la
// clave de idempotencia (SQS reentrega el mismo cuerpo, así que no cambia).
type eventMsg struct {
	ID        string          `json:"id"`
	Type      string          `json:"type"`
	ForceFail bool            `json:"forceFail"` // demo: fuerza un fallo
	Payload   json.RawMessage `json:"payload"`
}

// parseEvent valida el cuerpo. JSON inválido o sin id = veneno (va a la DLQ).
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

// store abstrae DynamoDB para testear sin nube.
type store interface {
	// putIfNew escribe solo si el id no existía. isNew=false si era duplicado.
	putIfNew(ctx context.Context, m eventMsg) (isNew bool, err error)
}

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

	// attribute_not_exists(id) hace la escritura idempotente: si el id ya está,
	// DynamoDB rechaza el PutItem en vez de pisarlo. Atómico.
	_, err = s.client.PutItem(ctx, &dynamodb.PutItemInput{
		TableName:           aws.String(s.table),
		Item:                item,
		ConditionExpression: aws.String("attribute_not_exists(id)"),
	})
	if err != nil {
		var ccf *types.ConditionalCheckFailedException
		if errors.As(err, &ccf) {
			return false, nil // ya existía
		}
		return false, err
	}
	return true, nil
}

// processOne es la lógica de negocio; no sabe nada de SQS ni de Lambda.
func processOne(ctx context.Context, body string, s store) error {
	m, err := parseEvent(body)
	if err != nil {
		return err // veneno -> DLQ
	}

	// Fallo simulado para la demo. Va antes de escribir para que cada reintento
	// vuelva a fallar y termine en la DLQ.
	if m.ForceFail {
		return fmt.Errorf("forceFail activo para el evento %s", m.ID)
	}

	isNew, err := s.putIfNew(ctx, m)
	if err != nil {
		// Error transitorio (p.ej. throttling): devolvemos error para reintentar.
		return fmt.Errorf("error guardando el evento %s: %w", m.ID, err)
	}
	if !isNew {
		log.Printf("evento %s ya estaba procesado, lo ignoro (idempotencia)", m.ID)
		return nil
	}

	log.Printf("evento %s procesado y guardado", m.ID)
	return nil
}

// processor se inicializa una vez en el arranque en frío.
var processor store

// handler procesa eventos de SQS con fallo parcial por mensaje
// (ReportBatchItemFailures): solo el mensaje que falla vuelve a la cola.
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
