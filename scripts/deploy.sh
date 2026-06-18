#!/usr/bin/env bash
set -euo pipefail

# Levanta todo de cero: compila el Lambda y aplica el Terraform.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

"$ROOT/scripts/build.sh"

cd "$ROOT/infra"
terraform init
terraform apply

echo
echo "Endpoint de ingesta:"
terraform output -raw events_endpoint
echo
