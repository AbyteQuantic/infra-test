#!/usr/bin/env bash
set -euo pipefail

# Destruye TODO lo creado. Déjalo correr al terminar para no dejar nada
# facturable colgando.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/infra"
terraform destroy
