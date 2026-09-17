#!/usr/bin/env python3
# By João Pitta (jlpitta82@gmail.com) and Beatriz Toscano (beatriz.melo@fiocruz.br)
# At Fiocruz-PE
"""Aggregate per-sample summary JSONs into the final bacflow dashboard.html."""
import argparse
import csv
import datetime
import glob
import html
import json
import os

NOISE_FLOOR = {
    "mismatches_per_100kbp": 1.0,
    "indels_per_100kbp": 1.0,
    "busco_complete_pct": 1.0,
    "checkm2_completeness": 1.0,
    "checkm2_contamination": 0.5,
}
CONTAMINATION_ALERT = 5.0

INPUT_TYPE_LABEL = {
    "hybrid": "Long + Short",
    "long_only": "Long only",
    "short_only": "Short only",
}


def classify(delta, floor):
    """delta already oriented so that positive == improvement."""
    if delta is None:
        return None
    if delta > floor:
        return "good"
    if delta < -floor:
        return "critical"
    return "neutral"


def overall_verdict(signals):
    signals = [s for s in signals if s is not None]
    if not signals:
        return "neutral"
    if "critical" in signals:
        return "critical"
    if "good" in signals:
        return "good"
    return "neutral"


def compute_sample(d):
    """Attach delta + verdict info to a loaded sample dict, in place."""
    if not d["has_polish_comparison"]:
        d["verdict"] = "na"
        d["signals"] = {}
        return d

    signals = {}

    if d["has_reference"]:
        qpre, qpost = d["quast"]["pre"], d["quast"]["post"]
        for key in ("mismatches_per_100kbp", "indels_per_100kbp"):
            pre_v, post_v = qpre.get(key), qpost.get(key)
            if pre_v is not None and post_v is not None:
                delta = pre_v - post_v  # lower is better
                signals[key] = {"pre": pre_v, "post": post_v, "delta": delta,
                                 "verdict": classify(delta, NOISE_FLOOR[key])}
    else:
        bpre, bpost = d["busco"]["pre"], d["busco"]["post"]
        pre_v, post_v = bpre.get("complete_pct"), bpost.get("complete_pct")
        if pre_v is not None and post_v is not None:
            delta = post_v - pre_v  # higher is better
            signals["busco_complete_pct"] = {"pre": pre_v, "post": post_v, "delta": delta,
                                              "verdict": classify(delta, NOISE_FLOOR["busco_complete_pct"])}

    cpre, cpost = d["checkm2"]["pre"], d["checkm2"]["post"]
    if cpre.get("completeness") is not None and cpost.get("completeness") is not None:
        delta = cpost["completeness"] - cpre["completeness"]  # higher better
        signals["checkm2_completeness"] = {"pre": cpre["completeness"], "post": cpost["completeness"],
                                            "delta": delta, "verdict": classify(delta, NOISE_FLOOR["checkm2_completeness"])}
    if cpre.get("contamination") is not None and cpost.get("contamination") is not None:
        delta = cpre["contamination"] - cpost["contamination"]  # lower better
        signals["checkm2_contamination"] = {"pre": cpre["contamination"], "post": cpost["contamination"],
                                             "delta": delta, "verdict": classify(delta, NOISE_FLOOR["checkm2_contamination"])}

    d["signals"] = signals
    d["verdict"] = overall_verdict([s["verdict"] for s in signals.values()])
    d["contamination_alert"] = bool(cpost.get("contamination") is not None and cpost["contamination"] > CONTAMINATION_ALERT)
    return d


# ─── SVG slope charts ──────────────────────────────────────────────────────

CHART_W, CHART_H = 380, 220
X_PRE, X_POST = 140, 280
Y_TOP, Y_BOTTOM = 30, 180


def truncate_label(name, max_len=10):
    return name if len(name) <= max_len else name[: max_len - 1] + "…"


def scale_y(value, lo, hi):
    if hi == lo:
        return (Y_TOP + Y_BOTTOM) / 2
    frac = (value - lo) / (hi - lo)
    frac = min(max(frac, 0), 1)
    return Y_BOTTOM - frac * (Y_BOTTOM - Y_TOP)


def place_labels(entries):
    """entries: list of (key, y). Returns {key: label_y} avoiding tight overlap."""
    out = {}
    last_y = None
    for key, y in sorted(entries, key=lambda t: t[1]):
        if last_y is not None and (y - last_y) < 15:
            label_y = y + 14
        else:
            label_y = y - 8
        out[key] = label_y
        last_y = y
    return out


def chart_data_table_html(series):
    """The per-sample pre/post/delta/verdict values behind a trend chart, as a table."""
    rows = []
    for s in series:
        v = s["verdict"] or "neutral"
        chip_class, chip_text = VERDICT_CHIP[v]
        rows.append(f'<tr><td>{html.escape(s["sample"])}</td>'
                    f'<td>{s["pre"]:.1f}</td><td>{s["post"]:.1f}</td>'
                    f'<td class="delta-{v}">{"+" if s["delta"]>=0 else ""}{s["delta"]:.1f}</td>'
                    f'<td><span class="verdict-td {chip_class}">{chip_text}</span></td></tr>')
    return (f'<div class="table-scroll modal-table-wrap"><table><thead><tr>'
            f'<th>Sample</th><th>Pre-polish</th><th>Post-polish</th><th>Delta</th><th>Verdict</th>'
            f'</tr></thead><tbody>{"".join(rows)}</tbody></table></div>')


def chart_modal_panel_html(chart_index, title, svg_html, series):
    """Hidden-by-default modal content for one chart: the same SVG at a larger
    display size (pure CSS scaling, same vector markup -- no re-render needed)
    plus its underlying per-sample data table and download buttons."""
    title_esc = html.escape(title)
    table_html = chart_data_table_html(series)
    return f'''
    <div class="modal-panel" id="chart-panel-{chart_index}" hidden>
      <div class="modal-panel-head">
        <h3>{title_esc}</h3>
        <div class="modal-actions">
          <button class="modal-btn dl-png" type="button">Download PNG</button>
          <button class="modal-btn dl-svg" type="button">Download SVG</button>
          <button class="modal-close" type="button" aria-label="Close">✕</button>
        </div>
      </div>
      <div class="modal-chart">{svg_html}</div>
      {table_html}
    </div>'''


def slope_chart(chart_index, title, unit_note, series, domain, higher_is_better, extra_note=""):
    """series: list of dicts {sample, pre, post, delta, verdict}.
    Returns (card_html, modal_panel_html) — both '' if series is empty."""
    if not series:
        return "", ""
    lo, hi = domain
    lines = []
    pre_positions = []
    post_positions = []
    for s in series:
        y_pre = scale_y(s["pre"], lo, hi)
        y_post = scale_y(s["post"], lo, hi)
        pre_positions.append((s["sample"], y_pre))
        post_positions.append((s["sample"], y_post))
    pre_label_y = place_labels(pre_positions)
    post_label_y = place_labels(post_positions)

    body = []
    body.append(f'<line class="trend-grid-line" x1="{X_PRE}" y1="{Y_TOP}" x2="{X_POST}" y2="{Y_TOP}" />')
    body.append(f'<line class="trend-grid-line" x1="{X_PRE}" y1="{(Y_TOP+Y_BOTTOM)/2:.1f}" x2="{X_POST}" y2="{(Y_TOP+Y_BOTTOM)/2:.1f}" />')
    body.append(f'<line class="trend-grid-line" x1="{X_PRE}" y1="{Y_BOTTOM}" x2="{X_POST}" y2="{Y_BOTTOM}" />')

    for s in series:
        v = s["verdict"] or "neutral"
        y_pre = scale_y(s["pre"], lo, hi)
        y_post = scale_y(s["post"], lo, hi)
        sample_esc = html.escape(s["sample"])
        body.append(f'<line class="trend-line {v}" x1="{X_PRE}" y1="{y_pre:.1f}" x2="{X_POST}" y2="{y_post:.1f}" />')
        body.append(f'<circle class="trend-dot {v}" cx="{X_PRE}" cy="{y_pre:.1f}" r="4"><title>{sample_esc} pre-polish: {s["pre"]:.1f}</title></circle>')
        body.append(f'<circle class="trend-dot {v}" cx="{X_POST}" cy="{y_post:.1f}" r="4"><title>{sample_esc} post-polish: {s["post"]:.1f}</title></circle>')
        label_esc = html.escape(truncate_label(s["sample"]))
        body.append(f'<text class="trend-label {v}" x="{X_PRE-10}" y="{pre_label_y[s["sample"]]:.1f}" text-anchor="end">{label_esc} · {s["pre"]:.1f}</text>')
        body.append(f'<text class="trend-label {v}" x="{X_POST+10}" y="{post_label_y[s["sample"]]:.1f}" text-anchor="start">{s["post"]:.1f}</text>')

    body.append(f'<text class="trend-axis-caption" x="{X_PRE}" y="205" text-anchor="middle">Pre-polish</text>')
    body.append(f'<text class="trend-axis-caption" x="{X_POST}" y="205" text-anchor="middle">Post-polish</text>')

    arrow = "higher is better" if higher_is_better else "lower is better"
    note = f'<p class="trend-note">{html.escape(unit_note)} · axis {lo:.0f}–{hi:.0f} · {arrow}{(" · " + extra_note) if extra_note else ""}</p>'
    svg = (f'<svg viewBox="0 0 {CHART_W} {CHART_H}" role="img" aria-label="{html.escape(title)}">'
           + "".join(body) + "</svg>")
    title_esc = html.escape(title)
    card = (f'<div class="trend-card" data-chart-index="{chart_index}">'
            f'<div class="trend-card-head"><h3>{title_esc}</h3>'
            f'<button class="trend-expand" type="button" data-chart-target="{chart_index}" '
            f'aria-label="Expand {title_esc} chart and view data table">⤢</button></div>'
            f'{note}{svg}</div>')
    panel = chart_modal_panel_html(chart_index, title, svg, series)
    return card, panel


def build_trend_section(samples):
    with_cmp = [s for s in samples if s["has_polish_comparison"]]

    ref_series = []
    noref_series = []
    for s in with_cmp:
        sig = s["signals"]
        if s["has_reference"] and "mismatches_per_100kbp" in sig:
            m = sig["mismatches_per_100kbp"]
            ref_series.append({"sample": s["sample"], "pre": m["pre"], "post": m["post"],
                                "delta": m["delta"], "verdict": m["verdict"]})
        if (not s["has_reference"]) and "busco_complete_pct" in sig:
            m = sig["busco_complete_pct"]
            noref_series.append({"sample": s["sample"], "pre": m["pre"], "post": m["post"],
                                  "delta": m["delta"], "verdict": m["verdict"]})

    completeness_series = []
    contamination_series = []
    for s in with_cmp:
        sig = s["signals"]
        if "checkm2_completeness" in sig:
            m = sig["checkm2_completeness"]
            completeness_series.append({"sample": s["sample"], "pre": m["pre"], "post": m["post"],
                                         "delta": m["delta"], "verdict": m["verdict"]})
        if "checkm2_contamination" in sig:
            m = sig["checkm2_contamination"]
            contamination_series.append({"sample": s["sample"], "pre": m["pre"], "post": m["post"],
                                          "delta": m["delta"], "verdict": m["verdict"]})

    charts = []
    panels = []

    def add_chart(*args, **kwargs):
        card, panel = slope_chart(len(charts), *args, **kwargs)
        charts.append(card)
        panels.append(panel)

    if ref_series:
        vals = [v for s in ref_series for v in (s["pre"], s["post"])]
        domain = (0, max(vals) * 1.15 if max(vals) > 0 else 1)
        add_chart("Assembly errors", "QUAST · mismatches /100kbp", ref_series, domain,
                  higher_is_better=False, extra_note="samples with --reference")
    if noref_series:
        vals = [v for s in noref_series for v in (s["pre"], s["post"])]
        lo = min(90, min(vals) - 2)
        add_chart("Gene completeness", "BUSCO · % complete", noref_series, (max(0, lo), 100),
                  higher_is_better=True, extra_note="samples without --reference")
    if completeness_series:
        vals = [v for s in completeness_series for v in (s["pre"], s["post"])]
        lo = min(90, min(vals) - 2)
        add_chart("Completeness (CheckM2)", "% Completeness", completeness_series, (max(0, lo), 100),
                  higher_is_better=True, extra_note="all samples, always runs")
    if contamination_series:
        vals = [v for s in contamination_series for v in (s["pre"], s["post"])]
        hi = max(vals) * 1.15 if max(vals) > 0 else 5
        add_chart("Contamination (CheckM2)", "% Contamination", contamination_series, (0, hi),
                  higher_is_better=False, extra_note="all samples, always runs")

    if not charts:
        return ""

    return f'''
  <section class="trend-section">
    <div class="trend-head">
      <h2>Polishing trend</h2>
      <p>Each line connects a sample's pre-polish value to its post-polish value. Click ⤢ on a chart to enlarge it and see the data behind it.</p>
    </div>
    <div class="trend-legend">
      <span class="legend-item"><i class="dot good"></i>Improved</span>
      <span class="legend-item"><i class="dot neutral"></i>Inconclusive</span>
      <span class="legend-item"><i class="dot critical"></i>No improvement</span>
    </div>
    <div class="trend-grid">
      {"".join(charts)}
    </div>
  </section>
  <div class="modal-overlay" id="chartModal" hidden>
    {"".join(panels)}
  </div>
'''


# ─── taxonomy section (GTDB-Tk, aggregated across all samples) ──────────────

def stat_tile_html(value, label, cls=""):
    cls_attr = f" {cls}" if cls else ""
    return f'<div class="stat{cls_attr}"><div class="n">{value}</div><div class="label">{html.escape(label)}</div></div>'


def dash_or(value, fmt=None):
    if value is None or value == "N/A":
        return "—"
    return fmt(value) if fmt else html.escape(str(value))


def build_taxonomy_section(samples):
    tax_samples = [s for s in samples if s.get("taxonomy")]
    if not tax_samples:
        return ""

    classified = [s for s in tax_samples if s["taxonomy"].get("species")]
    unclassified = [s for s in tax_samples if not s["taxonomy"].get("species")]

    species_counts = {}
    for s in classified:
        sp = s["taxonomy"]["species"]
        entry = species_counts.setdefault(sp, {"count": 0, "anis": []})
        entry["count"] += 1
        ani = s["taxonomy"].get("closest_reference_ani")
        if ani is not None:
            entry["anis"].append(ani)

    all_anis = [a for e in species_counts.values() for a in e["anis"]]
    avg_ani = sum(all_anis) / len(all_anis) if all_anis else None

    tiles = [
        stat_tile_html(len(tax_samples), "Samples analyzed"),
        stat_tile_html(len(classified), "Classified to species", cls="is-good" if classified and not unclassified else ""),
        stat_tile_html(len(unclassified), "Not classified", cls="is-critical" if unclassified else ""),
        stat_tile_html(len(species_counts), "Unique species found"),
    ]
    if avg_ani is not None:
        tiles.append(stat_tile_html(f"{avg_ani:.1f}%", "Avg. ANI to closest reference"))

    species_rows = []
    for sp, e in sorted(species_counts.items(), key=lambda kv: (-kv[1]["count"], kv[0])):
        avg = sum(e["anis"]) / len(e["anis"]) if e["anis"] else None
        pct = 100.0 * e["count"] / len(tax_samples)
        species_rows.append(
            f'<tr><td class="label-cell"><i>{html.escape(sp)}</i></td>'
            f'<td>{e["count"]} ({pct:.0f}%)</td>'
            f'<td>{f"{avg:.1f}%" if avg is not None else "—"}</td></tr>')
    if unclassified:
        pct = 100.0 * len(unclassified) / len(tax_samples)
        species_rows.append(
            f'<tr><td class="label-cell">Not classified to species</td>'
            f'<td>{len(unclassified)} ({pct:.0f}%)</td><td>—</td></tr>')

    sample_rows = []
    for s in tax_samples:
        t = s["taxonomy"]
        sample_esc = html.escape(s["sample"])
        if t.get("species"):
            species_cell = f'<i>{html.escape(t["species"])}</i>'
        elif t.get("genus"):
            species_cell = f'<span class="surveil-hint">genus only:</span> <i>{html.escape(t["genus"])}</i>'
        else:
            species_cell = '<span class="surveil-hint">Not classified</span>'
        ani_cell = dash_or(t.get("closest_reference_ani"), lambda v: f"{v:.1f}%")
        ref_cell = dash_or(t.get("closest_reference"))
        method_cell = dash_or(t.get("classification_method"))
        sample_rows.append(
            f'<tr><td>{sample_esc}</td><td class="label-cell">{species_cell}</td>'
            f'<td>{ani_cell}</td><td class="label-cell">{ref_cell}</td>'
            f'<td class="label-cell">{method_cell}</td></tr>')

    return f'''
  <section class="trend-section">
    <div class="trend-head">
      <h2>Taxonomic classification (GTDB-Tk)</h2>
      <p>Species-level classification against the GTDB reference database. The matched species is also what drives the organism-specific AMRFinderPlus database match in the section below.</p>
    </div>
    <div class="overview">
      {"".join(tiles)}
    </div>
    <div class="detail-block">
      <h3>Species found across samples</h3>
      <div class="table-scroll"><table><thead><tr>
        <th class="label-cell">Species</th><th>Samples</th><th>Avg. ANI</th>
      </tr></thead><tbody>{"".join(species_rows)}</tbody></table></div>
    </div>
    <div class="detail-block">
      <h3>Per-sample classification</h3>
      <div class="table-scroll"><table><thead><tr>
        <th>Sample</th><th class="label-cell">Species</th><th>ANI</th>
        <th class="label-cell">Closest reference genome</th><th class="label-cell">Classification method</th>
      </tr></thead><tbody>{"".join(sample_rows)}</tbody></table></div>
    </div>
  </section>
'''


# ─── incomplete assemblies (parsed from the Nextflow execution trace) ───────
# errorStrategy 'ignore' drops a failed task silently — the sample just never
# shows up in the dashboard, with no explanation. The trace file (1 line per
# task, `tag` = sample name since every process is `tag { sample }`) is the
# only remaining record of what happened to it.

FAILED_STATUSES = {"FAILED", "ABORTED"}


def parse_trace_failures(trace_path):
    """tag (sample name) -> list of {process, exit, workdir} for FAILED/ABORTED tasks."""
    failures = {}
    if not trace_path or not os.path.exists(trace_path):
        return failures
    with open(trace_path) as f:
        reader = csv.DictReader(f, delimiter="\t")
        for row in reader:
            if row.get("status") not in FAILED_STATUSES:
                continue
            tag = (row.get("tag") or "").strip()
            if not tag:
                continue
            failures.setdefault(tag, []).append({
                "process": row.get("process") or "?",
                "exit": row.get("exit") or "?",
                "workdir": row.get("workdir") or "",
            })
    return failures


def build_incomplete_section(trace_failures, completed_sample_names):
    """Samples with a FAILED/ABORTED task and NO usable final result (no
    summary.json => not in completed_sample_names) — not "had any failure",
    since e.g. only AMRFINDER_PREPOLISH failing on an otherwise-fine sample
    still produces a summary and doesn't belong here."""
    incomplete = {tag: tasks for tag, tasks in trace_failures.items()
                  if tag not in completed_sample_names}
    if not incomplete:
        return ""

    rows = []
    for sample in sorted(incomplete):
        for t in incomplete[sample]:
            workdir_cell = f'<span class="surveil-hint">{html.escape(t["workdir"])}</span>' if t["workdir"] else "—"
            rows.append(f'<tr><td>{html.escape(sample)}</td><td class="label-cell">{html.escape(t["process"])}</td>'
                        f'<td>{html.escape(str(t["exit"]))}</td><td class="label-cell">{workdir_cell}</td></tr>')

    return f'''
  <section class="trend-section">
    <div class="trend-head">
      <h2>Assemblies not completed</h2>
      <p><b>{len(incomplete)}</b> sample(s) had a task fail (<code>errorStrategy 'ignore'</code>) and never produced a usable final result — parsed from <code>pipeline_info/execution_trace.txt</code>. Workdir is kept for manual debugging (<code>nextflow log</code> / inspect the task directory directly).</p>
    </div>
    <div class="detail-block">
      <div class="table-scroll"><table><thead><tr>
        <th>Sample</th><th class="label-cell">Failed process</th><th>Exit code</th><th class="label-cell">Workdir</th>
      </tr></thead><tbody>{"".join(rows)}</tbody></table></div>
    </div>
  </section>
'''


# ─── Resistance section (AMRFinderPlus AMR+Stress, aggregated) ──────────────
# Split from the old combined "Resistance, virulence & stress" section
# (2026-09) so resistance and virulence can be surfaced as two independent
# panels — see build_virulence_section below for why (VFDB/abricate adds a
# second data source for virulence specifically, with no resistance
# equivalent, so the two no longer belong in one table).

def build_resistance_section(samples):
    amr_samples = [s for s in samples if s.get("amr")]
    if not amr_samples:
        return ""

    total_amr = sum(s["amr"].get("n_amr") or 0 for s in amr_samples)
    total_stress = sum(s["amr"].get("n_stress") or 0 for s in amr_samples)
    n_matched_org = sum(1 for s in amr_samples if s["amr"].get("organism_used"))
    n_rescued = sum(len(s["amr"].get("genes_fixed_by_polish") or []) for s in amr_samples)

    tiles = [
        stat_tile_html(len(amr_samples), "Samples analyzed"),
        stat_tile_html(total_amr, "AMR genes found"),
        stat_tile_html(total_stress, "Stress genes found"),
        stat_tile_html(f"{n_matched_org}/{len(amr_samples)}", "Organism-matched database"),
    ]
    if n_rescued:
        tiles.append(stat_tile_html(n_rescued, "Gene instances rescued by polishing", cls="is-good"))

    gene_stats = {}
    for s in amr_samples:
        for g in s["amr"].get("genes") or []:
            if g.get("type") not in ("AMR", "STRESS"):
                continue
            symbol = g.get("symbol") or "?"
            e = gene_stats.setdefault(symbol, {
                "name": g.get("name"), "class": g.get("class"), "subclass": g.get("subclass"),
                "type": g.get("type"), "count": 0, "identities": [], "coverages": [],
            })
            e["count"] += 1
            if g.get("identity_pct") is not None:
                e["identities"].append(g["identity_pct"])
            if g.get("coverage_pct") is not None:
                e["coverages"].append(g["coverage_pct"])

    gene_rows = []
    for symbol, e in sorted(gene_stats.items(), key=lambda kv: (-kv[1]["count"], kv[0])):
        avg_id = sum(e["identities"]) / len(e["identities"]) if e["identities"] else None
        avg_cov = sum(e["coverages"]) / len(e["coverages"]) if e["coverages"] else None
        pct = 100.0 * e["count"] / len(amr_samples)
        gene_rows.append(
            f'<tr><td class="label-cell"><b>{html.escape(symbol)}</b></td>'
            f'<td class="label-cell">{dash_or(e["name"])}</td>'
            f'<td class="label-cell">{dash_or(e["class"])}</td>'
            f'<td class="label-cell">{dash_or(e["subclass"])}</td>'
            f'<td>{dash_or(e["type"])}</td>'
            f'<td>{e["count"]} ({pct:.0f}%)</td>'
            f'<td>{f"{avg_id:.1f}%" if avg_id is not None else "—"}</td>'
            f'<td>{f"{avg_cov:.1f}%" if avg_cov is not None else "—"}</td></tr>')

    sample_rows = []
    for s in amr_samples:
        amr = s["amr"]
        sample_esc = html.escape(s["sample"])
        organism = amr.get("organism_used")
        org_cell = f'<i>{html.escape(organism)}</i>' if organism else '<span class="surveil-hint">generic database</span>'
        genes = [g for g in (amr.get("genes") or []) if g.get("type") in ("AMR", "STRESS")]
        if genes:
            fixed = set(amr.get("genes_fixed_by_polish") or [])
            chips = []
            for g in genes:
                symbol = g.get("symbol") or "?"
                rescued = symbol in fixed
                chip_class = "amr-chip rescued" if rescued else "amr-chip"
                cls = g.get("class") or g.get("type") or ""
                title_bits = [html.escape(cls)] if cls else []
                if rescued:
                    title_bits.append("rescued by polishing")
                chips.append(f'<span class="{chip_class}" title="{" · ".join(title_bits)}">{html.escape(symbol)}</span>')
            genes_cell = f'<div class="amr-chips">{"".join(chips)}</div>'
        else:
            genes_cell = '<span class="surveil-hint">no genes found</span>'
        sample_rows.append(
            f'<tr><td>{sample_esc}</td><td class="label-cell">{org_cell}</td>'
            f'<td>{amr.get("n_amr") or 0}</td><td>{amr.get("n_stress") or 0}</td>'
            f'<td class="label-cell">{genes_cell}</td></tr>')

    gene_table_block = ""
    if gene_rows:
        gene_table_block = f'''
    <div class="detail-block">
      <h3>Genes found across samples</h3>
      <div class="table-scroll"><table><thead><tr>
        <th class="label-cell">Symbol</th><th class="label-cell">Name</th><th class="label-cell">Class</th>
        <th class="label-cell">Subclass</th><th>Type</th><th>Samples</th><th>Avg. identity</th><th>Avg. coverage</th>
      </tr></thead><tbody>{"".join(gene_rows)}</tbody></table></div>
    </div>'''

    return f'''
  <section class="trend-section">
    <div class="trend-head">
      <h2>Resistance genes (AMRFinderPlus)</h2>
      <p>AMR and stress genes detected on the post-polish assembly. Matched against an organism-specific database when GTDB-Tk found a species AMRFinderPlus recognizes, otherwise the generic database — a generic-database result is broader but less precise.</p>
    </div>
    <div class="overview">
      {"".join(tiles)}
    </div>
    {gene_table_block}
    <div class="detail-block">
      <h3>Per-sample results</h3>
      <div class="table-scroll"><table><thead><tr>
        <th>Sample</th><th class="label-cell">Organism (database match)</th>
        <th>AMR</th><th>Stress</th><th class="label-cell">Genes</th>
      </tr></thead><tbody>{"".join(sample_rows)}</tbody></table></div>
    </div>
  </section>
'''


# ─── Virulence section (AMRFinderPlus VIRULENCE + VFDB/abricate) ────────────
# Two sources merged into one panel, tagged by source: AMRFinderPlus's
# --plus virulence search is curated for a small set of well-studied
# pathogens (Escherichia, Klebsiella pneumoniae, Staphylococcus aureus,
# Vibrio cholerae, Campylobacter, Salmonella) and comes back with 0 hits
# outside that group even when --plus is on; VFDB via abricate has much
# broader taxonomic coverage for virulence factors specifically. Kept
# separate from build_resistance_section above since VFDB has no
# resistance/stress equivalent -- merging would misrepresent VFDB's scope.

def build_virulence_section(samples):
    vir_samples = [s for s in samples if s.get("amr") or s.get("vfdb")]
    if not vir_samples:
        return ""

    total_amr_vir = sum(
        sum(1 for g in (s.get("amr") or {}).get("genes", []) if g.get("type") == "VIRULENCE")
        for s in vir_samples
    )
    total_vfdb = sum(len((s.get("vfdb") or {}).get("genes") or []) for s in vir_samples)

    tiles = [
        stat_tile_html(len(vir_samples), "Samples analyzed"),
        stat_tile_html(total_amr_vir, "AMRFinderPlus virulence genes"),
        stat_tile_html(total_vfdb, "VFDB genes (abricate)"),
    ]

    gene_stats = {}
    for s in vir_samples:
        for g in (s.get("amr") or {}).get("genes", []):
            if g.get("type") != "VIRULENCE":
                continue
            key = (g.get("symbol") or "?", "AMRFinderPlus")
            e = gene_stats.setdefault(key, {
                "name": g.get("name"), "source": "AMRFinderPlus", "count": 0,
                "identities": [], "coverages": [],
            })
            e["count"] += 1
            if g.get("identity_pct") is not None:
                e["identities"].append(g["identity_pct"])
            if g.get("coverage_pct") is not None:
                e["coverages"].append(g["coverage_pct"])
        for g in (s.get("vfdb") or {}).get("genes") or []:
            key = (g.get("symbol") or "?", "VFDB")
            e = gene_stats.setdefault(key, {
                "name": g.get("product"), "source": "VFDB", "count": 0,
                "identities": [], "coverages": [],
            })
            e["count"] += 1
            if g.get("identity_pct") is not None:
                e["identities"].append(g["identity_pct"])
            if g.get("coverage_pct") is not None:
                e["coverages"].append(g["coverage_pct"])

    gene_rows = []
    for (symbol, source), e in sorted(gene_stats.items(), key=lambda kv: (-kv[1]["count"], kv[0][0])):
        avg_id = sum(e["identities"]) / len(e["identities"]) if e["identities"] else None
        avg_cov = sum(e["coverages"]) / len(e["coverages"]) if e["coverages"] else None
        pct = 100.0 * e["count"] / len(vir_samples)
        gene_rows.append(
            f'<tr><td class="label-cell"><b>{html.escape(symbol)}</b></td>'
            f'<td class="label-cell">{dash_or(e["name"])}</td>'
            f'<td>{source}</td>'
            f'<td>{e["count"]} ({pct:.0f}%)</td>'
            f'<td>{f"{avg_id:.1f}%" if avg_id is not None else "—"}</td>'
            f'<td>{f"{avg_cov:.1f}%" if avg_cov is not None else "—"}</td></tr>')

    sample_rows = []
    for s in vir_samples:
        amr = s.get("amr") or {}
        vfdb = s.get("vfdb") or {}
        sample_esc = html.escape(s["sample"])
        amr_vir_genes = [g for g in amr.get("genes", []) if g.get("type") == "VIRULENCE"]
        vfdb_genes = vfdb.get("genes") or []
        chips = []
        for g in amr_vir_genes:
            symbol = g.get("symbol") or "?"
            chips.append(f'<span class="amr-chip" title="AMRFinderPlus">{html.escape(symbol)}</span>')
        for g in vfdb_genes:
            symbol = g.get("symbol") or "?"
            title = html.escape(g.get("product") or "VFDB")
            chips.append(f'<span class="amr-chip vfdb-source" title="VFDB · {title}">{html.escape(symbol)}</span>')
        genes_cell = f'<div class="amr-chips">{"".join(chips)}</div>' if chips else '<span class="surveil-hint">no genes found</span>'
        sample_rows.append(
            f'<tr><td>{sample_esc}</td>'
            f'<td>{len(amr_vir_genes)}</td><td>{len(vfdb_genes)}</td>'
            f'<td class="label-cell">{genes_cell}</td></tr>')

    gene_table_block = ""
    if gene_rows:
        gene_table_block = f'''
    <div class="detail-block">
      <h3>Genes found across samples</h3>
      <div class="table-scroll"><table><thead><tr>
        <th class="label-cell">Symbol</th><th class="label-cell">Name/Product</th>
        <th>Source</th><th>Samples</th><th>Avg. identity</th><th>Avg. coverage</th>
      </tr></thead><tbody>{"".join(gene_rows)}</tbody></table></div>
    </div>'''

    return f'''
  <section class="trend-section">
    <div class="trend-head">
      <h2>Virulence genes (AMRFinderPlus + VFDB)</h2>
      <p>Virulence factors detected on the post-polish assembly, from two sources: AMRFinderPlus's <code>--plus</code> search (curated for a handful of well-studied pathogens) and VFDB via <code>abricate</code> (broader taxonomic coverage). A gene absent from both sources is shown as 0, not necessarily absent from the genome.</p>
    </div>
    <div class="overview">
      {"".join(tiles)}
    </div>
    {gene_table_block}
    <div class="detail-block">
      <h3>Per-sample results</h3>
      <div class="table-scroll"><table><thead><tr>
        <th>Sample</th><th>AMRFinderPlus</th><th>VFDB</th><th class="label-cell">Genes</th>
      </tr></thead><tbody>{"".join(sample_rows)}</tbody></table></div>
    </div>
  </section>
'''


# ─── cards + table ──────────────────────────────────────────────────────────

VERDICT_CHIP = {
    "good": ('good', '✓ Improved'),
    "neutral": ('neutral', '– Inconclusive'),
    "critical": ('critical', '✕ No improvement'),
    "na": ('neutral', '○ No comparison'),
}

METRIC_META = {
    "mismatches_per_100kbp": ("Mismatches /100kbp", "lower is better", False),
    "indels_per_100kbp": ("Indels /100kbp", "lower is better", False),
    "busco_complete_pct": ("Complete (BUSCO, %)", "higher is better", True),
    "checkm2_completeness": ("Completeness (CheckM2, %)", "higher is better", True),
    "checkm2_contamination": ("Contamination (CheckM2, %)", "lower is better", False),
}


def metric_row_html(key, sig):
    label, hint, higher_better = METRIC_META[key]
    pre_v, post_v, delta, v = sig["pre"], sig["post"], sig["delta"], sig["verdict"] or "neutral"
    scale_max = max(pre_v, post_v, 0.0001)
    pre_pct = 100.0 * pre_v / scale_max
    post_pct = 100.0 * post_v / scale_max
    # arrow reflects the raw value's own trend (post vs. pre), matching the
    # pre/post numbers shown right beside it — NOT the improvement direction,
    # which would contradict those numbers for "lower is better" metrics
    # (e.g. indels rising 19.3→19.5 must show ↑, even though that's bad news;
    # color, not the arrow, carries the good/bad signal)
    raw_diff = post_v - pre_v
    arrow = "↑" if raw_diff > 0 else ("↓" if raw_diff < 0 else "—")
    pct_change = f"{'+' if delta >= 0 else ''}{(delta / pre_v * 100):.0f}%" if pre_v else "n/a"
    return f'''
        <div class="metric-row">
          <div class="metric-label">{html.escape(label)}<span class="metric-hint">{hint}</span></div>
          <div class="metric-bars">
            <div class="bar-track"><div class="bar-rail"><div class="bar-fill pre" style="width:{pre_pct:.1f}%"></div></div><span class="bar-value">{pre_v:.1f}</span></div>
            <div class="bar-track"><div class="bar-rail"><div class="bar-fill post-{v}" style="width:{post_pct:.1f}%"></div></div><span class="bar-value">{post_v:.1f}</span></div>
          </div>
          <div class="metric-delta {v}" data-tooltip="{pct_change} vs. pre-polish">{arrow} {abs(delta):.1f}</div>
        </div>'''


def info_metric_row_html(label, value, hint=""):
    return f'''
        <div class="metric-row-info"><span>{html.escape(label)}</span><span><b>{value}</b>{(" · " + hint) if hint else ""}</span></div>'''


# ─── surveillance section (taxonomy → annotation → AMR) ─────────────────────
# Sits at the top of the card, above the polish-comparison metrics: species
# identification contextualizes everything below it (the clinical/epi
# relevance of an AMR gene depends on the organism), and the annotation
# summary contextualizes the AMR list itself.

def taxonomy_html(tax):
    if not tax or not tax.get("species"):
        return ('<div class="surveil-row"><span class="surveil-label">Taxonomy</span>'
                '<span class="surveil-value">Not classified</span></div>')
    species_esc = html.escape(tax["species"])
    ani = tax.get("closest_reference_ani")
    ani_txt = f' · {ani:.1f}% ANI' if ani is not None else ""
    ref = tax.get("closest_reference")
    ref_txt = f' · closest reference: {html.escape(ref)}' if ref else ""
    return (f'<div class="surveil-row"><span class="surveil-label">Taxonomy</span>'
            f'<span class="surveil-value"><i>{species_esc}</i>{ani_txt}{ref_txt}</span></div>')


def annotation_html(ann):
    if not ann:
        return ""
    parts = []
    for key, label in (("n_cds", "CDS"), ("n_trna", "tRNA"), ("n_rrna", "rRNA")):
        value = ann.get(key)
        if value is not None:
            parts.append(f'{int(value)} {label}')
    if not parts:
        return ""
    return (f'<div class="surveil-row"><span class="surveil-label">Annotation</span>'
            f'<span class="surveil-value">{" · ".join(parts)} <span class="surveil-hint">(Bakta)</span></span></div>')


def resistance_html(amr):
    """'Resistance genes' block: AMRFinderPlus AMR + Stress only."""
    if not amr:
        return ""
    genes = [g for g in (amr.get("genes") or []) if g.get("type") in ("AMR", "STRESS")]
    fixed = set(amr.get("genes_fixed_by_polish") or [])
    organism = amr.get("organism_used")

    counts = []
    if amr.get("n_amr"):
        counts.append(f'{amr["n_amr"]} AMR')
    if amr.get("n_stress"):
        counts.append(f'{amr["n_stress"]} stress')
    summary = " · ".join(counts) if counts else "no genes found"
    org_note = (f' · organism: <i>{html.escape(organism)}</i>' if organism
                else ' · generic database (no organism match)')

    row = (f'<div class="surveil-row"><span class="surveil-label">Resistance genes</span>'
           f'<span class="surveil-value">{summary}{org_note}</span></div>')

    if not genes:
        return row

    chips = []
    for g in genes:
        symbol = g.get("symbol") or "?"
        cls = g.get("class") or g.get("type") or ""
        rescued = symbol in fixed
        chip_class = "amr-chip rescued" if rescued else "amr-chip"
        title_bits = [html.escape(cls)] if cls else []
        if rescued:
            title_bits.append("rescued by polishing")
        title = " · ".join(title_bits)
        chips.append(f'<span class="{chip_class}" title="{title}">{html.escape(symbol)}</span>')
    chips_html = f'<div class="amr-chips">{"".join(chips)}</div>'

    return row + chips_html


def virulence_html(amr, vfdb):
    """'Virulence genes' block: AMRFinderPlus VIRULENCE + VFDB/abricate, tagged by source."""
    amr_genes = [g for g in ((amr or {}).get("genes") or []) if g.get("type") == "VIRULENCE"]
    vfdb_genes = (vfdb or {}).get("genes") or []
    if not amr and not vfdb:
        return ""

    fixed = set((amr or {}).get("genes_fixed_by_polish") or [])
    n_total = len(amr_genes) + len(vfdb_genes)
    summary = (f'{n_total} gene{"s" if n_total != 1 else ""} '
               f'({len(amr_genes)} AMRFinderPlus · {len(vfdb_genes)} VFDB)') if n_total else "no genes found"

    row = (f'<div class="surveil-row"><span class="surveil-label">Virulence genes</span>'
           f'<span class="surveil-value">{summary}</span></div>')

    if not n_total:
        return row

    chips = []
    for g in amr_genes:
        symbol = g.get("symbol") or "?"
        rescued = symbol in fixed
        chip_class = "amr-chip rescued" if rescued else "amr-chip"
        title_bits = ["AMRFinderPlus"]
        if rescued:
            title_bits.append("rescued by polishing")
        chips.append(f'<span class="{chip_class}" title="{" · ".join(title_bits)}">{html.escape(symbol)}</span>')
    for g in vfdb_genes:
        symbol = g.get("symbol") or "?"
        title = html.escape(g.get("product") or "VFDB")
        chips.append(f'<span class="amr-chip vfdb-source" title="VFDB · {title}">{html.escape(symbol)}</span>')
    chips_html = f'<div class="amr-chips">{"".join(chips)}</div>'

    return row + chips_html


def surveillance_html(s):
    rows = (taxonomy_html(s.get("taxonomy")) + annotation_html(s.get("annotation"))
            + resistance_html(s.get("amr")) + virulence_html(s.get("amr"), s.get("vfdb")))
    if not rows:
        return ""
    return f'<div class="surveillance">{rows}</div>'


def sample_card_body(s):
    """Returns (metrics_html, note_html) — the two variable blocks inside a card."""
    if not s["has_polish_comparison"]:
        rows = [info_metric_row_html(
            "Assembly", s["assembler"].capitalize(),
            "Unicycler already incorporates the short reads — no pre-polish state to compare against",
        )]
        c = s["checkm2"]["post"]
        if c.get("completeness") is not None:
            rows.append(info_metric_row_html("CheckM2 Completeness", f'{c["completeness"]:.1f}%'))
        if c.get("contamination") is not None:
            rows.append(info_metric_row_html("CheckM2 Contamination", f'{c["contamination"]:.1f}%'))
        if s.get("busco"):
            b = s["busco"]["post"]
            if b.get("complete_pct") is not None:
                rows.append(info_metric_row_html("BUSCO Complete", f'{b["complete_pct"]:.1f}%'))
        return f'<div class="metrics">{"".join(rows)}</div>', ""

    order = ["mismatches_per_100kbp", "indels_per_100kbp", "busco_complete_pct",
             "checkm2_completeness", "checkm2_contamination"]
    rows = [metric_row_html(key, s["signals"][key]) for key in order if key in s["signals"]]

    qpre, qpost = s["quast"]["pre"].get("n50"), s["quast"]["post"].get("n50")
    n50_html = ""
    if qpre is not None and qpost is not None:
        n50_html = (f'<div class="info-row"><span>N50 (contiguity, informational)</span>'
                    f'<span><b>{qpre:,.0f} bp → {qpost:,.0f} bp</b> · no change expected</span></div>')
    metrics_html = f'<div class="metrics">{"".join(rows)}</div>{n50_html}'

    note_html = ""
    if s.get("contamination_alert"):
        post_contam = s["checkm2"]["post"]["contamination"]
        note_html = (f'<div class="card-note">⚠ High contamination post-polish ({post_contam:.1f}%) '
                      f'— consider investigating the sample (mixed culture, cross-contamination) before accepting the assembly.</div>')

    return metrics_html, note_html


def sample_card_html(s):
    v = s["verdict"]
    stripe_class, chip_text = VERDICT_CHIP[v]
    mode_text = "QUAST · reference" if s["has_reference"] else "BUSCO · no reference"
    input_text = INPUT_TYPE_LABEL[s["input_type"]]
    sample_esc = html.escape(s["sample"])
    metrics_html, note_html = sample_card_body(s)
    surveil_html = surveillance_html(s)

    return f'''
    <article class="card">
      <div class="card-stripe {stripe_class}"></div>
      <div class="card-head">
        <div class="card-head-row">
          <span class="sample-name">{sample_esc}</span>
          <span class="verdict-chip {stripe_class}">{chip_text}</span>
        </div>
        <div class="card-sub">
          <span class="mode-badge">{html.escape(mode_text)}</span>
          <span class="input-badge">{html.escape(input_text)}</span>
        </div>
      </div>
      {surveil_html}
      {metrics_html}
      {note_html}
    </article>'''


def _no_comparison_row(sample_esc, input_text, mode, label, value_text):
    """One table row for a single-call metric (Unicycler path — no pre/post
    pair to diff against, but the value itself is real, not a placeholder)."""
    return (f'<tr><td>{sample_esc}</td><td>{input_text}</td><td>{mode}</td>'
            f'<td class="label-cell">{html.escape(label)}</td><td>{value_text}</td><td>{value_text}</td>'
            f'<td>—</td><td><span class="verdict-td neutral">○ No comparison</span></td></tr>')


def table_rows_html(samples):
    rows = []
    for s in samples:
        mode = "QUAST" if s["has_reference"] else "BUSCO"
        input_text = html.escape(INPUT_TYPE_LABEL[s["input_type"]])
        sample_esc = html.escape(s["sample"])
        if not s["has_polish_comparison"]:
            # Unicycler has no pre/post pair, but CheckM2/BUSCO still ran
            # once (single call) and summarize_sample.py already feeds real
            # values under "post" for it — show those instead of a blanket
            # "no comparison" row with no numbers at all.
            c = s["checkm2"]["post"]
            added_any = False
            if c.get("completeness") is not None:
                rows.append(_no_comparison_row(sample_esc, input_text, mode,
                            "Completeness (CheckM2, %)", f'{c["completeness"]:.1f}'))
                added_any = True
            if c.get("contamination") is not None:
                rows.append(_no_comparison_row(sample_esc, input_text, mode,
                            "Contamination (CheckM2, %)", f'{c["contamination"]:.1f}'))
                added_any = True
            if s.get("busco"):
                b = s["busco"]["post"]
                if b.get("complete_pct") is not None:
                    rows.append(_no_comparison_row(sample_esc, input_text, mode,
                                "Complete (BUSCO, %)", f'{b["complete_pct"]:.1f}'))
                    added_any = True
            if not added_any:
                rows.append(f'<tr><td>{sample_esc}</td><td>{input_text}</td><td>{mode}</td>'
                            f'<td class="label-cell">(Unicycler, no data)</td><td>—</td><td>—</td>'
                            f'<td>—</td><td><span class="verdict-td neutral">○ No comparison</span></td></tr>')
            continue
        for key, sig in s["signals"].items():
            label = METRIC_META[key][0]
            v = sig["verdict"] or "neutral"
            chip_class, chip_text = VERDICT_CHIP[v]
            rows.append(f'<tr><td>{html.escape(s["sample"])}</td><td>{input_text}</td><td>{mode}</td>'
                        f'<td class="label-cell">{html.escape(label)}</td>'
                        f'<td>{sig["pre"]:.1f}</td><td>{sig["post"]:.1f}</td>'
                        f'<td class="delta-{v}">{"+" if sig["delta"]>=0 else ""}{sig["delta"]:.1f}</td>'
                        f'<td><span class="verdict-td {chip_class}">{chip_text}</span></td></tr>')
    return "".join(rows)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--summary-dir", required=True, help="directory containing *.summary.json files")
    ap.add_argument("--out", required=True)
    ap.add_argument("--run-commit", default="")
    ap.add_argument("--nextflow-version", default="")
    ap.add_argument("--trace", help="Nextflow execution_trace.txt, for the 'Assemblies not completed' section")
    args = ap.parse_args()

    files = sorted(glob.glob(os.path.join(args.summary_dir, "*.summary.json")))
    samples = []
    for fp in files:
        with open(fp) as f:
            d = json.load(f)
        samples.append(compute_sample(d))
    samples.sort(key=lambda s: s["sample"])

    trace_failures = parse_trace_failures(args.trace)
    incomplete_section_html = build_incomplete_section(trace_failures, {s["sample"] for s in samples})

    n_total = len(samples)
    n_good = sum(1 for s in samples if s["verdict"] == "good")
    n_neutral = sum(1 for s in samples if s["verdict"] == "neutral")
    n_critical = sum(1 for s in samples if s["verdict"] == "critical")
    n_na = sum(1 for s in samples if s["verdict"] == "na")

    tiles = [
        ('<div class="stat"><div class="n">{}</div><div class="label">Samples analyzed</div></div>'.format(n_total)),
        ('<div class="stat is-good"><div class="n">{}</div><div class="label">Improved</div></div>'.format(n_good)),
        ('<div class="stat is-neutral"><div class="n">{}</div><div class="label">Inconclusive</div></div>'.format(n_neutral)),
        ('<div class="stat is-critical"><div class="n">{}</div><div class="label">No improvement</div></div>'.format(n_critical)),
    ]
    if n_na:
        tiles.append('<div class="stat is-neutral"><div class="n">{}</div><div class="label">No comparison (Unicycler)</div></div>'.format(n_na))

    trend_html = build_trend_section(samples)
    taxonomy_section_html = build_taxonomy_section(samples)
    resistance_section_html = build_resistance_section(samples)
    virulence_section_html = build_virulence_section(samples)
    cards_html = "".join(sample_card_html(s) for s in samples)
    table_html = table_rows_html(samples)

    template_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "dashboard_template.html")
    with open(template_path) as f:
        template = f.read()

    now = datetime.datetime.now().strftime("%d/%m/%Y %H:%M")
    out_html = (template
                .replace("{{RUN_DATE}}", now)
                .replace("{{RUN_COMMIT}}", args.run_commit or "n/a")
                .replace("{{NEXTFLOW_VERSION}}", args.nextflow_version or "n/a")
                .replace("{{N_SAMPLES}}", str(n_total))
                .replace("{{OVERVIEW_TILES}}", "".join(tiles))
                .replace("{{TREND_SECTION}}", trend_html)
                .replace("{{TAXONOMY_SECTION}}", taxonomy_section_html)
                .replace("{{RESISTANCE_SECTION}}", resistance_section_html)
                .replace("{{VIRULENCE_SECTION}}", virulence_section_html)
                .replace("{{INCOMPLETE_SECTION}}", incomplete_section_html)
                .replace("{{CARDS_HTML}}", cards_html)
                .replace("{{TABLE_ROWS}}", table_html))

    with open(args.out, "w") as f:
        f.write(out_html)


if __name__ == "__main__":
    main()
