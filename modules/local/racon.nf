// By João Pitta (jlpitta82@gmail.com) and Beatriz Toscano (beatriz.melo@fiocruz.br)
// At Fiocruz-PE
process RACON {
    tag { sample }
    errorStrategy 'ignore'
    label 'process_medium'
    conda "${projectDir}/envs/bacflow-tools"
    publishDir { "${params.outdir}/${sample}/polishing/racon" }, mode: 'copy'

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

    stub:
    """
    echo ">stub_contig_1" > ${sample}.racon.fasta
    echo "ACGT" >> ${sample}.racon.fasta
    """
}
