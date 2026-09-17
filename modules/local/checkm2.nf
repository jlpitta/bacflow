// By João Pitta (jlpitta82@gmail.com) and Beatriz Toscano (beatriz.melo@fiocruz.br)
// At Fiocruz-PE
process CHECKM2 {
    tag { sample }
    errorStrategy 'ignore'
    label 'process_medium'
    conda "${projectDir}/envs/bacflow-checkm2"
    publishDir { "${params.outdir}/${sample}/qc/checkm2" }, mode: 'copy'

    input:
    tuple val(sample), path(assembly)

    output:
    tuple val(sample), path("checkm2_output"), emit: report

    script:
    """
    checkm2 predict \
        --input ${assembly} \
        --output-directory checkm2_output \
        --database_path ${params.checkm2_db} \
        --threads ${task.cpus} \
        -x fasta
    """

    stub:
    """
    mkdir -p checkm2_output
    touch checkm2_output/quality_report.tsv
    """
}

process CHECKM2_PREPOLISH {
    tag { sample }
    errorStrategy 'ignore'
    label 'process_medium'
    conda "${projectDir}/envs/bacflow-checkm2"
    publishDir { "${params.outdir}/${sample}/qc/checkm2_prepolish" }, mode: 'copy'

    input:
    tuple val(sample), path(assembly)

    output:
    tuple val(sample), path("checkm2_output"), emit: report

    script:
    """
    checkm2 predict \
        --input ${assembly} \
        --output-directory checkm2_output \
        --database_path ${params.checkm2_db} \
        --threads ${task.cpus} \
        -x fasta
    """

    stub:
    """
    mkdir -p checkm2_output
    touch checkm2_output/quality_report.tsv
    """
}

process CHECKM2_POSTPOLISH {
    tag { sample }
    errorStrategy 'ignore'
    label 'process_medium'
    conda "${projectDir}/envs/bacflow-checkm2"
    publishDir { "${params.outdir}/${sample}/qc/checkm2_postpolish" }, mode: 'copy'

    input:
    tuple val(sample), path(assembly)

    output:
    tuple val(sample), path("checkm2_output"), emit: report

    script:
    """
    checkm2 predict \
        --input ${assembly} \
        --output-directory checkm2_output \
        --database_path ${params.checkm2_db} \
        --threads ${task.cpus} \
        -x fasta
    """

    stub:
    """
    mkdir -p checkm2_output
    touch checkm2_output/quality_report.tsv
    """
}
