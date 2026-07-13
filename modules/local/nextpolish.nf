// By João Pitta (jlpitta82@gmail.com) and Beatriz Toscano (beatriz.melo@fiocruz.br)
// At Fiocruz-PE
process NEXTPOLISH {
    tag "$sample"
    label 'process_medium'
    conda 'bacflow-tools'
    publishDir "${params.outdir}/${sample}/polishing/nextpolish", mode: 'copy'

    input:
    tuple val(sample), path(assembly), path(r1), path(r2)
    val rounds

    output:
    tuple val(sample), path("${sample}.nextpolish.fasta"), emit: assembly

    script:
    def task_code = "12" * rounds
    """
    # write reads list
    echo "${r1}" >  sr_input.fofn
    echo "${r2}" >> sr_input.fofn

    cat <<EOF > nextpolish.cfg
[General]
job_type = local
job_prefix = nextpolish
task = ${task_code}
rewrite = yes
rerun = 3
parallel_jobs = 1
multithread_jobs = ${task.cpus}
genome = ${assembly}
genome_size = auto
workdir = np_work
polish_options = -p ${task.cpus}

[sgs_option]
sgs_fofn = sr_input.fofn
sgs_options = -max_depth 100 -bwa
EOF

    nextPolish nextpolish.cfg

    cp np_work/genome.nextpolish.fasta ${sample}.nextpolish.fasta
    """
}
