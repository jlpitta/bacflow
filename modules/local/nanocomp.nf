// By João Pitta (jlpitta82@gmail.com) and Beatriz Toscano (beatriz.melo@fiocruz.br)
// At Fiocruz-PE
process NANOCOMP {
    tag { sample }
    label 'process_low'
    conda "${System.getenv('HOME')}/miniforge3/envs/bacflow-tools"
    publishDir { "${params.outdir}/${sample}/qc/nanocomp" }, mode: 'copy'

    input:
    tuple val(sample), path(raw_reads), path(trimmed_reads)

    output:
    tuple val(sample), path("NanoComp-report.html"), path("NanoStats.txt"), emit: report

    script:
    """
    NanoComp \
        --fastq ${raw_reads} ${trimmed_reads} \
        --names raw trimmed \
        --outdir . \
        --threads ${task.cpus}
    """
}
