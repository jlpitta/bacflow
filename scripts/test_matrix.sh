#!/usr/bin/env bash
# By João Pitta (jlpitta82@gmail.com) and Beatriz Toscano (beatriz.melo@fiocruz.br)
# At Fiocruz-PE
#
# Regression suite covering the bacflow flow matrix: denovo/reference mode,
# hybrid/long-only/short-only samples, each polisher, racon on/off, the
# pacbio (no-Medaka) path, and both CLI and --samplesheet input. Born out of
# a real bug (v0.9.1) that only surfaced because a long-read-only run had
# never been exercised manually — this script exists so the next latent bug
# like that gets caught here instead of in a real run.
#
# Runs sequentially so one crashing test can't corrupt another's work/output
# dirs, and keeps going past a failing test by default so a single bug
# doesn't hide the rest of the matrix. Pass --stop-on-fail to abort instead.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

THREADS="${THREADS:-32}"
STOP_ON_FAIL=0
[[ "${1:-}" == "--stop-on-fail" ]] && STOP_ON_FAIL=1

LOG_DIR="test_matrix_logs"
mkdir -p "$LOG_DIR"
SUMMARY="$LOG_DIR/SUMMARY.md"

LONG="genome_test/staphylococcus_aureus_real/long_reads.fastq.gz"
SR1="genome_test/staphylococcus_aureus_real/short_reads_1.fastq.gz"
SR2="genome_test/staphylococcus_aureus_real/short_reads_2.fastq.gz"
REF="genome_test/staphylococcus_aureus_real/reference.fasta"
GSIZE="2.8m"
SS_DENOVO="scripts/test_matrix_samplesheets/denovo_mixed.csv"
SS_REFERENCE="scripts/test_matrix_samplesheets/reference_mixed.csv"

source "$HOME/miniforge3/etc/profile.d/conda.sh"
conda activate bacflow-tools

declare -a TEST_IDS=(D1 D2 D3 D4 D5 D6 D7 D8 D9 D10 R1 R2 R3 R4 R5 R6 S1 S2 S3)
declare -A TEST_DESC=(
  [D1]="denovo hybrid +ref polypolish"
  [D2]="denovo hybrid +ref polypolish racon"
  [D3]="denovo hybrid +ref nextpolish"
  [D4]="denovo hybrid +ref polisher=none"
  [D5]="denovo hybrid -ref (BUSCO) polypolish"
  [D6]="denovo long-only +ref"
  [D7]="denovo long-only -ref (BUSCO)"
  [D8]="denovo short-only(Unicycler) +ref"
  [D9]="denovo short-only(Unicycler) -ref (BUSCO)"
  [D10]="denovo hybrid +ref platform=pacbio (skips Medaka)"
  [R1]="reference hybrid polypolish"
  [R2]="reference hybrid nextpolish"
  [R3]="reference hybrid polisher=none"
  [R4]="reference long-only polypolish -- SUSPECTED BUG (silent drop via inner join)"
  [R5]="reference long-only polisher=none (control for R4)"
  [R6]="reference hybrid polypolish racon"
  [S1]="samplesheet denovo mixed(hybrid+longonly+shortonly) +ref"
  [S2]="samplesheet denovo mixed(hybrid+longonly+shortonly) -ref (BUSCO)"
  [S3]="samplesheet reference mixed(hybrid+longonly) -- multi-sample SUSPECTED BUG"
)

# Fills the `args` nameref with the nextflow CLI flags for a given test id.
build_args() {
  local id="$1"
  local -n out=$2
  out=(--t "$THREADS")
  case "$id" in
    D1)  out+=(--long_reads "$LONG" --short_reads_1 "$SR1" --short_reads_2 "$SR2" --genome_size "$GSIZE" --sample_name sa_d1 --reference "$REF") ;;
    D2)  out+=(--long_reads "$LONG" --short_reads_1 "$SR1" --short_reads_2 "$SR2" --genome_size "$GSIZE" --sample_name sa_d2 --reference "$REF" --use_racon) ;;
    D3)  out+=(--long_reads "$LONG" --short_reads_1 "$SR1" --short_reads_2 "$SR2" --genome_size "$GSIZE" --sample_name sa_d3 --reference "$REF" --polisher nextpolish) ;;
    D4)  out+=(--long_reads "$LONG" --short_reads_1 "$SR1" --short_reads_2 "$SR2" --genome_size "$GSIZE" --sample_name sa_d4 --reference "$REF" --polisher none) ;;
    D5)  out+=(--long_reads "$LONG" --short_reads_1 "$SR1" --short_reads_2 "$SR2" --genome_size "$GSIZE" --sample_name sa_d5) ;;
    D6)  out+=(--long_reads "$LONG" --genome_size "$GSIZE" --sample_name sa_d6 --reference "$REF") ;;
    D7)  out+=(--long_reads "$LONG" --genome_size "$GSIZE" --sample_name sa_d7) ;;
    D8)  out+=(--short_reads_1 "$SR1" --short_reads_2 "$SR2" --sample_name sa_d8 --reference "$REF") ;;
    D9)  out+=(--short_reads_1 "$SR1" --short_reads_2 "$SR2" --sample_name sa_d9) ;;
    D10) out+=(--long_reads "$LONG" --short_reads_1 "$SR1" --short_reads_2 "$SR2" --genome_size "$GSIZE" --sample_name sa_d10 --reference "$REF" --platform pacbio) ;;
    R1)  out+=(--mode reference --long_reads "$LONG" --short_reads_1 "$SR1" --short_reads_2 "$SR2" --genome_size "$GSIZE" --sample_name sa_r1 --reference "$REF") ;;
    R2)  out+=(--mode reference --long_reads "$LONG" --short_reads_1 "$SR1" --short_reads_2 "$SR2" --genome_size "$GSIZE" --sample_name sa_r2 --reference "$REF" --polisher nextpolish) ;;
    R3)  out+=(--mode reference --long_reads "$LONG" --short_reads_1 "$SR1" --short_reads_2 "$SR2" --genome_size "$GSIZE" --sample_name sa_r3 --reference "$REF" --polisher none) ;;
    R4)  out+=(--mode reference --long_reads "$LONG" --genome_size "$GSIZE" --sample_name sa_r4 --reference "$REF") ;;
    R5)  out+=(--mode reference --long_reads "$LONG" --genome_size "$GSIZE" --sample_name sa_r5 --reference "$REF" --polisher none) ;;
    R6)  out+=(--mode reference --long_reads "$LONG" --short_reads_1 "$SR1" --short_reads_2 "$SR2" --genome_size "$GSIZE" --sample_name sa_r6 --reference "$REF" --use_racon) ;;
    S1)  out+=(--samplesheet "$SS_DENOVO" --reference "$REF") ;;
    S2)  out+=(--samplesheet "$SS_DENOVO") ;;
    S3)  out+=(--mode reference --samplesheet "$SS_REFERENCE" --reference "$REF") ;;
    *) echo "unknown test id: $id" >&2; return 1 ;;
  esac
}

echo "| id | descricao | status | duracao(s) | succeeded | failed | erro |" > "$SUMMARY"
echo "|---|---|---|---|---|---|---|" >> "$SUMMARY"

for id in "${TEST_IDS[@]}"; do
  echo "=== [$id] ${TEST_DESC[$id]} ==="
  args=()
  build_args "$id" args

  outdir="test_run_${id}"
  workdir="work_test_${id}"
  logfile="$LOG_DIR/${id}.log"
  rm -rf "$outdir" "$workdir"

  start_ts=$(date +%s)
  nextflow run bacflow.nf -w "$workdir" --outdir "$outdir" "${args[@]}" > "$logfile" 2>&1
  exit_code=$?
  end_ts=$(date +%s)
  duration=$(( end_ts - start_ts ))

  succeeded=$(grep -oE 'Succeeded[[:space:]]*:[[:space:]]*[0-9]+' "$logfile" | grep -oE '[0-9]+' | tail -1)
  failed=$(grep -oE 'Failed[[:space:]]*:[[:space:]]*[0-9]+' "$logfile" | grep -oE '[0-9]+' | tail -1)

  err_line="-"
  if [[ $exit_code -ne 0 ]]; then
    status="FAIL"
    err_line=$(grep -m1 -E 'ERROR ~|Exception' "$logfile" | tr '|' '¦' | cut -c1-160)
    [[ -z "$err_line" ]] && err_line="(exit $exit_code, ver $logfile)"
  else
    status="PASS"
  fi

  printf "| %s | %s | %s | %s | %s | %s | %s |\n" \
    "$id" "${TEST_DESC[$id]}" "$status" "$duration" "${succeeded:-?}" "${failed:-0}" "$err_line" >> "$SUMMARY"

  echo "  -> $status (${duration}s), exit=$exit_code"

  if [[ "$status" == "FAIL" && $STOP_ON_FAIL -eq 1 ]]; then
    echo "Parando na primeira falha (--stop-on-fail): $id"
    break
  fi
done

echo
echo "Resumo final em $SUMMARY:"
cat "$SUMMARY"
