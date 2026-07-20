#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# detecta gerenciador de pacotes disponível
if command -v mamba &>/dev/null; then
    PKG=mamba
elif command -v micromamba &>/dev/null; then
    PKG=micromamba
elif command -v conda &>/dev/null; then
    PKG=conda
else
    echo "ERRO: nenhum gerenciador conda encontrado (mamba, micromamba ou conda)."
    echo "Instale o Miniforge: https://github.com/conda-forge/miniforge"
    exit 1
fi

echo "==> Usando: ${PKG}"

echo "==> Instalando bacflow-tools..."
${PKG} env create -f "${SCRIPT_DIR}/envs/tools.yaml" --yes || \
    ${PKG} env update -f "${SCRIPT_DIR}/envs/tools.yaml" --prune

echo "==> Instalando bacflow-medaka..."
${PKG} env create -f "${SCRIPT_DIR}/envs/medaka.yaml" --yes || \
    ${PKG} env update -f "${SCRIPT_DIR}/envs/medaka.yaml" --prune

echo "==> Instalando bacflow-checkm2..."
${PKG} env create -f "${SCRIPT_DIR}/envs/checkm2.yaml" --yes || \
    ${PKG} env update -f "${SCRIPT_DIR}/envs/checkm2.yaml" --prune

CHECKM2_DB="${HOME}/checkm2_db/CheckM2_database/uniref100.KO.1.dmnd"
if [ -f "${CHECKM2_DB}" ]; then
    echo "==> Banco de dados do CheckM2 já presente em ${CHECKM2_DB}, pulando download."
else
    echo "==> Baixando banco de dados do CheckM2 (~1.7 GB, uma vez só)..."
    ${PKG} run -n bacflow-checkm2 checkm2 database --download --path "${HOME}/checkm2_db"
fi

echo ""
echo "Ambientes instalados:"
${PKG} env list | grep -E 'bacflow'
echo ""
echo "Para usar o nextflow instalado no ambiente, adicione ao seu ~/.bashrc:"
echo "  alias nextflow='${PKG} run -n bacflow-tools nextflow'"
echo ""
echo "Ou ative o ambiente manualmente antes de rodar:"
echo "  ${PKG} activate bacflow-tools"
echo ""
echo "Pronto. Execute o pipeline com:"
echo "  nextflow run ${SCRIPT_DIR}/bacflow.nf --help"
