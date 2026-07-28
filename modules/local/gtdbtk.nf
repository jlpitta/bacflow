// By João Pitta (jlpitta82@gmail.com) and Beatriz Toscano (beatriz.melo@fiocruz.br)
// At Fiocruz-PE
process GTDBTK {
    tag { sample }
    label 'process_medium'
    conda "${System.getenv('HOME')}/miniforge3/envs/bacflow-gtdbtk"
    publishDir { "${params.outdir}/${sample}/taxonomy/gtdbtk" }, mode: 'copy'

    input:
    tuple val(sample), path(assembly)

    output:
    tuple val(sample), path("gtdbtk_output"), emit: report

    script:
    """
    export GTDBTK_DATA_PATH="${params.gtdbtk_db}"
    gtdbtk classify_wf \
        --genome_dir . \
        --out_dir gtdbtk_output \
        --extension fasta \
        --prefix ${sample} \
        --cpus ${task.cpus}
    """
}
