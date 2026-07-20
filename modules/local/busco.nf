// By João Pitta (jlpitta82@gmail.com) and Beatriz Toscano (beatriz.melo@fiocruz.br)
// At Fiocruz-PE
process BUSCO {
    tag { sample }
    label 'process_medium'
    conda "${System.getenv('HOME')}/miniforge3/envs/bacflow-tools"
    publishDir { "${params.outdir}/${sample}/qc/busco" }, mode: 'copy'

    input:
    tuple val(sample), path(assembly)

    output:
    path "busco_output", emit: report

    script:
    """
    busco \
        -i ${assembly} \
        -o busco_output \
        -l ${params.busco_lineage} \
        -m genome \
        --cpu ${task.cpus} \
        --out_path .
    """
}

process BUSCO_PREPOLISH {
    tag { sample }
    label 'process_medium'
    conda "${System.getenv('HOME')}/miniforge3/envs/bacflow-tools"
    publishDir { "${params.outdir}/${sample}/qc/busco_prepolish" }, mode: 'copy'

    input:
    tuple val(sample), path(assembly)

    output:
    path "busco_output", emit: report

    script:
    """
    busco \
        -i ${assembly} \
        -o busco_output \
        -l ${params.busco_lineage} \
        -m genome \
        --cpu ${task.cpus} \
        --out_path .
    """
}

process BUSCO_POSTPOLISH {
    tag { sample }
    label 'process_medium'
    conda "${System.getenv('HOME')}/miniforge3/envs/bacflow-tools"
    publishDir { "${params.outdir}/${sample}/qc/busco_postpolish" }, mode: 'copy'

    input:
    tuple val(sample), path(assembly)

    output:
    path "busco_output", emit: report

    script:
    """
    busco \
        -i ${assembly} \
        -o busco_output \
        -l ${params.busco_lineage} \
        -m genome \
        --cpu ${task.cpus} \
        --out_path .
    """
}
