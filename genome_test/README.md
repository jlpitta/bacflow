# Dados de teste do bacflow

Dois datasets pequenos para validar o pipeline de ponta a ponta sem precisar de dados próprios. Ambos cabem em `--t 4` e rodam em poucos minutos numa máquina comum.

## `mycoplasma_genitalium_synthetic/` — rápido, sintético a partir de sequência real

- **Referência real:** *Mycoplasmoides genitalium* G37, [GCF_000027325.1](https://www.ncbi.nlm.nih.gov/datasets/genome/GCF_000027325.1/) (580 kb — um dos menores genomas bacterianos conhecidos).
- **Reads:** simulados a partir dessa sequência real (não são reads de sequenciador de verdade) — ~40x long reads (erro aleatório ~5%, perfil simplificado, não replica o padrão sistemático real de erro ONT/PacBio) e ~30x short reads (erro ~0.5%).
- **Uso:** smoke test rápido — confirma que o pipeline roda de ponta a ponta e gera todos os relatórios de QC esperados. **Não é adequado para avaliar a qualidade real do polimento** — como os reads não têm o padrão de erro sistemático de um sequenciador de verdade, o Medaka já corrige praticamente tudo sozinho, então os relatórios pré/pós-polish tendem a sair idênticos (não é bug do pipeline, é limitação do dado sintético).

```bash
nextflow run bacflow.nf --t 4 \
    --long_reads genome_test/mycoplasma_genitalium_synthetic/long_reads.fastq.gz \
    --short_reads_1 genome_test/mycoplasma_genitalium_synthetic/short_reads_1.fastq.gz \
    --short_reads_2 genome_test/mycoplasma_genitalium_synthetic/short_reads_2.fastq.gz \
    --genome_size 580000 \
    --sample_name mgenitalium_test \
    --reference genome_test/mycoplasma_genitalium_synthetic/reference.fasta
```

## `staphylococcus_aureus_real/` — mais lento, 100% dados reais de sequenciador

- **Long + short reads:** **mesma cepa real** (*Staphylococcus aureus* JH62PP1, amostra [SAMD00828832](https://www.ebi.ac.uk/ena/browser/view/SAMD00828832) no ENA/DDBJ) — long reads ONT ([DRR613158](https://www.ebi.ac.uk/ena/browser/view/DRR613158)) e short reads Illumina ([DRR613151](https://www.ebi.ac.uk/ena/browser/view/DRR613151)), ambos subamostrados com `seqkit sample` (seed 42) para ~25x de cobertura cada, a partir dos runs completos públicos.
- **Referência:** *Staphylococcus aureus* NCTC 8325, [GCF_000013425.1](https://www.ncbi.nlm.nih.gov/datasets/genome/GCF_000013425.1/) — **cepa diferente** da dos reads (de propósito: no uso real do pipeline raramente se tem uma referência da cepa exata, então isso testa o cenário realista de comparar contra uma referência próxima, não idêntica).
- **Uso:** validação de verdade do polimento com erro real de sequenciador. Resultado observado num run de teste (`--reference` informado, caminho Flye):

  | Métrica | Pré-polish | Pós-polish |
  |---|---|---|
  | Indels /100kbp (QUAST) | 119.96 | 55.69 |
  | CheckM2 Completeness | 90.7% | **100.0%** |
  | CheckM2 Contamination | 8.53% | **0.05%** |

  A queda de completude/contaminação pré-polish é o efeito esperado de indels de long-read causando frameshift (genes fragmentados); o polimento com short reads corrige isso quase totalmente. Mismatches (~1100/100kbp) refletem principalmente divergência genômica real entre as duas cepas, não erro de sequenciamento — por isso ficam altos mesmo pós-polish.

```bash
nextflow run bacflow.nf --t 4 \
    --long_reads genome_test/staphylococcus_aureus_real/long_reads.fastq.gz \
    --short_reads_1 genome_test/staphylococcus_aureus_real/short_reads_1.fastq.gz \
    --short_reads_2 genome_test/staphylococcus_aureus_real/short_reads_2.fastq.gz \
    --genome_size 2.8m \
    --sample_name saureus_test \
    --reference genome_test/staphylococcus_aureus_real/reference.fasta
```

## Sem `--reference`

Ambos os comandos acima também podem ser rodados sem `--reference` (removendo a flag) para exercitar o caminho BUSCO em vez da comparação QUAST baseada em referência.
