// By João Pitta (jlpitta82@gmail.com) and Beatriz Toscano (beatriz.melo@fiocruz.br)
// At Fiocruz-PE
process FLYE {
    tag "$sample"
    label 'process_high'
    conda 'bacflow-tools'
    publishDir "${params.outdir}/${sample}/assembly/flye", mode: 'copy'

    input:
    tuple val(sample), path(reads)
    val flye_mode
    val genome_size

    output:
    tuple val(sample), path("${sample}.assembly.fasta"), emit: assembly
    path "flye_output/assembly_info.txt", emit: info

    script:
    """
    flye \
        --${flye_mode} ${reads} \
        --genome-size ${genome_size} \
        --out-dir flye_output \
        --threads ${task.cpus}

    cp flye_output/assembly.fasta ${sample}.assembly.fasta
    """
}
