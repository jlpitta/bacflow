process RACON {
    tag "$sample"
    label 'process_medium'
    conda 'nextassembler-tools'
    publishDir "${params.outdir}/${sample}/polishing/racon", mode: 'copy'

    input:
    tuple val(sample), path(reads), path(assembly)

    output:
    tuple val(sample), path("${sample}.racon.fasta"), emit: assembly

    script:
    """
    minimap2 -x map-ont -t ${task.cpus} ${assembly} ${reads} > overlaps.paf

    racon \
        --threads ${task.cpus} \
        ${reads} overlaps.paf ${assembly} > ${sample}.racon.fasta
    """
}
