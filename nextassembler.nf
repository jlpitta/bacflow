#!/usr/bin/env nextflow
nextflow.enable.dsl = 2

include { NANOFILT          } from './modules/local/nanofilt'
include { SEQKIT_DOWNSAMPLE } from './modules/local/seqkit_downsample'
include { FASTP             } from './modules/local/fastp'
include { FLYE              } from './modules/local/flye'
include { UNICYCLER         } from './modules/local/unicycler'
include { RACON             } from './modules/local/racon'
include { MEDAKA            } from './modules/local/medaka'
include { NEXTPOLISH        } from './modules/local/nextpolish'
include { QUAST             } from './modules/local/quast'

// ─── helpers ─────────────────────────────────────────────────────────────────

def platform_defaults(platform) {
    switch (platform) {
        case 'ont':
            return [flye_mode: 'nano-hq', medaka_model: 'r1041_e82_400bps_hac_g632']
        case 'pacbio':
            return [flye_mode: 'pacbio-hifi', medaka_model: null]
        default: // mgicyclone
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
    ║              nextassembler v${workflow.manifest.version}                    ║
    ║        Long-Read Genome Assembly Pipeline                ║
    ╚══════════════════════════════════════════════════════════╝

    Usage:
      nextflow run nextassembler.nf [options]

    Input (single-sample):
      --long_reads FILE       Long reads FASTQ.GZ (required)
      --genome_size SIZE      Genome size, e.g. 5m, 2.4g (required)
      --sample_name NAME      Output prefix [default: sample]
      --short_reads_1 FILE    Short reads R1 (required for unicycler/nextpolish)
      --short_reads_2 FILE    Short reads R2

    Input (multi-sample):
      --samplesheet FILE      CSV with columns: sample,long_reads,short_reads_1,short_reads_2,genome_size

    Mode:
      --mode MODE             denovo | reference [default: denovo]
      --assembler ASSEMBLER   flye | unicycler [default: flye]
      --reference FILE        Reference FASTA (required for --mode reference; optional QUAST comparison in denovo)

    Platform:
      --platform PLATFORM     mgicyclone | ont | pacbio [default: mgicyclone]
      --flye_mode MODE        Override platform flye mode
      --medaka_model MODEL    Override platform medaka model

    Polishing:
      --use_racon             Enable Racon polishing before Medaka
      --use_nextpolish        Enable NextPolish short-read polishing
      --nextpolish_rounds N   NextPolish rounds, 1-4 [default: 1]

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
            def long_reads = file(row.long_reads)
            def r1         = row.short_reads_1 ? file(row.short_reads_1) : null
            def r2         = row.short_reads_2 ? file(row.short_reads_2) : null
            def gsize      = row.genome_size   ?: params.genome_size
            if (!gsize) error "genome_size missing for sample ${sample}"
            [sample, long_reads, r1, r2, gsize]
        }
}

// ─── main workflow ───────────────────────────────────────────────────────────

workflow {

    if (params.help) { help_message(); exit 0 }

    // resolve platform defaults
    def flye_mode    = resolved_flye_mode(params)
    def medaka_model = resolved_medaka_model(params)

    // ── build input channel ──────────────────────────────────────────────────
    def ch_input
    if (params.samplesheet) {
        ch_input = parse_samplesheet(params.samplesheet)
    } else if (params.long_reads) {
        if (!params.genome_size) error "--genome_size is required in single-sample mode"
        def r1 = params.short_reads_1 ? file(params.short_reads_1) : null
        def r2 = params.short_reads_2 ? file(params.short_reads_2) : null
        ch_input = Channel.of([
            params.sample_name,
            file(params.long_reads),
            r1, r2,
            params.genome_size
        ])
    } else {
        error "Provide --long_reads or --samplesheet"
    }

    // ch_input: [sample, long_reads, r1, r2, genome_size]
    def ch_lr    = ch_input.map { s, lr, r1, r2, gs -> tuple(s, lr) }
    def ch_sr    = ch_input.map { s, lr, r1, r2, gs -> tuple(s, r1, r2) }
                           .filter  { s, r1, r2 -> r1 != null }
    def ch_gsize = ch_input.map { s, lr, r1, r2, gs -> tuple(s, gs) }

    // ── long-read QC ─────────────────────────────────────────────────────────
    NANOFILT(ch_lr)
    def ch_lr_filtered = NANOFILT.out.reads

    if (params.downsample > 0) {
        SEQKIT_DOWNSAMPLE(ch_lr_filtered)
        ch_lr_filtered = SEQKIT_DOWNSAMPLE.out.reads
    }

    // ── short-read QC ────────────────────────────────────────────────────────
    def ch_sr_clean = Channel.empty()
    if (params.use_nextpolish || params.assembler == 'unicycler') {
        FASTP(ch_sr)
        ch_sr_clean = FASTP.out.reads
    }

    // ── reference channel for QUAST ──────────────────────────────────────────
    def ch_reference = params.reference ? Channel.fromPath(params.reference) : Channel.value([])

    // ─────────────────────────────────────────────────────────────────────────
    // DENOVO MODE
    // ─────────────────────────────────────────────────────────────────────────
    if (params.mode == 'denovo') {

        def ch_draft

        if (params.assembler == 'unicycler') {
            // unicycler needs long + short reads
            def ch_uni_input = ch_lr_filtered.join(ch_sr_clean)
            UNICYCLER(ch_uni_input)
            ch_draft = UNICYCLER.out.assembly

        } else {
            // flye: join with genome_size per sample
            def ch_flye_input = ch_lr_filtered.join(ch_gsize)
            FLYE(ch_flye_input, flye_mode)
            ch_draft = FLYE.out.assembly
        }

        // optional Racon
        if (params.use_racon) {
            RACON(ch_lr_filtered.join(ch_draft))
            ch_draft = RACON.out.assembly
        }

        // Medaka (skip for PacBio)
        if (params.platform != 'pacbio') {
            MEDAKA(ch_lr_filtered.join(ch_draft), medaka_model)
            ch_draft = MEDAKA.out.assembly
        }

        // optional NextPolish
        if (params.use_nextpolish) {
            NEXTPOLISH(ch_draft.join(ch_sr_clean), params.nextpolish_rounds)
            ch_draft = NEXTPOLISH.out.assembly
        }

        QUAST(ch_draft, ch_reference)

    // ─────────────────────────────────────────────────────────────────────────
    // REFERENCE MODE
    // ─────────────────────────────────────────────────────────────────────────
    } else if (params.mode == 'reference') {

        if (!params.reference) error "--reference is required in reference mode"

        def ch_ref_draft = Channel.fromPath(params.reference)
            .map { f -> tuple(params.sample_name, f) }

        // combine per-sample lr with the reference draft
        def ch_medaka_input = ch_lr_filtered.combine(ch_ref_draft, by: 0)

        MEDAKA(ch_medaka_input, medaka_model)
        def ch_draft = MEDAKA.out.assembly

        if (params.use_nextpolish) {
            NEXTPOLISH(ch_draft.join(ch_sr_clean), params.nextpolish_rounds)
            ch_draft = NEXTPOLISH.out.assembly
        }

        QUAST(ch_draft, ch_reference)

    } else {
        error "Unknown --mode '${params.mode}'. Use 'denovo' or 'reference'."
    }
}
