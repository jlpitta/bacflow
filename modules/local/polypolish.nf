// By João Pitta (jlpitta82@gmail.com) and Beatriz Toscano (beatriz.melo@fiocruz.br)
// At Fiocruz-PE
process POLYPOLISH {
    tag "$sample"
    label 'process_medium'
    conda 'bacflow-tools'
    publishDir "${params.outdir}/${sample}/polishing/polypolish", mode: 'copy'

    input:
    tuple val(sample), path(assembly), path(r1), path(r2)

    output:
    tuple val(sample), path("${sample}.polypolish.fasta"), emit: assembly

    script:
    """
    bwa index ${assembly}
    bwa mem -t ${task.cpus} -a ${assembly} ${r1} > r1.sam
    bwa mem -t ${task.cpus} -a ${assembly} ${r2} > r2.sam

    polypolish filter \
        --in1 r1.sam --in2 r2.sam \
        --out1 filtered_r1.sam --out2 filtered_r2.sam

    polypolish polish ${assembly} filtered_r1.sam filtered_r2.sam \
        > ${sample}.polypolish.fasta
    """
}
