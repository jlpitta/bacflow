// By João Pitta (jlpitta82@gmail.com) and Beatriz Toscano (beatriz.melo@fiocruz.br)
// At Fiocruz-PE
process FLYE {
    tag { sample }
    errorStrategy 'ignore'
    label 'process_high'
    conda "${projectDir}/envs/bacflow-tools"
    publishDir { "${params.outdir}/${sample}/assembly/flye" }, mode: 'copy'

    input:
    tuple val(sample), path(reads), val(genome_size)
    val flye_mode

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

    stub:
    """
    mkdir -p flye_output
    echo ">stub_contig_1" > ${sample}.assembly.fasta
    echo "ACGT" >> ${sample}.assembly.fasta
    echo -e "seq_name\tlength\tcov.\tcirc.\trepeat\tmult.\talt_group\tgraph_path" > flye_output/assembly_info.txt
    """
}
