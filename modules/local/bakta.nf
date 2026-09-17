// By João Pitta (jlpitta82@gmail.com) and Beatriz Toscano (beatriz.melo@fiocruz.br)
// At Fiocruz-PE
process BAKTA {
    tag { sample }
    errorStrategy 'ignore'
    label 'process_medium'
    conda "${projectDir}/envs/bacflow-bakta"
    publishDir { "${params.outdir}/${sample}/annotation/bakta" }, mode: 'copy'

    input:
    tuple val(sample), path(assembly)

    output:
    tuple val(sample), path("bakta_output"), emit: report

    script:
    """
    bakta \
        --db ${params.bakta_db} \
        --prefix ${sample} \
        --output bakta_output \
        --threads ${task.cpus} \
        --force \
        ${assembly}
    """

    stub:
    """
    mkdir -p bakta_output
    touch bakta_output/${sample}.fna bakta_output/${sample}.faa bakta_output/${sample}.gff3
    """
}
