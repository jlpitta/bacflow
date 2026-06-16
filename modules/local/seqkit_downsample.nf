process SEQKIT_DOWNSAMPLE {
    tag "$sample"
    label 'process_low'
    conda 'nextassembler-tools'

    input:
    tuple val(sample), path(reads)

    output:
    tuple val(sample), path("${sample}.downsampled.fastq.gz"), emit: reads

    script:
    """
    seqkit head -n ${params.downsample} ${reads} -o ${sample}.downsampled.fastq.gz
    """
}
