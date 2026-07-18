// By João Pitta (jlpitta82@gmail.com) and Beatriz Toscano (beatriz.melo@fiocruz.br)
// At Fiocruz-PE
process FASTQC_RAW {
    tag { sample }
    label 'process_low'
    conda "${System.getenv('HOME')}/miniforge3/envs/bacflow-tools"
    publishDir { "${params.outdir}/${sample}/qc/fastqc_raw" }, mode: 'copy'

    input:
    tuple val(sample), path(r1), path(r2)

    output:
    tuple val(sample), path("*.html"), path("*.zip"), emit: reports

    script:
    """
    fastqc ${r1} ${r2} --threads ${task.cpus} --outdir .
    """
}

process FASTQC_TRIMMED {
    tag { sample }
    label 'process_low'
    conda "${System.getenv('HOME')}/miniforge3/envs/bacflow-tools"
    publishDir { "${params.outdir}/${sample}/qc/fastqc_trimmed" }, mode: 'copy'

    input:
    tuple val(sample), path(r1), path(r2)

    output:
    tuple val(sample), path("*.html"), path("*.zip"), emit: reports

    script:
    """
    fastqc ${r1} ${r2} --threads ${task.cpus} --outdir .
    """
}
