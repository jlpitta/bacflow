#!/usr/bin/env python3
# By João Pitta (jlpitta82@gmail.com) and Beatriz Toscano (beatriz.melo@fiocruz.br)
# At Fiocruz-PE
"""Parse QUAST/BUSCO/CheckM2 reports for one sample (pre and post polish) into a single JSON."""
import argparse
import csv
import glob
import json
import os


def to_float(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def parse_quast(dirpath):
    report = os.path.join(dirpath, "report.tsv")
    values = {}
    with open(report) as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 2:
                values[parts[0]] = parts[1]
    return {
        "n50": to_float(values.get("N50")),
        "contigs": to_float(values.get("# contigs")),
        "total_length": to_float(values.get("Total length")),
        "genome_fraction": to_float(values.get("Genome fraction (%)")),
        "mismatches_per_100kbp": to_float(values.get("# mismatches per 100 kbp")),
        "indels_per_100kbp": to_float(values.get("# indels per 100 kbp")),
        "misassemblies": to_float(values.get("# misassemblies")),
    }


def parse_busco(dirpath):
    matches = sorted(glob.glob(os.path.join(dirpath, "short_summary.specific.*.json")))
    if not matches:
        matches = sorted(glob.glob(os.path.join(dirpath, "short_summary.*.json")))
    with open(matches[0]) as f:
        data = json.load(f)
    r = data.get("results", {})
    return {
        "complete_pct": to_float(r.get("Complete percentage")),
        "single_pct": to_float(r.get("Single copy percentage")),
        "duplicated_pct": to_float(r.get("Multi copy percentage")),
        "fragmented_pct": to_float(r.get("Fragmented percentage")),
        "missing_pct": to_float(r.get("Missing percentage")),
        "n_markers": r.get("n_markers"),
        "lineage": data.get("lineage_dataset", {}).get("name"),
    }


def parse_checkm2(dirpath):
    report = os.path.join(dirpath, "quality_report.tsv")
    with open(report) as f:
        reader = csv.DictReader(f, delimiter="\t")
        row = next(reader)
    return {
        "completeness": to_float(row.get("Completeness")),
        "contamination": to_float(row.get("Contamination")),
        "total_coding_sequences": to_float(row.get("Total_Coding_Sequences")),
        "genome_size": to_float(row.get("Genome_Size")),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sample", required=True)
    ap.add_argument("--input-type", required=True, choices=["hybrid", "long_only", "short_only"])
    ap.add_argument("--assembler", required=True, choices=["flye", "unicycler", "reference"])
    ap.add_argument("--quast-pre", required=True)
    ap.add_argument("--quast-post", required=True)
    ap.add_argument("--busco-pre")
    ap.add_argument("--busco-post")
    ap.add_argument("--checkm2-pre", required=True)
    ap.add_argument("--checkm2-post", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    data = {
        "sample": args.sample,
        "input_type": args.input_type,
        "assembler": args.assembler,
        # Unicycler has no separate polish step, so pre==post is fed in on purpose —
        # this flag lets the dashboard label it as "no comparison" instead of a verdict.
        "has_polish_comparison": args.assembler != "unicycler",
        "has_reference": args.busco_pre is None,
        "quast": {
            "pre": parse_quast(args.quast_pre),
            "post": parse_quast(args.quast_post),
        },
        "checkm2": {
            "pre": parse_checkm2(args.checkm2_pre),
            "post": parse_checkm2(args.checkm2_post),
        },
    }
    if args.busco_pre:
        data["busco"] = {
            "pre": parse_busco(args.busco_pre),
            "post": parse_busco(args.busco_post),
        }

    with open(args.out, "w") as f:
        json.dump(data, f, indent=2)


if __name__ == "__main__":
    main()
