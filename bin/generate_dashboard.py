#!/usr/bin/env python3
# By João Pitta (jlpitta82@gmail.com) and Beatriz Toscano (beatriz.melo@fiocruz.br)
# At Fiocruz-PE
"""Aggregate per-sample summary JSONs into the final bacflow dashboard.html."""
import argparse
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


def slope_chart(title, unit_note, series, domain, higher_is_better, extra_note=""):
    """series: list of dicts {sample, pre, post, verdict}. Returns SVG HTML block or '' if empty."""
    if not series:
        return ""
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
        body.append(f'<circle class="trend-dot {v}" cx="{X_PRE}" cy="{y_pre:.1f}" r="4"><title>{sample_esc} pré-polish: {s["pre"]:.1f}</title></circle>')
        body.append(f'<circle class="trend-dot {v}" cx="{X_POST}" cy="{y_post:.1f}" r="4"><title>{sample_esc} pós-polish: {s["post"]:.1f}</title></circle>')
        label_esc = html.escape(truncate_label(s["sample"]))
        body.append(f'<text class="trend-label {v}" x="{X_PRE-10}" y="{pre_label_y[s["sample"]]:.1f}" text-anchor="end">{label_esc} · {s["pre"]:.1f}</text>')
        body.append(f'<text class="trend-label {v}" x="{X_POST+10}" y="{post_label_y[s["sample"]]:.1f}" text-anchor="start">{s["post"]:.1f}</text>')

    body.append(f'<text class="trend-axis-caption" x="{X_PRE}" y="205" text-anchor="middle">Pré-polish</text>')
    body.append(f'<text class="trend-axis-caption" x="{X_POST}" y="205" text-anchor="middle">Pós-polish</text>')

    arrow = "subir é melhora" if higher_is_better else "descer é melhora"
    note = f'<p class="trend-note">{html.escape(unit_note)} · eixo {lo:.0f}–{hi:.0f} · {arrow}{(" · " + extra_note) if extra_note else ""}</p>'
    svg = (f'<svg viewBox="0 0 {CHART_W} {CHART_H}" role="img" aria-label="{html.escape(title)}">'
           + "".join(body) + "</svg>")
    return f'<div class="trend-card"><h3>{html.escape(title)}</h3>{note}{svg}</div>'


def build_trend_section(samples):
    with_cmp = [s for s in samples if s["has_polish_comparison"]]

    ref_series = []
    noref_series = []
    for s in with_cmp:
        sig = s["signals"]
        if s["has_reference"] and "mismatches_per_100kbp" in sig:
            m = sig["mismatches_per_100kbp"]
            ref_series.append({"sample": s["sample"], "pre": m["pre"], "post": m["post"], "verdict": m["verdict"]})
        if (not s["has_reference"]) and "busco_complete_pct" in sig:
            m = sig["busco_complete_pct"]
            noref_series.append({"sample": s["sample"], "pre": m["pre"], "post": m["post"], "verdict": m["verdict"]})

    completeness_series = []
    contamination_series = []
    for s in with_cmp:
        sig = s["signals"]
        if "checkm2_completeness" in sig:
            m = sig["checkm2_completeness"]
            completeness_series.append({"sample": s["sample"], "pre": m["pre"], "post": m["post"], "verdict": m["verdict"]})
        if "checkm2_contamination" in sig:
            m = sig["checkm2_contamination"]
            contamination_series.append({"sample": s["sample"], "pre": m["pre"], "post": m["post"], "verdict": m["verdict"]})

    charts = []
    if ref_series:
        vals = [v for s in ref_series for v in (s["pre"], s["post"])]
        domain = (0, max(vals) * 1.15 if max(vals) > 0 else 1)
        charts.append(slope_chart("Erros de montagem", "QUAST · mismatches /100kbp", ref_series, domain,
                                   higher_is_better=False, extra_note="amostras com --reference"))
    if noref_series:
        vals = [v for s in noref_series for v in (s["pre"], s["post"])]
        lo = min(90, min(vals) - 2)
        charts.append(slope_chart("Completude gênica", "BUSCO · % completos", noref_series, (max(0, lo), 100),
                                   higher_is_better=True, extra_note="amostras sem --reference"))
    if completeness_series:
        vals = [v for s in completeness_series for v in (s["pre"], s["post"])]
        lo = min(90, min(vals) - 2)
        charts.append(slope_chart("Completude (CheckM2)", "% Completeness", completeness_series, (max(0, lo), 100),
                                   higher_is_better=True, extra_note="todas as amostras, sempre roda"))
    if contamination_series:
        vals = [v for s in contamination_series for v in (s["pre"], s["post"])]
        hi = max(vals) * 1.15 if max(vals) > 0 else 5
        charts.append(slope_chart("Contaminação (CheckM2)", "% Contamination", contamination_series, (0, hi),
                                   higher_is_better=False, extra_note="todas as amostras, sempre roda"))

    if not charts:
        return ""

    return f'''
  <section class="trend-section">
    <div class="trend-head">
      <h2>Tendência do polimento</h2>
      <p>Cada linha liga o valor pré-polish ao pós-polish de uma amostra.</p>
    </div>
    <div class="trend-legend">
      <span class="legend-item"><i class="dot good"></i>Melhorou</span>
      <span class="legend-item"><i class="dot neutral"></i>Inconclusivo</span>
      <span class="legend-item"><i class="dot critical"></i>Sem melhora</span>
    </div>
    <div class="trend-grid">
      {"".join(charts)}
    </div>
  </section>
'''


# ─── cards + table ──────────────────────────────────────────────────────────

VERDICT_CHIP = {
    "good": ('good', '✓ Melhorou'),
    "neutral": ('neutral', '– Inconclusivo'),
    "critical": ('critical', '✕ Sem melhora'),
    "na": ('neutral', '○ Sem comparação'),
}

METRIC_META = {
    "mismatches_per_100kbp": ("Mismatches /100kbp", "menor é melhor", False),
    "indels_per_100kbp": ("Indels /100kbp", "menor é melhor", False),
    "busco_complete_pct": ("Completos (BUSCO, %)", "maior é melhor", True),
    "checkm2_completeness": ("Completeness (CheckM2, %)", "maior é melhor", True),
    "checkm2_contamination": ("Contamination (CheckM2, %)", "menor é melhor", False),
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
    pct_change = f"{'+' if delta >= 0 else ''}{(delta / pre_v * 100):.0f}%" if pre_v else "n/d"
    return f'''
        <div class="metric-row">
          <div class="metric-label">{html.escape(label)}<span class="metric-hint">{hint}</span></div>
          <div class="metric-bars">
            <div class="bar-track"><div class="bar-rail"><div class="bar-fill pre" style="width:{pre_pct:.1f}%"></div></div><span class="bar-value">{pre_v:.1f}</span></div>
            <div class="bar-track"><div class="bar-rail"><div class="bar-fill post-{v}" style="width:{post_pct:.1f}%"></div></div><span class="bar-value">{post_v:.1f}</span></div>
          </div>
          <div class="metric-delta {v}" data-tooltip="{pct_change} vs. pré-polish">{arrow} {abs(delta):.1f}</div>
        </div>'''


def info_metric_row_html(label, value, hint=""):
    return f'''
        <div class="metric-row-info"><span>{html.escape(label)}</span><span><b>{value}</b>{(" · " + hint) if hint else ""}</span></div>'''


def sample_card_body(s):
    """Returns (metrics_html, note_html) — the two variable blocks inside a card."""
    if not s["has_polish_comparison"]:
        rows = [info_metric_row_html(
            "Montagem", s["assembler"].capitalize(),
            "Unicycler já incorpora os short reads — sem estado pré-polish pra comparar",
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
        n50_html = (f'<div class="info-row"><span>N50 (contiguidade, informativo)</span>'
                    f'<span><b>{qpre:,.0f} bp → {qpost:,.0f} bp</b> · sem alteração esperada</span></div>')
    metrics_html = f'<div class="metrics">{"".join(rows)}</div>{n50_html}'

    note_html = ""
    if s.get("contamination_alert"):
        post_contam = s["checkm2"]["post"]["contamination"]
        note_html = (f'<div class="card-note">⚠ Contaminação alta pós-polish ({post_contam:.1f}%) '
                      f'— considerar investigar a amostra (cultura mista, cross-contamination) antes de aceitar a montagem.</div>')

    return metrics_html, note_html


def sample_card_html(s):
    v = s["verdict"]
    stripe_class, chip_text = VERDICT_CHIP[v]
    mode_text = "QUAST · referência" if s["has_reference"] else "BUSCO · sem referência"
    input_text = INPUT_TYPE_LABEL[s["input_type"]]
    sample_esc = html.escape(s["sample"])
    metrics_html, note_html = sample_card_body(s)

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
      {metrics_html}
      {note_html}
    </article>'''


def table_rows_html(samples):
    rows = []
    for s in samples:
        mode = "QUAST" if s["has_reference"] else "BUSCO"
        if not s["has_polish_comparison"]:
            rows.append(f'<tr><td>{html.escape(s["sample"])}</td><td>{mode}</td>'
                        f'<td class="label-cell">(Unicycler, sem comparação)</td><td>—</td><td>—</td>'
                        f'<td>—</td><td><span class="verdict-td neutral">○ Sem comparação</span></td></tr>')
            continue
        for key, sig in s["signals"].items():
            label = METRIC_META[key][0]
            v = sig["verdict"] or "neutral"
            chip_class, chip_text = VERDICT_CHIP[v]
            rows.append(f'<tr><td>{html.escape(s["sample"])}</td><td>{mode}</td>'
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
    args = ap.parse_args()

    files = sorted(glob.glob(os.path.join(args.summary_dir, "*.summary.json")))
    samples = []
    for fp in files:
        with open(fp) as f:
            d = json.load(f)
        samples.append(compute_sample(d))
    samples.sort(key=lambda s: s["sample"])

    n_total = len(samples)
    n_good = sum(1 for s in samples if s["verdict"] == "good")
    n_neutral = sum(1 for s in samples if s["verdict"] == "neutral")
    n_critical = sum(1 for s in samples if s["verdict"] == "critical")
    n_na = sum(1 for s in samples if s["verdict"] == "na")

    tiles = [
        ('<div class="stat"><div class="n">{}</div><div class="label">Amostras analisadas</div></div>'.format(n_total)),
        ('<div class="stat is-good"><div class="n">{}</div><div class="label">Melhoraram</div></div>'.format(n_good)),
        ('<div class="stat is-neutral"><div class="n">{}</div><div class="label">Inconclusivas</div></div>'.format(n_neutral)),
        ('<div class="stat is-critical"><div class="n">{}</div><div class="label">Sem melhora</div></div>'.format(n_critical)),
    ]
    if n_na:
        tiles.append('<div class="stat is-neutral"><div class="n">{}</div><div class="label">Sem comparação (Unicycler)</div></div>'.format(n_na))

    trend_html = build_trend_section(samples)
    cards_html = "".join(sample_card_html(s) for s in samples)
    table_html = table_rows_html(samples)

    template_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "dashboard_template.html")
    with open(template_path) as f:
        template = f.read()

    now = datetime.datetime.now().strftime("%d/%m/%Y %H:%M")
    out_html = (template
                .replace("{{RUN_DATE}}", now)
                .replace("{{RUN_COMMIT}}", args.run_commit or "n/d")
                .replace("{{NEXTFLOW_VERSION}}", args.nextflow_version or "n/d")
                .replace("{{N_SAMPLES}}", str(n_total))
                .replace("{{OVERVIEW_TILES}}", "".join(tiles))
                .replace("{{TREND_SECTION}}", trend_html)
                .replace("{{CARDS_HTML}}", cards_html)
                .replace("{{TABLE_ROWS}}", table_html))

    with open(args.out, "w") as f:
        f.write(out_html)


if __name__ == "__main__":
    main()
