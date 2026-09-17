// By João Pitta (jlpitta82@gmail.com) and Beatriz Toscano (beatriz.melo@fiocruz.br)
// At Fiocruz-PE
process GTDBTK {
    tag { sample }
    errorStrategy 'ignore'
    label 'process_medium'
    conda "${projectDir}/envs/bacflow-gtdbtk"
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

    stub:
    """
    mkdir -p gtdbtk_output
    touch gtdbtk_output/${sample}.bac120.summary.tsv
    """
}
