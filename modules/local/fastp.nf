// By João Pitta (jlpitta82@gmail.com) and Beatriz Toscano (beatriz.melo@fiocruz.br)
// At Fiocruz-PE
process FASTP {
    tag { sample }
    errorStrategy 'ignore'
    label 'process_low'
    conda "${projectDir}/envs/bacflow-tools"
    publishDir { "${params.outdir}/${sample}/qc/fastp" }, mode: 'copy'

    input:
    tuple val(sample), path(r1), path(r2)

    output:
    tuple val(sample), path("${sample}_R1.clean.fastq.gz"), path("${sample}_R2.clean.fastq.gz"), emit: reads
    path "${sample}.fastp.json", emit: json
    path "${sample}.fastp.html", emit: html

    script:
    """
    fastp \
        -i ${r1} -I ${r2} \
        -o ${sample}_R1.clean.fastq.gz \
        -O ${sample}_R2.clean.fastq.gz \
        --json ${sample}.fastp.json \
        --html ${sample}.fastp.html \
        --qualified_quality_phred 20 \
        --length_required 50 \
        --thread ${task.cpus}
    """

    stub:
    """
    touch ${sample}_R1.clean.fastq.gz ${sample}_R2.clean.fastq.gz ${sample}.fastp.json ${sample}.fastp.html
    """
}
