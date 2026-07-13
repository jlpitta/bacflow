// By João Pitta (jlpitta82@gmail.com) and Beatriz Toscano (beatriz.melo@fiocruz.br)
// At Fiocruz-PE
process SEQKIT_DOWNSAMPLE {
    tag "$sample"
    label 'process_low'
    conda 'bacflow-tools'

    input:
    tuple val(sample), path(reads)

    output:
    tuple val(sample), path("${sample}.downsampled.fastq.gz"), emit: reads

    script:
    """
    seqkit head -n ${params.downsample} ${reads} -o ${sample}.downsampled.fastq.gz
    """
}
