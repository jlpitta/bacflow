#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Instalando nextassembler-tools..."
mamba env create -f "${SCRIPT_DIR}/envs/tools.yaml" --yes || \
    mamba env update -f "${SCRIPT_DIR}/envs/tools.yaml" --prune

echo "==> Instalando nextassembler-medaka..."
mamba env create -f "${SCRIPT_DIR}/envs/medaka.yaml" --yes || \
    mamba env update -f "${SCRIPT_DIR}/envs/medaka.yaml" --prune

echo ""
echo "Ambientes instalados:"
mamba env list | grep -E 'nextassembler'
echo ""
echo "Pronto. Execute o pipeline com:"
echo "  nextflow run ${SCRIPT_DIR}/nextassembler.nf --help"
