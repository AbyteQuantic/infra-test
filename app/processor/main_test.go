package main

import (
	"context"
	"errors"
	"testing"

	"github.com/aws/aws-lambda-go/events"
)

// fakeStore es un store en memoria para testear processOne sin tocar AWS.
type fakeStore struct {
	seen    map[string]bool
	failPut bool
}

func newFakeStore() *fakeStore { return &fakeStore{seen: map[string]bool{}} }

func (f *fakeStore) putIfNew(_ context.Context, m eventMsg) (bool, error) {
	if f.failPut {
		return false, errors.New("dynamodb caído")
	}
	if f.seen[m.ID] {
		return false, nil // duplicado
	}
	f.seen[m.ID] = true
	return true, nil
}

func TestParseEvent(t *testing.T) {
	tests := []struct {
		name    string
		body    string
		wantErr bool
	}{
		{"válido", `{"id":"1","type":"t"}`, false},
		{"json inválido", `{nope`, true},
		{"sin id es veneno", `{"type":"t"}`, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := parseEvent(tt.body)
			if (err != nil) != tt.wantErr {
				t.Fatalf("parseEvent() err=%v, wantErr=%v", err, tt.wantErr)
			}
		})
	}
}

func TestProcessOne(t *testing.T) {
	ctx := context.Background()

	t.Run("evento nuevo se procesa y se guarda", func(t *testing.T) {
		s := newFakeStore()
		if err := processOne(ctx, `{"id":"a","type":"t"}`, s); err != nil {
			t.Fatalf("no esperaba error: %v", err)
		}
		if !s.seen["a"] {
			t.Fatal("debió guardar el evento")
		}
	})

	t.Run("mismo id dos veces es idempotente", func(t *testing.T) {
		s := newFakeStore()
		_ = processOne(ctx, `{"id":"a"}`, s)
		if err := processOne(ctx, `{"id":"a"}`, s); err != nil {
			t.Fatalf("un duplicado no debe fallar: %v", err)
		}
	})

	t.Run("forceFail devuelve error y no guarda (irá a la DLQ)", func(t *testing.T) {
		s := newFakeStore()
		if err := processOne(ctx, `{"id":"a","forceFail":true}`, s); err == nil {
			t.Fatal("esperaba error por forceFail")
		}
		if s.seen["a"] {
			t.Fatal("no debió guardar un evento marcado como forceFail")
		}
	})

	t.Run("veneno sin id devuelve error", func(t *testing.T) {
		s := newFakeStore()
		if err := processOne(ctx, `{"type":"t"}`, s); err == nil {
			t.Fatal("esperaba error por falta de id")
		}
	})

	t.Run("error del store se propaga para reintentar", func(t *testing.T) {
		s := newFakeStore()
		s.failPut = true
		if err := processOne(ctx, `{"id":"a"}`, s); err == nil {
			t.Fatal("esperaba que el error del store se propagara")
		}
	})
}

// TestHandler verifica el fallo parcial por lote: en un lote de 2, el bueno
// sale bien y solo el malo se reporta como fallido (vuelve a la cola).
func TestHandler(t *testing.T) {
	processor = newFakeStore() // inyecta el store de prueba en el global

	evt := events.SQSEvent{
		Records: []events.SQSMessage{
			{MessageId: "ok", Body: `{"id":"ok-1"}`},
			{MessageId: "malo", Body: `{"id":"malo-1","forceFail":true}`},
		},
	}

	resp, err := handler(context.Background(), evt)
	if err != nil {
		t.Fatalf("el handler no debe devolver error: %v", err)
	}
	if len(resp.BatchItemFailures) != 1 {
		t.Fatalf("esperaba 1 fallo parcial, hubo %d", len(resp.BatchItemFailures))
	}
	if resp.BatchItemFailures[0].ItemIdentifier != "malo" {
		t.Fatalf("el fallo reportado debió ser 'malo', fue %q", resp.BatchItemFailures[0].ItemIdentifier)
	}
}
