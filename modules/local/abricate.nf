// By João Pitta (jlpitta82@gmail.com) and Beatriz Toscano (beatriz.melo@fiocruz.br)
// At Fiocruz-PE
//
// Virulence factors via VFDB (Virulence Factor Database), complementing
// AMRFinderPlus's --plus virulence search: AMRFinderPlus's virulence gene set
// is curated for a small handful of organisms (Escherichia, Klebsiella
// pneumoniae, Staphylococcus aureus, Vibrio cholerae, Campylobacter,
// Salmonella), so genomes outside that group come back with 0 virulence hits
// even with --plus -- not because the genes are absent, but because the
// database has no coverage for that organism. VFDB has much broader
// taxonomic coverage for virulence factors specifically. Runs on the final
// assembly, both paths merged -- same scope as BAKTA/GTDBTK.
process ABRICATE {
    tag { sample }
    errorStrategy 'ignore'
    label 'process_low'
    conda "${projectDir}/envs/bacflow-abricate"
    publishDir { "${params.outdir}/${sample}/amr/vfdb" }, mode: 'copy'

    input:
    tuple val(sample), path(assembly)

    output:
    tuple val(sample), path("${sample}.vfdb.tsv"), emit: report

    script:
    """
    abricate --db vfdb --threads ${task.cpus} ${assembly} > ${sample}.vfdb.tsv
    """

    stub:
    """
    touch ${sample}.vfdb.tsv
    """
}
