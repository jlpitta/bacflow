// By João Pitta (jlpitta82@gmail.com) and Beatriz Toscano (beatriz.melo@fiocruz.br)
// At Fiocruz-PE
process MATCH_ORGANISM {
    tag { sample }
    label 'process_low'
    conda "${System.getenv('HOME')}/miniforge3/envs/bacflow-bakta"
    publishDir { "${params.outdir}/${sample}/taxonomy/amrfinder_organism" }, mode: 'copy'

    input:
    tuple val(sample), path(gtdbtk_output)

    output:
    tuple val(sample), path("organism.txt"), emit: organism

    script:
    """
    gtdb_to_amrfinder_organism.py \
        --gtdbtk-summary ${gtdbtk_output}/${sample}.bac120.summary.tsv \
        --amrfinder-db ${params.amrfinder_db} \
        > organism.txt
    """
}

// Nucleotide-only baseline, no --organism -- run on the pre-polish assembly
// (Flye path only, mirrors QUAST_PREPOLISH) so the dashboard can later show
// which AMR genes polishing rescued from a frameshift/indel.
process AMRFINDER_PREPOLISH {
    tag { sample }
    label 'process_low'
    conda "${System.getenv('HOME')}/miniforge3/envs/bacflow-bakta"
    publishDir { "${params.outdir}/${sample}/amr/amrfinder_prepolish" }, mode: 'copy'

    input:
    tuple val(sample), path(assembly)

    output:
    tuple val(sample), path("${sample}.amrfinder_prepolish.tsv"), emit: report

    script:
    """
    amrfinder \
        -n ${assembly} \
        -d ${params.amrfinder_db} \
        --threads ${task.cpus} \
        -o ${sample}.amrfinder_prepolish.tsv
    """
}

// Full mode: nucleotide + protein + GFF from Bakta, organism-aware when
// MATCH_ORGANISM found one. Runs on the final assembly, both paths merged --
// same scope as BAKTA/GTDBTK, no pre/post split needed here (only the
// nucleotide-only baseline above needs one).
//
// Must use Bakta's OWN .fna as -n, not the original assembly: Bakta renames
// contigs internally (e.g. "contig_1"), and its .gff3 references those
// renamed ids -- feeding the original assembly here causes a
// "GFF contig id ... is not in the DNA FASTA file" error (confirmed by
// testing before wiring this in).
process AMRFINDER_POSTPOLISH {
    tag { sample }
    label 'process_low'
    conda "${System.getenv('HOME')}/miniforge3/envs/bacflow-bakta"
    publishDir { "${params.outdir}/${sample}/amr/amrfinder_postpolish" }, mode: 'copy'

    input:
    tuple val(sample), path(bakta_output), val(organism)

    output:
    tuple val(sample), path("${sample}.amrfinder_postpolish.tsv"), emit: report

    script:
    def org_arg = organism ? "-O ${organism}" : ""
    """
    amrfinder \
        -n ${bakta_output}/${sample}.fna \
        -p ${bakta_output}/${sample}.faa \
        -g ${bakta_output}/${sample}.gff3 \
        -a bakta \
        -d ${params.amrfinder_db} \
        ${org_arg} \
        --threads ${task.cpus} \
        -o ${sample}.amrfinder_postpolish.tsv
    """
}
