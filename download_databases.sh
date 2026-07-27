#!/usr/bin/env bash
# Baixa CheckM2/Bakta/GTDB-Tk em sequência, sem bloquear o install_envs.sh que
# o dispara em background (nohup + disown). Idempotente: cada base marca
# db_status/<nome>.done ao terminar, e é pulada se o marcador já existir.
# Pode ser rodado sozinho também (ex: pra retomar depois de uma falha).
set -uo pipefail
# Sem 'set -e' de propósito: cada bloco trata a própria falha via retry_cmd,
# e a falha de uma base não deve abortar as outras da cadeia.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_STATUS_DIR="${SCRIPT_DIR}/db_status"
mkdir -p "${DB_STATUS_DIR}"

source "${HOME}/miniforge3/etc/profile.d/conda.sh"

retry_cmd() {
    local max_attempts=3
    local delay=20
    local attempt=1
    while true; do
        if "$@"; then
            return 0
        fi
        if [ "${attempt}" -ge "${max_attempts}" ]; then
            echo "    falhou após ${max_attempts} tentativas: $*"
            return 1
        fi
        echo "    tentativa ${attempt}/${max_attempts} falhou, tentando de novo em ${delay}s: $*"
        sleep "${delay}"
        attempt=$((attempt + 1))
    done
}

CHECKM2_DB="${HOME}/checkm2_db/CheckM2_database/uniref100.KO.1.dmnd"
BAKTA_DB="${HOME}/bakta_db/db"
GTDBTK_DIR="${HOME}/gtdbtk_db"

echo "=== $(date -Iseconds) — CheckM2 ==="
if [ -f "${DB_STATUS_DIR}/checkm2.done" ]; then
    echo "    já concluído, pulando."
elif [ -f "${CHECKM2_DB}" ]; then
    echo "    banco já presente em ${CHECKM2_DB}, marcando sem baixar de novo."
    touch "${DB_STATUS_DIR}/checkm2.done"
else
    conda activate bacflow-checkm2
    if retry_cmd checkm2 database --download --path "${HOME}/checkm2_db"; then
        touch "${DB_STATUS_DIR}/checkm2.done"
        echo "    concluído."
    fi
    conda deactivate
fi

echo "=== $(date -Iseconds) — Bakta ==="
if [ -f "${DB_STATUS_DIR}/bakta.done" ]; then
    echo "    já concluído, pulando."
elif [ -d "${BAKTA_DB}" ] && [ -n "$(ls -A "${BAKTA_DB}" 2>/dev/null)" ]; then
    echo "    banco já presente em ${BAKTA_DB}, marcando sem baixar de novo."
    touch "${DB_STATUS_DIR}/bakta.done"
else
    conda activate bacflow-bakta
    if retry_cmd bakta_db download --output "${HOME}/bakta_db" --type full; then
        touch "${DB_STATUS_DIR}/bakta.done"
        echo "    concluído."
    fi
    conda deactivate
fi

echo "=== $(date -Iseconds) — GTDB-Tk ==="
if [ -f "${DB_STATUS_DIR}/gtdbtk.done" ]; then
    echo "    já concluído, pulando."
elif [ -d "${GTDBTK_DIR}" ] && [ -n "$(find "${GTDBTK_DIR}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)" ]; then
    # Não sabemos de antemão o nome exato da pasta que o tarball extrai (varia
    # por release) — checa por qualquer subdiretório real (não só o .tar.gz
    # baixado) como sinal de que já foi extraído antes.
    echo "    banco já parece extraído em ${GTDBTK_DIR}, marcando sem baixar de novo."
    touch "${DB_STATUS_DIR}/gtdbtk.done"
else
    GTDBTK_URL="https://data.gtdb.ecogenomic.org/releases/latest/auxillary_files/gtdbtk_package/full_package/gtdbtk_data.tar.gz"
    GTDBTK_TARBALL="${GTDBTK_DIR}/gtdbtk_data.tar.gz"
    mkdir -p "${GTDBTK_DIR}"

    download_ok=0
    if command -v aria2c &>/dev/null; then
        retry_cmd aria2c -x16 -s16 -k1M -c -d "${GTDBTK_DIR}" -o gtdbtk_data.tar.gz "${GTDBTK_URL}" && download_ok=1
    else
        echo "    aria2c não encontrado — usando wget -c (mais lento, sem paralelismo)."
        retry_cmd wget -c -O "${GTDBTK_TARBALL}" "${GTDBTK_URL}" && download_ok=1
    fi

    if [ "${download_ok}" = "1" ]; then
        echo "    download concluído, descompactando com pigz..."
        if pigz -dc -p "$(nproc)" "${GTDBTK_TARBALL}" | tar xf - -C "${GTDBTK_DIR}"; then
            rm -f "${GTDBTK_TARBALL}"
            touch "${DB_STATUS_DIR}/gtdbtk.done"
            echo "    concluído."
        else
            echo "    falha na descompactação — tarball mantido em ${GTDBTK_TARBALL} pra não perder o download."
        fi
    fi
fi

echo "=== $(date -Iseconds) — downloads finalizados ==="
