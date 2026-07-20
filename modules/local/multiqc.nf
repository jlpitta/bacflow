// By João Pitta (jlpitta82@gmail.com) and Beatriz Toscano (beatriz.melo@fiocruz.br)
// At Fiocruz-PE
process MULTIQC {
    label 'process_low'
    conda "${System.getenv('HOME')}/miniforge3/envs/bacflow-tools"
    publishDir { "${params.outdir}/multiqc" }, mode: 'copy'

    input:
    val ready
    val outdir_abs

    output:
    path "multiqc_report.html", emit: report
    path "multiqc_data", emit: data

    script:
    """
    ln -s ${outdir_abs} outdir_link

    multiqc outdir_link \
        --dirs --dirs-depth -2 \
        --ignore '*busco*' \
        --ignore '*nanocomp*' \
        --outdir . \
        --force
    """
}
