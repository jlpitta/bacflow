// By João Pitta (jlpitta82@gmail.com) and Beatriz Toscano (beatriz.melo@fiocruz.br)
// At Fiocruz-PE
process NANOFILT {
    tag { sample }
    label 'process_low'
    conda 'bacflow-tools'
    publishDir { "${params.outdir}/${sample}/qc/nanofilt" }, mode: 'copy'

    input:
    tuple val(sample), path(reads)

    output:
    tuple val(sample), path("${sample}.filtered.fastq.gz"), emit: reads

    script:
    """
    NanoFilt -q ${params.min_quality} -l ${params.min_length} \
        <(zcat ${reads}) | gzip > ${sample}.filtered.fastq.gz
    """
}
