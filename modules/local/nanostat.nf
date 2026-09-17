// By João Pitta (jlpitta82@gmail.com) and Beatriz Toscano (beatriz.melo@fiocruz.br)
// At Fiocruz-PE
process NANOSTAT_RAW {
    tag { sample }
    errorStrategy 'ignore'
    label 'process_low'
    conda "${projectDir}/envs/bacflow-tools"
    publishDir { "${params.outdir}/${sample}/qc/nanostat_raw" }, mode: 'copy'

    input:
    tuple val(sample), path(reads)

    output:
    path "${sample}.nanostat_raw.txt", emit: report

    script:
    """
    NanoStat --fastq ${reads} --threads ${task.cpus} > ${sample}.nanostat_raw.txt
    """

    stub:
    """
    touch ${sample}.nanostat_raw.txt
    """
}

process NANOSTAT_TRIMMED {
    tag { sample }
    errorStrategy 'ignore'
    label 'process_low'
    conda "${projectDir}/envs/bacflow-tools"
    publishDir { "${params.outdir}/${sample}/qc/nanostat_trimmed" }, mode: 'copy'

    input:
    tuple val(sample), path(reads)

    output:
    path "${sample}.nanostat_trimmed.txt", emit: report

    script:
    """
    NanoStat --fastq ${reads} --threads ${task.cpus} > ${sample}.nanostat_trimmed.txt
    """

    stub:
    """
    touch ${sample}.nanostat_trimmed.txt
    """
}
