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

TOTAL_STEPS=7
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

# detecta gerenciador de pacotes disponível; se nenhum existir, baixa e
# instala o Miniforge silenciosamente (sem sudo, sem prompts) em vez de
# abortar — cobre o caso de servidor novo/limpo sem conda pré-instalado.
BOOTSTRAPPED_MINIFORGE=false
MINIFORGE_PREFIX="${HOME}/miniforge3"

if command -v mamba &>/dev/null; then
    PKG=mamba
elif command -v micromamba &>/dev/null; then
    PKG=micromamba
elif command -v conda &>/dev/null; then
    PKG=conda
elif [ -x "${MINIFORGE_PREFIX}/bin/mamba" ]; then
    # instalado em execução anterior desta mesma máquina, mas fora do PATH
    PKG="${MINIFORGE_PREFIX}/bin/mamba"
else
    echo "Nenhum gerenciador conda encontrado (mamba, micromamba ou conda)."
    echo "Baixando e instalando o Miniforge em ${MINIFORGE_PREFIX} (sem sudo, sem prompts)..."
    echo ""

    MINIFORGE_TMP="$(mktemp -d)"
    MINIFORGE_INSTALLER="${MINIFORGE_TMP}/Miniforge3.sh"
    MINIFORGE_URL="https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-$(uname -s)-$(uname -m).sh"

    curl -fsSL -o "${MINIFORGE_INSTALLER}" "${MINIFORGE_URL}"
    bash "${MINIFORGE_INSTALLER}" -b -p "${MINIFORGE_PREFIX}"
    rm -rf "${MINIFORGE_TMP}"

    PKG="${MINIFORGE_PREFIX}/bin/mamba"
    BOOTSTRAPPED_MINIFORGE=true
    echo ""
    echo "Miniforge instalado em ${MINIFORGE_PREFIX}."
fi

echo "Usando: ${PKG}"
echo ""

# Envs self-contained dentro do próprio repo (${SCRIPT_DIR}/envs/bacflow-X),
# em vez de nomeados na instalação global de conda -- não depende de o
# gerenciador do usuário ser miniforge (~/miniforge3) ou outra distribuição
# (ex. ~/anaconda3): os módulos referenciam o env via "${projectDir}/envs/
# bacflow-X" (variável implícita do Nextflow), então funciona igual em
# qualquer conta, independente do que já está instalado em $HOME.
ENVS_DIR="${SCRIPT_DIR}/envs"

create_or_update_env() {
    local name="$1"
    local yaml="$2"
    local prefix="${ENVS_DIR}/${name}"
    ${PKG} create --prefix "${prefix}" -f "${yaml}" --yes || \
        ${PKG} env update --prefix "${prefix}" -f "${yaml}" --prune
}

step_start "Instalando bacflow-tools"
create_or_update_env "bacflow-tools" "${SCRIPT_DIR}/envs/tools.yaml"
step_end

step_start "Instalando bacflow-medaka"
create_or_update_env "bacflow-medaka" "${SCRIPT_DIR}/envs/medaka.yaml"
step_end

step_start "Instalando bacflow-checkm2"
create_or_update_env "bacflow-checkm2" "${SCRIPT_DIR}/envs/checkm2.yaml"
step_end

step_start "Instalando bacflow-bakta"
create_or_update_env "bacflow-bakta" "${SCRIPT_DIR}/envs/bakta.yaml"
step_end

step_start "Instalando bacflow-gtdbtk"
create_or_update_env "bacflow-gtdbtk" "${SCRIPT_DIR}/envs/gtdbtk.yaml"
step_end

# abricate ships its reference databases (incl. vfdb) bundled inside the
# conda package itself -- --setupdb just runs makeblastdb on the bundled
# fasta files, entirely local/offline, no separate download step needed
# (unlike CheckM2/Bakta/GTDB-Tk below).
step_start "Instalando bacflow-abricate"
create_or_update_env "bacflow-abricate" "${SCRIPT_DIR}/envs/abricate.yaml"
${PKG} run --prefix "${ENVS_DIR}/bacflow-abricate" abricate --setupdb
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
echo "Ambientes instalados (self-contained, dentro do repo):"
ls -1 "${ENVS_DIR}" | grep -E '^bacflow-' | sed "s|^|  ${ENVS_DIR}/|"
echo ""
echo "Para usar o nextflow instalado no ambiente, adicione ao seu ~/.bashrc:"
echo "  alias nextflow='${PKG} run -p ${ENVS_DIR}/bacflow-tools nextflow'"
echo ""
if [ "${BOOTSTRAPPED_MINIFORGE}" = true ]; then
    echo "Miniforge foi instalado agora, sem 'conda init' (instalação silenciosa) —"
    echo "'${PKG} activate ${ENVS_DIR}/bacflow-tools' direto no shell atual não vai funcionar ainda."
    echo "Use o alias acima (não exige ativação), ou rode uma vez:"
    echo "  ${MINIFORGE_PREFIX}/bin/conda init bash && exec bash"
    echo "para poder usar 'conda activate' normalmente depois."
    echo ""
else
    echo "Ou ative o ambiente manualmente antes de rodar:"
    echo "  ${PKG} activate ${ENVS_DIR}/bacflow-tools"
    echo ""
fi
echo "IMPORTANTE: os bancos de dados (CheckM2/Bakta/GTDB-Tk) continuam baixando"
echo "em background — a instalação dos ambientes terminou, mas o pipeline só"
echo "roda de fato quando db_status/checkm2.done e db_status/bakta.done existirem"
echo "(o bacflow.nf verifica isso antes de começar e avisa com uma mensagem clara"
echo "se algum ainda estiver faltando, em vez de quebrar no meio de um processo)."
echo ""
echo "Pronto. Execute o pipeline com:"
echo "  nextflow run ${SCRIPT_DIR}/bacflow.nf --help"
