#!/usr/bin/env nextflow
// bacflow — Pipeline Nextflow para montagem de genoma long-read com polimento híbrido
// By João Pitta (jlpitta82@gmail.com) and Beatriz Toscano (beatriz.melo@fiocruz.br)
// At Fiocruz-PE
// Tue 16 Jun 2026 15:42 -03 (Primeira versão)
// Thu 02 Jul 2026 12:20 -03 (Montagem short-read-only via Unicycler; remoção do modo híbrido Unicycler; fix de amostras derrubadas silenciosamente no polishing)
nextflow.enable.dsl = 2

include { NANOFILT          } from './modules/local/nanofilt'
include { SEQKIT_DOWNSAMPLE } from './modules/local/seqkit_downsample'
include { FASTP             } from './modules/local/fastp'
include { FASTQC_RAW; FASTQC_TRIMMED } from './modules/local/fastqc'
include { NANOSTAT_RAW; NANOSTAT_TRIMMED } from './modules/local/nanostat'
include { NANOCOMP          } from './modules/local/nanocomp'
include { FLYE              } from './modules/local/flye'
include { UNICYCLER         } from './modules/local/unicycler'
include { RACON             } from './modules/local/racon'
include { MEDAKA            } from './modules/local/medaka'
include { POLYPOLISH        } from './modules/local/polypolish'
include { NEXTPOLISH        } from './modules/local/nextpolish'
include { QUAST; QUAST_PREPOLISH; QUAST_POSTPOLISH } from './modules/local/quast'
include { BUSCO; BUSCO_PREPOLISH; BUSCO_POSTPOLISH } from './modules/local/busco'
include { CHECKM2; CHECKM2_PREPOLISH; CHECKM2_POSTPOLISH } from './modules/local/checkm2'
include { MULTIQC } from './modules/local/multiqc'
include { SAMPLE_SUMMARY; DASHBOARD } from './modules/local/dashboard'

// ─── helpers ─────────────────────────────────────────────────────────────────

def platform_defaults(platform) {
    if (platform == 'ont') {
        return [flye_mode: 'nano-hq', medaka_model: 'r1041_e82_400bps_hac_g632']
    } else if (platform == 'pacbio') {
        return [flye_mode: 'pacbio-hifi', medaka_model: null]
    } else { // mgicyclone
        return [flye_mode: 'nano-raw', medaka_model: 'r941_min_hac_g507']
    }
}

def resolved_flye_mode(params) {
    params.flye_mode ?: platform_defaults(params.platform).flye_mode
}

def resolved_medaka_model(params) {
    params.medaka_model ?: platform_defaults(params.platform).medaka_model
}

def help_message() {
    log.info """
    ╔══════════════════════════════════════════════════════════╗
    ║              bacflow v${workflow.manifest.version}                    ║
    ║        Long-Read Genome Assembly Pipeline                ║
    ╚══════════════════════════════════════════════════════════╝

    Usage:
      nextflow run bacflow.nf [options]

    Input (single-sample):
      --long_reads FILE       Long reads FASTQ.GZ (required, unless assembling short-read-only)
      --genome_size SIZE      Genome size, e.g. 5m, 2.4g (required when --long_reads is given)
      --sample_name NAME      Output prefix [default: sample]
      --short_reads_1 FILE    Short reads R1 (required for short-read polishing; alone, without
                               --long_reads, triggers short-read-only assembly via Unicycler)
      --short_reads_2 FILE    Short reads R2

    Input (multi-sample):
      --samplesheet FILE      CSV with columns: sample,long_reads,short_reads_1,short_reads_2,genome_size
                               (long_reads may be left empty per-sample for short-read-only assembly;
                               a samplesheet can freely mix hybrid, long-only and short-only samples)

    Mode:
      --mode MODE             denovo | reference [default: denovo]
      --reference FILE        Reference FASTA (required for --mode reference; optional QUAST comparison in denovo)
                               In denovo mode, when omitted, BUSCO pre/post-polish runs instead
                               of reference-based QUAST comparison (gene completeness signal)
      --busco_lineage NAME    BUSCO lineage dataset [default: bacteria_odb10] (only used when --reference is not set)
      --checkm2_db PATH       Path to CheckM2 DIAMOND database [default: ~/checkm2_db/CheckM2_database/uniref100.KO.1.dmnd]
                               CheckM2 (completeness + contamination) always runs, regardless of --reference

    Assembler (automatic, no flag):
      Samples with --long_reads are assembled with Flye.
      Samples with only short reads are assembled with Unicycler (SPAdes-based, short-read-only).
      --mode reference always requires --long_reads.

    Platform:
      --platform PLATFORM     mgicyclone | ont | pacbio [default: mgicyclone]
      --flye_mode MODE        Override platform flye mode
      --medaka_model MODEL    Override platform medaka model

    Polishing:
      --use_racon             Enable Racon polishing before Medaka
      --polisher POLISHER     Short-read polisher: polypolish (default), nextpolish, none
      --nextpolish_rounds N   NextPolish rounds, 1-4 [default: 1] (only with --polisher nextpolish)

    Filtering:
      --min_quality N         NanoFilt minimum Q-score [default: 10]
      --min_length N          NanoFilt minimum read length bp [default: 500]
      --downsample N          Max reads after filtering; 0 = no limit [default: 0]

    Resources:
      --t N                   Total CPUs [default: 8]
      --outdir DIR            Output directory [default: results]

    Profiles:
      -profile mamba          Use mamba (default)
      -profile conda          Use conda
      -profile micromamba     Use micromamba
    """.stripIndent()
}

// ─── parse samplesheet ───────────────────────────────────────────────────────

def parse_samplesheet(csv_file) {
    Channel.fromPath(csv_file)
        .splitCsv(header: true)
        .map { row ->
            def sample     = row.sample
            def long_reads = row.long_reads ? file(row.long_reads) : null
            def r1         = row.short_reads_1 ? file(row.short_reads_1) : null
            def r2         = row.short_reads_2 ? file(row.short_reads_2) : null

            if (!long_reads && !(r1 && r2)) {
                error "Sample ${sample}: provide long_reads, or both short_reads_1 and short_reads_2"
            }
            if (!long_reads && params.mode == 'reference') {
                error "Sample ${sample}: --mode reference requires long_reads (short-read-only is not supported in reference mode)"
            }
            if (!long_reads) {
                log.warn "Sample ${sample}: no long_reads provided — assembling short-read-only with Unicycler."
            }

            def gsize = row.genome_size ?: params.genome_size
            if (long_reads && !gsize) error "genome_size missing for sample ${sample} (required when long_reads is provided)"

            [sample, long_reads, r1, r2, gsize]
        }
}

// ─── main workflow ───────────────────────────────────────────────────────────

workflow {

    if (params.help) { help_message(); exit 0 }

    def max_cpus = Runtime.runtime.availableProcessors()
    if ((params.t as int) > max_cpus) {
        log.warn "Requested --t ${params.t} exceeds available CPUs (${max_cpus}) on this machine — capping to ${max_cpus}."
    }

    // resolve platform defaults
    def flye_mode    = resolved_flye_mode(params)
    def medaka_model = resolved_medaka_model(params)

    // ── build input channel ──────────────────────────────────────────────────
    def ch_input
    if (params.samplesheet) {
        ch_input = parse_samplesheet(params.samplesheet)
    } else if (params.long_reads) {
        if (!params.genome_size) error "--genome_size is required when --long_reads is provided"
        def r1 = params.short_reads_1 ? file(params.short_reads_1) : null
        def r2 = params.short_reads_2 ? file(params.short_reads_2) : null
        ch_input = Channel.of([
            params.sample_name,
            file(params.long_reads),
            r1, r2,
            params.genome_size
        ])
    } else if (params.short_reads_1 && params.short_reads_2) {
        if (params.mode == 'reference') error "--mode reference requires --long_reads (short-read-only is not supported in reference mode)"
        log.warn "No --long_reads provided — assembling short-read-only with Unicycler."
        ch_input = Channel.of([
            params.sample_name,
            null,
            file(params.short_reads_1),
            file(params.short_reads_2),
            params.genome_size
        ])
    } else {
        error "Provide --long_reads, --short_reads_1/--short_reads_2, or --samplesheet"
    }

    // ch_input: [sample, long_reads, r1, r2, genome_size]
    // assembler is chosen automatically per sample: long_reads present → Flye,
    // long_reads absent (short-only) → Unicycler.
    def branched = ch_input.branch { s, lr, r1, r2, gs ->
        flye_path:      lr != null
        unicycler_path: lr == null
    }

    def ch_lr    = branched.flye_path.map { s, lr, r1, r2, gs -> tuple(s, lr) }
    def ch_gsize = branched.flye_path.map { s, lr, r1, r2, gs -> tuple(s, gs) }
    def ch_sr    = ch_input.map { s, lr, r1, r2, gs -> tuple(s, r1, r2) }
                           .filter  { s, r1, r2 -> r1 != null }

    // ── long-read QC (flye_path only) ────────────────────────────────────────
    NANOFILT(ch_lr)
    def ch_lr_filtered = NANOFILT.out.reads

    // raw-vs-trimmed long-read QC, captured before downsampling (downsample is a
    // sampling reduction, not a quality change — not part of this comparison)
    NANOSTAT_RAW(ch_lr)
    NANOSTAT_TRIMMED(ch_lr_filtered)
    NANOCOMP(ch_lr.join(ch_lr_filtered))

    if (params.downsample > 0) {
        SEQKIT_DOWNSAMPLE(ch_lr_filtered)
        ch_lr_filtered = SEQKIT_DOWNSAMPLE.out.reads
    }

    // ── short-read QC (any sample with short reads: hybrid polishing or short-only assembly) ──
    FASTQC_RAW(ch_sr)
    FASTP(ch_sr)
    def ch_sr_clean = FASTP.out.reads
    FASTQC_TRIMMED(ch_sr_clean)

    // ── reference channel for QUAST ──────────────────────────────────────────
    def ch_reference
    if (params.reference) {
        ch_reference = Channel.fromPath(params.reference)
    } else {
        ch_reference = Channel.value([])
    }

    // ── MultiQC — files fed into the final aggregator (FastQC, NanoStat, QUAST,
    // CheckM2; BUSCO and NanoComp are deliberately excluded, see multiqc.nf) ────
    def outdir_abs = file(params.outdir).toAbsolutePath().toString()
    def ch_multiqc_files = Channel.empty()
        .mix(FASTQC_RAW.out.reports)
        .mix(FASTQC_TRIMMED.out.reports)
        .mix(NANOSTAT_RAW.out.report)
        .mix(NANOSTAT_TRIMMED.out.report)

    // dashboard summary JSONs, accumulated across denovo/reference branches the
    // same way ch_multiqc_files is above — DASHBOARD is called once at the end
    def ch_summary_json = Channel.empty()

    // ─────────────────────────────────────────────────────────────────────────
    // DENOVO MODE
    // ─────────────────────────────────────────────────────────────────────────
    if (params.mode == 'denovo') {

        // ── Flye path (every sample with long reads, hybrid or long-only) ───────
        def ch_flye_input = ch_lr_filtered.join(ch_gsize)
        FLYE(ch_flye_input, flye_mode)
        def ch_draft_flye = FLYE.out.assembly

        if (params.use_racon) {
            RACON(ch_lr_filtered.join(ch_draft_flye))
            ch_draft_flye = RACON.out.assembly
        }

        // Medaka (skip for PacBio)
        if (params.platform != 'pacbio') {
            MEDAKA(ch_lr_filtered.join(ch_draft_flye), medaka_model)
            ch_draft_flye = MEDAKA.out.assembly
        }

        // QC de montagem pré-polish — logo após Racon/Medaka, antes do polimento
        // com short reads (compara com QUAST_POSTPOLISH mais abaixo)
        QUAST_PREPOLISH(ch_draft_flye, ch_reference)

        // BUSCO só entra quando não há --reference: sem referência, a contiguidade
        // do QUAST não muda com o polish (ele corrige erro de base, não estrutura),
        // então a completude gênica do BUSCO é o sinal real de melhora
        if (!params.reference) {
            BUSCO_PREPOLISH(ch_draft_flye)
        }

        // CheckM2 roda sempre, com ou sem --reference: mede completude E
        // contaminação — a contaminação é uma dimensão que nem QUAST nem BUSCO
        // cobrem, então vale a pena mesmo quando a montagem já está bem avaliada
        // pelos outros dois
        CHECKM2_PREPOLISH(ch_draft_flye)
        ch_multiqc_files = ch_multiqc_files.mix(QUAST_PREPOLISH.out.report, CHECKM2_PREPOLISH.out.report)

        // short-read polishing — only for flye_path samples that actually have
        // short reads. join(remainder:true) + branch + mix so that samples
        // without short reads pass through untouched instead of being silently
        // dropped by a plain inner join() (previous behavior; see README history).
        // remainder:true also emits entries from ch_sr_clean with no match in
        // ch_draft_flye (asm=null) — e.g. unicycler_path (short-only) samples,
        // which have no Flye assembly at all — so those need filtering out here
        // instead of leaking into POLYPOLISH/NEXTPOLISH with a null path.
        // r1/r2 are wrapped as a single nested value before the join so the
        // join's own tuple arity stays fixed at (sample, asm, sr) even when
        // ch_sr_clean never emits a single item for the whole run (pure
        // long-read-only runs) — join(remainder:true) can't infer the right-hand
        // tuple shape from zero observed items, so without the wrapper it pads
        // with the wrong number of nulls and breaks the downstream destructuring.
        def ch_sr_wrapped = ch_sr_clean.map { s, r1, r2 -> tuple(s, [r1, r2]) }
        def ch_flye_joined = ch_draft_flye.join(ch_sr_wrapped, remainder: true)
            .filter { s, asm, sr -> asm != null }
            .map { s, asm, sr ->
                def (r1, r2) = (sr instanceof List) ? sr : [null, null]
                tuple(s, asm, r1, r2)
            }
        def polish_branch = ch_flye_joined.branch { s, asm, r1, r2 ->
            to_polish:   r1 != null && params.polisher != 'none'
            passthrough: !(r1 != null && params.polisher != 'none')
        }

        def ch_draft_flye_final
        if (params.polisher == 'polypolish') {
            POLYPOLISH(polish_branch.to_polish.map { s, asm, r1, r2 -> tuple(s, asm, r1, r2) })
            ch_draft_flye_final = POLYPOLISH.out.assembly
                .mix(polish_branch.passthrough.map { s, asm, r1, r2 -> tuple(s, asm) })
        } else if (params.polisher == 'nextpolish') {
            NEXTPOLISH(polish_branch.to_polish.map { s, asm, r1, r2 -> tuple(s, asm, r1, r2) }, params.nextpolish_rounds)
            ch_draft_flye_final = NEXTPOLISH.out.assembly
                .mix(polish_branch.passthrough.map { s, asm, r1, r2 -> tuple(s, asm) })
        } else {
            ch_draft_flye_final = ch_draft_flye
        }

        // QC de montagem pós-polish — mesmo caminho do QUAST_PREPOLISH acima,
        // após Polypolish/NextPolish (ou inalterado, se a amostra não tinha
        // short reads ou --polisher none — nesse caso pré e pós ficam idênticos,
        // o que é a informação correta: nenhum polimento foi aplicado)
        QUAST_POSTPOLISH(ch_draft_flye_final, ch_reference)

        if (!params.reference) {
            BUSCO_POSTPOLISH(ch_draft_flye_final)
        }

        CHECKM2_POSTPOLISH(ch_draft_flye_final)
        ch_multiqc_files = ch_multiqc_files.mix(QUAST_POSTPOLISH.out.report, CHECKM2_POSTPOLISH.out.report)

        // ── Unicycler path (short-read-only samples) ────────────────────────────
        def ch_uni_input = branched.unicycler_path
            .map { s, lr, r1, r2, gs -> tuple(s) }
            .join(ch_sr_clean)
        UNICYCLER(ch_uni_input)
        def ch_draft_uni = UNICYCLER.out.assembly
        // never polished further — Unicycler already incorporates the short reads,
        // então não há estado "pré-polish" real pra comparar — QUAST único, como antes
        QUAST(ch_draft_uni, ch_reference)

        // idem BUSCO: chamada única (sem antes/depois), só quando não há --reference
        if (!params.reference) {
            BUSCO(ch_draft_uni)
        }

        // CheckM2 roda sempre, chamada única (sem antes/depois), como o QUAST único
        CHECKM2(ch_draft_uni)
        ch_multiqc_files = ch_multiqc_files.mix(QUAST.out.report, CHECKM2.out.report)

        // ── dashboard summary (per sample) ───────────────────────────────────
        // flye_path and unicycler_path are not mutually exclusive within denovo
        // mode (a samplesheet can mix both), so — same reasoning as the QUAST/
        // BUSCO/CHECKM2 calls above — SAMPLE_SUMMARY is called ONCE on a channel
        // that merges both paths via mix(), rather than once per path.
        def ch_summary_meta_flye = branched.flye_path.map { s, lr, r1, r2, gs ->
            tuple(s, r1 != null ? 'hybrid' : 'long_only', 'flye')
        }
        def ch_summary_meta_uni = branched.unicycler_path.map { s, lr, r1, r2, gs ->
            tuple(s, 'short_only', 'unicycler')
        }
        def ch_summary_meta = ch_summary_meta_flye.mix(ch_summary_meta_uni)

        // Unicycler has no separate polish step: QUAST/BUSCO/CHECKM2 there are
        // single calls, fed as both pre and post so the dashboard can render
        // "no comparison" for those samples instead of a fake delta.
        def ch_quast_pre_denovo   = QUAST_PREPOLISH.out.report.mix(QUAST.out.report)
        def ch_quast_post_denovo  = QUAST_POSTPOLISH.out.report.mix(QUAST.out.report)
        def ch_checkm2_pre_denovo  = CHECKM2_PREPOLISH.out.report.mix(CHECKM2.out.report)
        def ch_checkm2_post_denovo = CHECKM2_POSTPOLISH.out.report.mix(CHECKM2.out.report)

        // BUSCO only exists at all when !params.reference (global toggle, not
        // per-sample) — when it doesn't run, feed [] so SAMPLE_SUMMARY's busco
        // input stages no files and the script omits --busco-pre/--busco-post
        def ch_busco_pre_denovo  = Channel.empty()
        def ch_busco_post_denovo = Channel.empty()
        if (!params.reference) {
            ch_busco_pre_denovo  = BUSCO_PREPOLISH.out.report.mix(BUSCO.out.report)
            ch_busco_post_denovo = BUSCO_POSTPOLISH.out.report.mix(BUSCO.out.report)
        }

        def ch_summary_input_denovo = ch_summary_meta
            .join(ch_quast_pre_denovo)
            .join(ch_quast_post_denovo)
            .join(ch_checkm2_pre_denovo)
            .join(ch_checkm2_post_denovo)
            .join(ch_busco_pre_denovo,  remainder: true)
            .join(ch_busco_post_denovo, remainder: true)
            .map { s, input_type, assembler, qpre, qpost, cpre, cpost, bpre, bpost ->
                tuple(s, input_type, assembler, qpre, qpost, bpre ?: [], bpost ?: [], cpre, cpost)
            }

        SAMPLE_SUMMARY(ch_summary_input_denovo)
        ch_summary_json = ch_summary_json.mix(SAMPLE_SUMMARY.out.json)

    // ─────────────────────────────────────────────────────────────────────────
    // REFERENCE MODE
    // ─────────────────────────────────────────────────────────────────────────
    } else if (params.mode == 'reference') {

        if (!params.reference) error "--reference is required in reference mode"

        def ch_ref_file = Channel.fromPath(params.reference)

        // combine per-sample lr with the reference draft — cross join (not
        // keyed), since the reference file has no sample name and is the
        // same for every sample in the run, whether from --reference or a
        // --samplesheet (a by:0 keyed combine against params.sample_name
        // only ever matched the single-sample CLI case by coincidence — with
        // a samplesheet no row's sample name ever equals params.sample_name,
        // so MEDAKA silently never ran for any sample)
        def ch_medaka_input = ch_lr_filtered.combine(ch_ref_file)

        MEDAKA(ch_medaka_input, medaka_model)
        def ch_draft = MEDAKA.out.assembly

        // QC de montagem pré-polish — logo após o Medaka, antes do polimento
        // com short reads (compara com QUAST_POSTPOLISH mais abaixo)
        QUAST_PREPOLISH(ch_draft, ch_reference)

        // CheckM2 roda sempre (não é condicionado a --reference como o BUSCO —
        // modo reference sempre tem --reference, mas CheckM2 mede contaminação,
        // uma dimensão que o QUAST baseado em referência não cobre)
        CHECKM2_PREPOLISH(ch_draft)
        ch_multiqc_files = ch_multiqc_files.mix(QUAST_PREPOLISH.out.report, CHECKM2_PREPOLISH.out.report)

        // short-read polishing — same join(remainder:true)+wrap+branch fix as
        // v0.9.1 in denovo mode: a plain inner join here silently dropped any
        // sample with no short reads (and ALL samples when ch_sr_clean was
        // entirely empty for the whole run) from POLYPOLISH onward instead of
        // just passing them through unpolished. Variable names kept distinct
        // from the denovo block's (ch_sr_wrapped/ch_flye_joined/polish_branch)
        // even though the two are mutually exclusive branches, since this
        // Nextflow version has shown sensitivity to repeated `def` in the same
        // workflow scope (see the 17/07 "Channel already defined" fix).
        def ch_ref_sr_wrapped = ch_sr_clean.map { s, r1, r2 -> tuple(s, [r1, r2]) }
        def ch_ref_joined = ch_draft.join(ch_ref_sr_wrapped, remainder: true)
            .filter { s, asm, sr -> asm != null }
            .map { s, asm, sr ->
                def (r1, r2) = (sr instanceof List) ? sr : [null, null]
                tuple(s, asm, r1, r2)
            }
        def polish_branch_ref = ch_ref_joined.branch { s, asm, r1, r2 ->
            to_polish:   r1 != null && params.polisher != 'none'
            passthrough: !(r1 != null && params.polisher != 'none')
        }

        if (params.polisher == 'polypolish') {
            POLYPOLISH(polish_branch_ref.to_polish.map { s, asm, r1, r2 -> tuple(s, asm, r1, r2) })
            ch_draft = POLYPOLISH.out.assembly
                .mix(polish_branch_ref.passthrough.map { s, asm, r1, r2 -> tuple(s, asm) })
        } else if (params.polisher == 'nextpolish') {
            NEXTPOLISH(polish_branch_ref.to_polish.map { s, asm, r1, r2 -> tuple(s, asm, r1, r2) }, params.nextpolish_rounds)
            ch_draft = NEXTPOLISH.out.assembly
                .mix(polish_branch_ref.passthrough.map { s, asm, r1, r2 -> tuple(s, asm) })
        }

        // QC de montagem pós-polish — idêntico ao pré-polish se nenhum polimento
        // foi aplicado (--polisher none ou sem short reads), o que é a informação
        // correta nesse caso
        QUAST_POSTPOLISH(ch_draft, ch_reference)

        CHECKM2_POSTPOLISH(ch_draft)
        ch_multiqc_files = ch_multiqc_files.mix(QUAST_POSTPOLISH.out.report, CHECKM2_POSTPOLISH.out.report)

        // ── dashboard summary (per sample) ───────────────────────────────────
        // reference mode requires long_reads for every sample (validated in
        // parse_samplesheet / the single-sample branches above), so there is no
        // unicycler_path here and no busco (has_reference is always true).
        def ch_summary_meta_ref = ch_input.map { s, lr, r1, r2, gs ->
            tuple(s, r1 != null ? 'hybrid' : 'long_only', 'reference')
        }
        def ch_summary_input_ref = ch_summary_meta_ref
            .join(QUAST_PREPOLISH.out.report)
            .join(QUAST_POSTPOLISH.out.report)
            .join(CHECKM2_PREPOLISH.out.report)
            .join(CHECKM2_POSTPOLISH.out.report)
            .map { s, input_type, assembler, qpre, qpost, cpre, cpost ->
                tuple(s, input_type, assembler, qpre, qpost, [], [], cpre, cpost)
            }

        SAMPLE_SUMMARY(ch_summary_input_ref)
        ch_summary_json = ch_summary_json.mix(SAMPLE_SUMMARY.out.json)

    } else {
        error "Unknown --mode '${params.mode}'. Use 'denovo' or 'reference'."
    }

    MULTIQC(ch_multiqc_files.collect(), outdir_abs)
    DASHBOARD(ch_summary_json.collect(), workflow.commitId ?: 'n/d', workflow.nextflow.version.toString())
}
