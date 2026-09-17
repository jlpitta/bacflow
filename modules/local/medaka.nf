// By João Pitta (jlpitta82@gmail.com) and Beatriz Toscano (beatriz.melo@fiocruz.br)
// At Fiocruz-PE
process MEDAKA {
    tag { sample }
    errorStrategy 'ignore'
    label 'process_medium'
    conda "${projectDir}/envs/bacflow-medaka"
    publishDir { "${params.outdir}/${sample}/polishing/medaka" }, mode: 'copy'

    input:
    tuple val(sample), path(reads), path(draft)
    val medaka_model

    output:
    tuple val(sample), path("${sample}.medaka.fasta"), emit: assembly

    script:
    """
    medaka_consensus \
        -i ${reads} \
        -d ${draft} \
        -o medaka_output \
        -m ${medaka_model} \
        -t ${task.cpus}

    cp medaka_output/consensus.fasta ${sample}.medaka.fasta
    """

    stub:
    """
    echo ">stub_contig_1" > ${sample}.medaka.fasta
    echo "ACGT" >> ${sample}.medaka.fasta
    """
}
