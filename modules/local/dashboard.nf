// By João Pitta (jlpitta82@gmail.com) and Beatriz Toscano (beatriz.melo@fiocruz.br)
// At Fiocruz-PE
process SAMPLE_SUMMARY {
    tag { sample }
    label 'process_low'
    conda "${System.getenv('HOME')}/miniforge3/envs/bacflow-tools"
    publishDir { "${params.outdir}/${sample}/qc/dashboard" }, mode: 'copy'

    input:
    tuple val(sample), val(input_type), val(assembler),
          path(quast_pre, stageAs: 'quast_pre'),
          path(quast_post, stageAs: 'quast_post'),
          path(busco_pre, stageAs: 'busco_pre'),
          path(busco_post, stageAs: 'busco_post'),
          path(checkm2_pre, stageAs: 'checkm2_pre'),
          path(checkm2_post, stageAs: 'checkm2_post'),
          path(gtdbtk, stageAs: 'gtdbtk'),
          path(bakta, stageAs: 'bakta'),
          val(organism),
          path(amrfinder_pre, stageAs: 'amrfinder_pre.tsv'),
          path(amrfinder_post, stageAs: 'amrfinder_post.tsv')

    output:
    path "${sample}.summary.json", emit: json

    script:
    def busco_args = busco_pre ? "--busco-pre ${busco_pre} --busco-post ${busco_post}" : ""
    def amrfinder_pre_args = amrfinder_pre ? "--amrfinder-pre ${amrfinder_pre}" : ""
    """
    summarize_sample.py \
        --sample ${sample} \
        --input-type ${input_type} \
        --assembler ${assembler} \
        --quast-pre ${quast_pre} \
        --quast-post ${quast_post} \
        --checkm2-pre ${checkm2_pre} \
        --checkm2-post ${checkm2_post} \
        --gtdbtk ${gtdbtk} \
        --bakta ${bakta} \
        --organism "${organism}" \
        --amrfinder-post ${amrfinder_post} \
        ${busco_args} \
        ${amrfinder_pre_args} \
        --out ${sample}.summary.json
    """
}

process DASHBOARD {
    tag 'dashboard'
    label 'process_low'
    conda "${System.getenv('HOME')}/miniforge3/envs/bacflow-tools"
    publishDir { "${params.outdir}" }, mode: 'copy'

    input:
    path summaries
    val run_commit
    val nextflow_version

    output:
    path "dashboard.html"

    script:
    """
    generate_dashboard.py \
        --summary-dir . \
        --out dashboard.html \
        --run-commit "${run_commit}" \
        --nextflow-version "${nextflow_version}"
    """
}
