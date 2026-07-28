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

TOTAL_STEPS=6
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

step_start "Instalando bacflow-bakta"
${PKG} env create -f "${SCRIPT_DIR}/envs/bakta.yaml" --yes || \
    ${PKG} env update -f "${SCRIPT_DIR}/envs/bakta.yaml" --prune
step_end

step_start "Instalando bacflow-gtdbtk"
${PKG} env create -f "${SCRIPT_DIR}/envs/gtdbtk.yaml" --yes || \
    ${PKG} env update -f "${SCRIPT_DIR}/envs/gtdbtk.yaml" --prune
step_end

# Bancos de dados (CheckM2 ~1.7GB, Bakta ~84GB, GTDB-Tk ~94GB) são grandes
# demais pra bloquear a instalação aqui — download_databases.sh roda em
# background (nohup + disown, sobrevive à sessão SSH terminar) e marca cada
# base concluída em db_status/<nome>.done, que o bacflow.nf confere antes de
# rodar. Idempotente: já rodou antes e a base já está lá → marca na hora,
# sem baixar de novo.
step_start "Disparando downloads de bancos em background (CheckM2/Bakta/GTDB-Tk)"
mkdir -p "${SCRIPT_DIR}/logs" "${SCRIPT_DIR}/db_status"
chmod +x "${SCRIPT_DIR}/download_databases.sh"
nohup bash "${SCRIPT_DIR}/download_databases.sh" > "${SCRIPT_DIR}/logs/db_downloads.log" 2>&1 &
disown
step_end
echo "    em background — acompanhar com: tail -f ${SCRIPT_DIR}/logs/db_downloads.log"
echo "    ver o que já terminou: ls ${SCRIPT_DIR}/db_status/"

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
echo "IMPORTANTE: os bancos de dados (CheckM2/Bakta/GTDB-Tk) continuam baixando"
echo "em background — a instalação dos ambientes terminou, mas o pipeline só"
echo "roda de fato quando db_status/checkm2.done e db_status/bakta.done existirem"
echo "(o bacflow.nf verifica isso antes de começar e avisa com uma mensagem clara"
echo "se algum ainda estiver faltando, em vez de quebrar no meio de um processo)."
echo ""
echo "Pronto. Execute o pipeline com:"
echo "  nextflow run ${SCRIPT_DIR}/bacflow.nf --help"
