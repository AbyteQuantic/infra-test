#!/usr/bin/env bash
set -euo pipefail

# Compila el Lambda de Go (linux/arm64) y lo empaqueta en un zip.
# El binario DEBE llamarse "bootstrap" porque usamos el runtime provided.al2023.

cd "$(dirname "$0")/../app/processor"

echo "==> go mod tidy"
go mod tidy

echo "==> go vet"
go vet ./...

echo "==> go test (con cobertura)"
go test ./... -cover

echo "==> compilando bootstrap (linux/arm64)"
mkdir -p build
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -tags lambda.norpc -o build/bootstrap .

echo "==> empaquetando zip"
cd build
zip -j processor.zip bootstrap >/dev/null

echo "OK -> app/processor/build/processor.zip"
