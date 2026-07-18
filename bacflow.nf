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
include { QUAST             } from './modules/local/quast'

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
    if (params.t > max_cpus) {
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

        // short-read polishing — only for flye_path samples that actually have
        // short reads. join(remainder:true) + branch + mix so that samples
        // without short reads pass through untouched instead of being silently
        // dropped by a plain inner join() (previous behavior; see README history).
        def ch_flye_joined = ch_draft_flye.join(ch_sr_clean, remainder: true)
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

        // ── Unicycler path (short-read-only samples) ────────────────────────────
        def ch_uni_input = branched.unicycler_path
            .map { s, lr, r1, r2, gs -> tuple(s) }
            .join(ch_sr_clean)
        UNICYCLER(ch_uni_input)
        def ch_draft_uni = UNICYCLER.out.assembly
        // never polished further — Unicycler already incorporates the short reads

        def ch_draft = ch_draft_flye_final.mix(ch_draft_uni)
        QUAST(ch_draft, ch_reference)

    // ─────────────────────────────────────────────────────────────────────────
    // REFERENCE MODE
    // ─────────────────────────────────────────────────────────────────────────
    } else if (params.mode == 'reference') {

        if (!params.reference) error "--reference is required in reference mode"

        def ch_ref_draft
        ch_ref_draft = Channel.fromPath(params.reference)
            .map { f -> tuple(params.sample_name, f) }

        // combine per-sample lr with the reference draft
        def ch_medaka_input = ch_lr_filtered.combine(ch_ref_draft, by: 0)

        MEDAKA(ch_medaka_input, medaka_model)
        def ch_draft = MEDAKA.out.assembly

        if (params.polisher == 'polypolish') {
            POLYPOLISH(ch_draft.join(ch_sr_clean))
            ch_draft = POLYPOLISH.out.assembly
        } else if (params.polisher == 'nextpolish') {
            NEXTPOLISH(ch_draft.join(ch_sr_clean), params.nextpolish_rounds)
            ch_draft = NEXTPOLISH.out.assembly
        }

        QUAST(ch_draft, ch_reference)

    } else {
        error "Unknown --mode '${params.mode}'. Use 'denovo' or 'reference'."
    }
}
