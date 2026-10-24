#!/usr/bin/env bash
# ============================================================================
#  clean.sh - Supprime les artefacts de compilation (dossier build)
# ============================================================================
set -euo pipefail

cd "$(dirname "$0")"

rm -rf build
echo "[OK] Dossier build supprime."
