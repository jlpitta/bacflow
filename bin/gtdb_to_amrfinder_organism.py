#!/usr/bin/env python3
# By João Pitta (jlpitta82@gmail.com) and Beatriz Toscano (beatriz.melo@fiocruz.br)
# At Fiocruz-PE
"""Match a GTDB-Tk classification to an AMRFinderPlus --organism value.

Queries the AMRFinderPlus database's own supported-organism list at runtime
(via `amrfinder --list_organisms`), instead of a hardcoded table -- newly
curated organisms are picked up automatically as the database is updated,
with no code change needed. Falls back to no organism (AMRFinder's generic
core database) when there's no match; this always succeeds, it never
fails the caller just because a species isn't in the curated list.
"""
import argparse
import csv
import re
import subprocess
import sys

# Known cases where GTDB's ANI-based taxonomy diverges from the names
# AMRFinderPlus expects (which mostly follow traditional/NCBI naming).
# Meant to grow empirically as real samples surface new cases -- not an
# attempt to be exhaustive from the start.
KNOWN_ALIASES = {
    # GTDB nests *Shigella* inside *Escherichia* by ANI; AMRFinder has no
    # separate Shigella organism, but Escherichia covers it.
    "escherichia": "Escherichia",
}


def strip_clade_suffix(name):
    """Remove GTDB clade letters, e.g. the '_A' in 'Escherichia_A'."""
    return re.sub(r"_[A-Z]+$", "", name)


def parse_gtdbtk_classification(summary_path):
    with open(summary_path) as f:
        reader = csv.DictReader(f, delimiter="\t")
        row = next(reader)
    ranks = {}
    for part in row["classification"].split(";"):
        prefix, _, value = part.partition("__")
        ranks[prefix] = value
    return ranks


def list_amrfinder_organisms(amrfinder_db, amrfinder_bin="amrfinder"):
    result = subprocess.run(
        [amrfinder_bin, "--list_organisms", "-d", amrfinder_db],
        capture_output=True, text=True, check=True,
    )
    for line in result.stdout.splitlines():
        if line.startswith("Available --organism options:"):
            options = line.split(":", 1)[1]
            return [o.strip() for o in options.split(",") if o.strip()]
    return []


def match_organism(ranks, organism_list):
    organism_by_lower = {o.lower(): o for o in organism_list}

    genus = strip_clade_suffix(ranks.get("g", ""))
    species_full = ranks.get("s", "")
    species_epithet = species_full.split(" ")[-1] if " " in species_full else ""

    if not genus:
        return ""

    alias = KNOWN_ALIASES.get(genus.lower())
    if alias and alias.lower() in organism_by_lower:
        return organism_by_lower[alias.lower()]

    if species_epithet:
        candidate = f"{genus}_{species_epithet}".lower()
        if candidate in organism_by_lower:
            return organism_by_lower[candidate]

    if genus.lower() in organism_by_lower:
        return organism_by_lower[genus.lower()]

    return ""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gtdbtk-summary", required=True,
                         help="Path to {sample}.bac120.summary.tsv from GTDB-Tk")
    parser.add_argument("--amrfinder-db", required=True,
                         help="Path to the AMRFinderPlus database (e.g. ~/amrfinder_db/latest)")
    parser.add_argument("--amrfinder-bin", default="amrfinder")
    args = parser.parse_args()

    ranks = parse_gtdbtk_classification(args.gtdbtk_summary)
    organisms = list_amrfinder_organisms(args.amrfinder_db, args.amrfinder_bin)
    match = match_organism(ranks, organisms)

    print(match)
    if match:
        print(f"Matched organism: {match} (genus={ranks.get('g')}, species={ranks.get('s')})", file=sys.stderr)
    else:
        print(f"No AMRFinderPlus organism match for genus={ranks.get('g')}, species={ranks.get('s')} "
              "-- falling back to the generic database.", file=sys.stderr)


if __name__ == "__main__":
    main()
