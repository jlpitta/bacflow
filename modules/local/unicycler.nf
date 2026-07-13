// By João Pitta (jlpitta82@gmail.com) and Beatriz Toscano (beatriz.melo@fiocruz.br)
// At Fiocruz-PE
process UNICYCLER {
    tag "$sample"
    label 'process_high'
    conda 'bacflow-tools'
    publishDir "${params.outdir}/${sample}/assembly/unicycler", mode: 'copy'

    input:
    tuple val(sample), path(r1), path(r2)

    output:
    tuple val(sample), path("${sample}.assembly.fasta"), emit: assembly

    script:
    """
    unicycler \
        -1 ${r1} -2 ${r2} \
        -o unicycler_output \
        --threads ${task.cpus}

    cp unicycler_output/assembly.fasta ${sample}.assembly.fasta
    """
}
