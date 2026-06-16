process QUAST {
    tag "$sample"
    label 'process_low'
    conda 'nextassembler-tools'
    publishDir "${params.outdir}/${sample}/qc/quast", mode: 'copy'

    input:
    tuple val(sample), path(assembly)
    path reference

    output:
    path "quast_output", emit: report

    script:
    def ref_arg = reference ? "--reference ${reference}" : ""
    """
    quast.py \
        ${assembly} \
        ${ref_arg} \
        --output-dir quast_output \
        --threads ${task.cpus}
    """
}
