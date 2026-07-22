// By João Pitta (jlpitta82@gmail.com) and Beatriz Toscano (beatriz.melo@fiocruz.br)
// At Fiocruz-PE
process CHECKM2 {
    tag { sample }
    label 'process_medium'
    conda "${System.getenv('HOME')}/miniforge3/envs/bacflow-checkm2"
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
}

process CHECKM2_PREPOLISH {
    tag { sample }
    label 'process_medium'
    conda "${System.getenv('HOME')}/miniforge3/envs/bacflow-checkm2"
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
}

process CHECKM2_POSTPOLISH {
    tag { sample }
    label 'process_medium'
    conda "${System.getenv('HOME')}/miniforge3/envs/bacflow-checkm2"
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
}
