#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Mesmo banner do bacflow.nf/README — texto puro, sem cores ANSI.
cat <<'BANNER'

██████╗   █████╗   ██████╗ ███████╗ ██╗       ██████╗  ██╗    ██╗
██╔══██╗ ██╔══██╗ ██╔════╝ ██╔════╝ ██║      ██╔═══██╗ ██║    ██║
██████╔╝ ███████║ ██║      █████╗   ██║      ██║   ██║ ██║ █╗ ██║
██╔══██╗ ██╔══██║ ██║      ██╔══╝   ██║      ██║   ██║ ██║███╗██║
██████╔╝ ██║  ██║ ╚██████╗ ██║      ███████╗ ╚██████╔╝ ╚███╔███╔╝
╚═════╝  ╚═╝  ╚═╝  ╚═════╝ ╚═╝      ╚══════╝  ╚═════╝   ╚══╝╚══╝

                                by João Pitta and Beatriz Toscano

BANNER
echo "Instalador de ambientes"
echo ""

TOTAL_STEPS=4
CURRENT_STEP=0
CURRENT_STEP_NAME=""
STEP_START_TS=0
INSTALL_START=$(date +%s)

on_error() {
    echo ""
    echo "✗ Falhou na etapa [${CURRENT_STEP}/${TOTAL_STEPS}]: ${CURRENT_STEP_NAME}"
    exit 1
}
trap on_error ERR

step_start() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    CURRENT_STEP_NAME="$1"
    STEP_START_TS=$(date +%s)
    echo "==> [${CURRENT_STEP}/${TOTAL_STEPS}] ${CURRENT_STEP_NAME}..."
}

step_end() {
    local elapsed=$(( $(date +%s) - STEP_START_TS ))
    printf "    concluído em %02d:%02d\n" $((elapsed / 60)) $((elapsed % 60))
}

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

echo "Usando: ${PKG}"
echo ""

step_start "Instalando bacflow-tools"
${PKG} env create -f "${SCRIPT_DIR}/envs/tools.yaml" --yes || \
    ${PKG} env update -f "${SCRIPT_DIR}/envs/tools.yaml" --prune
step_end

step_start "Instalando bacflow-medaka"
${PKG} env create -f "${SCRIPT_DIR}/envs/medaka.yaml" --yes || \
    ${PKG} env update -f "${SCRIPT_DIR}/envs/medaka.yaml" --prune
step_end

step_start "Instalando bacflow-checkm2"
${PKG} env create -f "${SCRIPT_DIR}/envs/checkm2.yaml" --yes || \
    ${PKG} env update -f "${SCRIPT_DIR}/envs/checkm2.yaml" --prune
step_end

CHECKM2_DB="${HOME}/checkm2_db/CheckM2_database/uniref100.KO.1.dmnd"
if [ -f "${CHECKM2_DB}" ]; then
    step_start "Banco de dados do CheckM2"
    echo "    já presente em ${CHECKM2_DB}, pulando download."
    step_end
else
    step_start "Baixando banco de dados do CheckM2 (~1.7 GB, uma vez só)"
    ${PKG} run -n bacflow-checkm2 checkm2 database --download --path "${HOME}/checkm2_db"
    step_end
fi

TOTAL_ELAPSED=$(( $(date +%s) - INSTALL_START ))
echo ""
printf "Instalação concluída em %02d:%02d\n" $((TOTAL_ELAPSED / 60)) $((TOTAL_ELAPSED % 60))
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
