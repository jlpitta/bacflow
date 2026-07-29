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


def parse_gtdbtk(dirpath):
    matches = glob.glob(os.path.join(dirpath, "*.bac120.summary.tsv"))
    if not matches:
        return None
    with open(matches[0]) as f:
        reader = csv.DictReader(f, delimiter="\t")
        row = next(reader)
    ranks = {}
    for part in (row.get("classification") or "").split(";"):
        prefix, _, value = part.partition("__")
        ranks[prefix] = value
    return {
        "species": ranks.get("s") or None,
        "genus": ranks.get("g") or None,
        "closest_reference": row.get("closest_genome_reference") or None,
        "closest_reference_ani": to_float(row.get("closest_genome_ani")),
        "classification_method": row.get("classification_method") or None,
    }


def parse_bakta(dirpath):
    # {sample}.txt is the only plain .txt file bakta_output produces — the
    # hypotheticals summary is a .tsv, not .txt, so no ambiguity here.
    matches = glob.glob(os.path.join(dirpath, "*.txt"))
    if not matches:
        return None
    counts = {}
    in_annotation = False
    with open(matches[0]) as f:
        for line in f:
            line = line.strip()
            if line == "Annotation:":
                in_annotation = True
                continue
            if not in_annotation:
                continue
            if not line or ":" not in line:
                break
            key, _, value = line.partition(":")
            counts[key.strip()] = to_float(value.strip())
    return {
        "n_cds": counts.get("CDSs"),
        "n_trna": counts.get("tRNAs"),
        "n_rrna": counts.get("rRNAs"),
        "n_ncrna": counts.get("ncRNAs"),
        "n_pseudogenes": counts.get("pseudogenes"),
        "n_hypotheticals": counts.get("hypotheticals"),
    }


def parse_amr_genes(tsv_path):
    if not tsv_path or not os.path.exists(tsv_path):
        return []
    genes = []
    with open(tsv_path) as f:
        reader = csv.DictReader(f, delimiter="\t")
        for row in reader:
            genes.append({
                "symbol": row.get("Element symbol") or None,
                "name": row.get("Element name") or None,
                "type": row.get("Type") or None,
                "subtype": row.get("Subtype") or None,
                "class": row.get("Class") or None,
                "subclass": row.get("Subclass") or None,
                "coverage_pct": to_float(row.get("% Coverage of reference")),
                "identity_pct": to_float(row.get("% Identity to reference")),
                "method": row.get("Method") or None,
            })
    return genes


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
    ap.add_argument("--gtdbtk", required=True, help="GTDB-Tk output directory")
    ap.add_argument("--bakta", required=True, help="Bakta output directory")
    ap.add_argument("--organism", default="", help="Matched AMRFinderPlus --organism value, or empty if no match")
    ap.add_argument("--amrfinder-pre", help="Nucleotide-only AMRFinderPlus TSV (Flye path only)")
    ap.add_argument("--amrfinder-post", required=True, help="Full-mode AMRFinderPlus TSV")
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
        "taxonomy": parse_gtdbtk(args.gtdbtk),
        "annotation": parse_bakta(args.bakta),
    }
    if args.busco_pre:
        data["busco"] = {
            "pre": parse_busco(args.busco_pre),
            "post": parse_busco(args.busco_post),
        }

    organism_used = args.organism.strip() or None

    amr_pre_genes = parse_amr_genes(args.amrfinder_pre)
    amr_post_genes = parse_amr_genes(args.amrfinder_post)
    pre_symbols = {g["symbol"] for g in amr_pre_genes if g["symbol"]}
    post_symbols = {g["symbol"] for g in amr_post_genes if g["symbol"]}
    # Only meaningful when there's a real pre/post pair (Flye path) — for
    # Unicycler-path samples amr_pre_genes is empty (never polished), so this
    # naturally comes out empty there too, same "no comparison" degradation
    # already used for quast/checkm2/busco above.
    genes_fixed_by_polish = sorted(post_symbols - pre_symbols) if amr_pre_genes else []

    data["amr"] = {
        "organism_used": organism_used,
        "genes": amr_post_genes,
        "n_genes": len(amr_post_genes),
        "n_amr": sum(1 for g in amr_post_genes if g["type"] == "AMR"),
        "n_stress": sum(1 for g in amr_post_genes if g["type"] == "STRESS"),
        "n_virulence": sum(1 for g in amr_post_genes if g["type"] == "VIRULENCE"),
        "genes_fixed_by_polish": genes_fixed_by_polish,
    }

    with open(args.out, "w") as f:
        json.dump(data, f, indent=2)


if __name__ == "__main__":
    main()
