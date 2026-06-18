# nextassembler

Pipeline [Nextflow](https://www.nextflow.io/) DSL2 para **montagem de genomas long-read com polishing híbrido** (long reads + short reads Illumina). Combina ferramentas de montagem, polishing e avaliação de qualidade em um fluxo automatizado com gerenciamento de ambientes Conda.


---

## Sumário

- [Visão geral](#visão-geral)
- [Instalação](#instalação)
- [Ambientes Conda](#ambientes-conda)
- [Plataformas suportadas](#plataformas-suportadas)
- [Modos de execução](#modos-de-execução)
- [Modos de input](#modos-de-input)
- [Parâmetros](#parâmetros)
- [Os 8 fluxos de execução](#os-8-fluxos-de-execução)
- [Controle de CPUs](#controle-de-cpus)
- [Profiles (gerenciador de pacotes)](#profiles-gerenciador-de-pacotes)
- [Estrutura de arquivos](#estrutura-de-arquivos)
- [Regras importantes](#regras-importantes)

---

## Visão geral

```
Long reads ──► NanoFilt ──────────────────────────────────────────────────┐
                                                                           │
Short reads ─► FASTP ──► R1.clean + R2.clean  (paralelo ao NanoFilt)      │
                              │                                            │
                              │          [Flye] ou [Unicycler]  ◄── lr.filtered
                              │                    │
                              │           [Racon]  (opcional)
                              │                    │
                              │           [Medaka] ◄── lr.filtered
                              │                    │
                              └──► [Polypolish] ou [NextPolish]  (opcional)
                                                   │
                                               [QUAST]
                                                   │
                                          relatório de qualidade
```

### Ferramentas utilizadas

| Etapa | Ferramenta | Função |
|---|---|---|
| Filtragem long reads | NanoFilt | Q-score ≥ 10, comprimento ≥ 500 bp |
| Filtragem short reads | FASTP | Q ≥ 20, comprimento ≥ 50 bp |
| Downsampling | SeqKit | Limitar número de reads (opcional) |
| Montagem | Flye / Unicycler | Montagem *de novo* |
| Polishing long reads | Racon | Polishing rápido pré-Medaka (opcional) |
| Polishing long reads | Medaka 1.11.3 | Correção de erros com modelo de rede neural |
| Polishing short reads | **Polypolish** (padrão) | Correção final com Illumina, base a base |
| Polishing short reads | NextPolish (alternativa) | Correção multi-round com Illumina (`--polisher nextpolish`) |
| Avaliação | QUAST | Métricas de qualidade da montagem |

---

## Instalação

### Pré-requisitos

- [Mamba](https://mamba.readthedocs.io/) ou [Conda](https://docs.conda.io/)

> O Nextflow é instalado automaticamente dentro do ambiente `nextassembler-tools`. Não é necessário instalá-lo separadamente.

### Clonar e instalar ambientes

```bash
git clone https://github.com/jlpitta/nextassembler
cd nextassembler

# instalar os ambientes conda (obrigatório antes da primeira execução)
bash install_envs.sh
```

O script instala dois ambientes e exibe instruções para configurar o `nextflow` no terminal. Há duas opções:

**Opção A — alias permanente** (recomendado): adicione ao `~/.bashrc`:
```bash
alias nextflow='mamba run -n nextassembler-tools nextflow'
```
Depois: `source ~/.bashrc`. A partir daí `nextflow` funciona diretamente em qualquer terminal.

**Opção B — ativar o ambiente manualmente** antes de cada uso:
```bash
mamba activate nextassembler-tools
nextflow run nextassembler.nf ...
```

```bash
# verificar ambientes instalados
mamba env list | grep nextassembler
# nextassembler-tools   ~/.conda/envs/nextassembler-tools
# nextassembler-medaka  ~/.conda/envs/nextassembler-medaka
```

> **Importante:** os módulos referenciam os ambientes pelo **nome fixo** (`nextassembler-tools` / `nextassembler-medaka`), não pelo caminho do YAML. A pré-instalação é obrigatória antes da primeira execução.

---

## Ambientes Conda

| Ambiente | YAML | Ferramentas |
|---|---|---|
| `nextassembler-tools` | `envs/tools.yaml` | nextflow, nanofilt, fastp, flye, unicycler, minimap2, racon, seqkit, samtools, polypolish, nextpolish, bwa, quast, multiqc, nanostat |
| `nextassembler-medaka` | `envs/medaka.yaml` | medaka=1.11.3 (**isolada** — conflito TensorFlow/ONNX com bioconda) |

O Medaka é mantido em ambiente isolado obrigatoriamente, pois suas dependências (TensorFlow, ONNX) conflitam com pacotes do canal bioconda.

---

## Plataformas suportadas

Definido com `--platform` (padrão: `mgicyclone`):

| Valor | Modo Flye | Modelo Medaka |
|---|---|---|
| `mgicyclone` | `nano-raw` | `r941_min_hac_g507` |
| `ont` | `nano-hq` | `r1041_e82_400bps_hac_g632` |
| `pacbio` | `pacbio-hifi` | *(sem Medaka)* |

---

## Modos de execução

### `--mode denovo` (padrão)

Monta o genoma do zero com Flye ou Unicycler, seguido de polishing com Medaka e opcionalmente Polypolish ou NextPolish.

### `--mode reference`

Usa um genoma de referência (`--reference ref.fasta`) como draft direto para o Medaka, pulando a etapa de montagem. Indicado para organismos bem caracterizados. Para espécies com alta divergência, prefira `denovo`.

---

## Modos de input

O pipeline aceita duas formas de entrada, mutuamente exclusivas:

### Single-sample — parâmetros diretos

```bash
nextflow run nextassembler.nf -resume \
    --t 32 \
    --long_reads lr.fastq.gz \
    --genome_size 5m \
    --sample_name amostra01 \
    --short_reads_1 r1.fastq.gz \
    --short_reads_2 r2.fastq.gz
```

### Multi-sample — samplesheet CSV

```bash
nextflow run nextassembler.nf -resume \
    --t 64 \
    --samplesheet samples.csv
```

**Formato do CSV** (colunas `short_reads_1/2` são opcionais por linha):

```csv
sample,long_reads,short_reads_1,short_reads_2,genome_size
amostra01,data/A01/lr.fastq.gz,data/A01/r1.fastq.gz,data/A01/r2.fastq.gz,5m
amostra02,data/A02/lr.fastq.gz,data/A02/r1.fastq.gz,data/A02/r2.fastq.gz,5m
amostra03,data/A03/lr.fastq.gz,,,4.8m
```

- Amostras processadas em **paralelo**, limitadas pelo `--t` global
- `genome_size` pode ser coluna no CSV (por amostra) ou `--genome_size` como parâmetro global
- Saídas em `results/{sample}/`

---

## Parâmetros

| Parâmetro | Padrão | Descrição |
|---|---|---|
| `--mode` | `denovo` | Modo: `denovo` ou `reference` |
| `--long_reads` | — | FASTQ long reads (obrigatório sem samplesheet) |
| `--samplesheet` | — | CSV multi-sample (alternativa a --long_reads) |
| `--short_reads_1` | — | R1 Illumina (obrigatório para unicycler e polishing short-read) |
| `--short_reads_2` | — | R2 Illumina |
| `--genome_size` | — | Tamanho estimado do genoma (ex: `5m`, `4.8m`, `2g`) |
| `--sample_name` | `sample` | Prefixo dos outputs e nome da subpasta em results/ |
| `--assembler` | `flye` | Montador: `flye` ou `unicycler` |
| `--platform` | `mgicyclone` | Plataforma sequenciadora |
| `--use_racon` | `false` | Ativar polishing com Racon antes do Medaka |
| `--polisher` | `polypolish` | Polidor short-read: `polypolish` (padrão), `nextpolish` ou `none` |
| `--nextpolish_rounds` | `1` | Iterações do NextPolish (1–4; apenas com `--polisher nextpolish`) |
| `--reference` | `null` | Draft para modo `reference`; referência comparativa QUAST no modo `denovo` |
| `--medaka_model` | *(da plataforma)* | Sobrescreve o modelo Medaka padrão |
| `--t` | — | Total de CPUs disponíveis |
| `--min_quality` | `10` | Q-score mínimo NanoFilt |
| `--min_length` | `500` | Comprimento mínimo de reads NanoFilt (bp) |
| `--downsample` | `0` | Máx de reads para montagem (`0` = sem limite; ex: `200000` para economizar RAM) |
| `--outdir` | `results` | Diretório de saída |

---

## Os 8 fluxos de execução

### Modo `denovo` / Flye

**Fluxo 1 — Mínimo: Flye + Medaka**

```bash
nextflow run nextassembler.nf -resume \
    --t 16 \
    --long_reads lr.fastq.gz \
    --genome_size 5m \
    --sample_name amostra01
```

**Fluxo 2 — Com Racon: Flye + Racon + Medaka**

```bash
nextflow run nextassembler.nf -resume \
    --t 16 \
    --long_reads lr.fastq.gz \
    --genome_size 5m \
    --sample_name amostra01 \
    --use_racon
```

**Fluxo 3 — Padrão-ouro: Flye + Medaka + Polypolish**

```bash
nextflow run nextassembler.nf -resume \
    --t 32 \
    --long_reads lr.fastq.gz \
    --short_reads_1 r1.fastq.gz \
    --short_reads_2 r2.fastq.gz \
    --genome_size 5m \
    --sample_name amostra01
```

> Polypolish é o padrão quando short reads são fornecidas. Nenhum parâmetro extra necessário.

**Fluxo 4 — Completo: Flye + Racon + Medaka + Polypolish**

```bash
nextflow run nextassembler.nf -resume \
    --t 32 \
    --long_reads lr.fastq.gz \
    --short_reads_1 r1.fastq.gz \
    --short_reads_2 r2.fastq.gz \
    --genome_size 5m \
    --sample_name amostra01 \
    --use_racon
```

### Modo `denovo` / Unicycler

> Short reads são **obrigatórios** com Unicycler. Polypolish roda por padrão após o Medaka.

**Fluxo 5 — Unicycler + Medaka + Polypolish**

```bash
nextflow run nextassembler.nf -resume \
    --t 32 \
    --long_reads lr.fastq.gz \
    --short_reads_1 r1.fastq.gz \
    --short_reads_2 r2.fastq.gz \
    --genome_size 5m \
    --sample_name amostra01 \
    --assembler unicycler
```

**Fluxo 6 — Unicycler + Racon + Medaka + Polypolish**

```bash
nextflow run nextassembler.nf -resume \
    --t 32 \
    --long_reads lr.fastq.gz \
    --short_reads_1 r1.fastq.gz \
    --short_reads_2 r2.fastq.gz \
    --genome_size 5m \
    --sample_name amostra01 \
    --assembler unicycler \
    --use_racon
```

### Modo `reference`

**Fluxo 7 — Referência + Medaka**

```bash
nextflow run nextassembler.nf -resume \
    --t 16 \
    --mode reference \
    --long_reads lr.fastq.gz \
    --reference ref.fasta \
    --sample_name amostra01
```

**Fluxo 8 — Referência + Medaka + Polypolish**

```bash
nextflow run nextassembler.nf -resume \
    --t 32 \
    --mode reference \
    --long_reads lr.fastq.gz \
    --short_reads_1 r1.fastq.gz \
    --short_reads_2 r2.fastq.gz \
    --reference ref.fasta \
    --sample_name amostra01
```

### Usar NextPolish em vez de Polypolish

Para qualquer fluxo que utilize short reads, substitua o polidor padrão com:

```bash
--polisher nextpolish
# opcional: --nextpolish_rounds 3
```

---

## Qual fluxo escolher?

```
Tenho só long reads?
  └─► Fluxo 1 (Flye + Medaka) — mínimo viável

Tenho long + short reads?
  └─► Fluxo 3 (Flye + Medaka + Polypolish) — padrão-ouro
      └─► Máxima qualidade: Fluxo 4 (+ Racon)

Genoma bem caracterizado / referência confiável disponível?
  └─► Fluxo 7 ou 8 (modo reference) — mais rápido

Organismo com muitos repetidos / genoma complexo?
  └─► Fluxos 5 ou 6 (Unicycler + short reads obrigatório)

Várias amostras ao mesmo tempo?
  └─► Qualquer fluxo acima com --samplesheet samples.csv
```

---

## Controle de CPUs

O parâmetro `--t` define o total de CPUs disponíveis. O pipeline distribui automaticamente:

| Nível | Processos | CPUs |
|---|---|---|
| `process_low` | NanoFilt, FASTP, QUAST | `t / 4` |
| `process_medium` | Racon, Medaka, Polypolish, NextPolish | `t / 2` |
| `process_high` | Flye | `t` (todos) |

Exemplo com `--t 32`: NanoFilt + FASTP rodam em paralelo (8 + 8 CPUs), Flye usa todas as 32.

---

## Profiles (gerenciador de pacotes)

**Mamba é o padrão** — configurado diretamente no `nextflow.config`. Profiles servem apenas para sobrescrever quando necessário.

```groovy
// nextflow.config
conda.enabled  = true
conda.useMamba = true   // mamba é o default

profiles {
    conda      { conda.useMamba = false }
    mamba      { /* igual ao padrão */ }
    micromamba { conda.mambaBin = 'micromamba' }
}
```

| Situação | Comando |
|---|---|
| Mamba (padrão) | `nextflow run nextassembler.nf ...` |
| Conda | `nextflow run nextassembler.nf -profile conda ...` |
| Micromamba | `nextflow run nextassembler.nf -profile micromamba ...` |

---

## Estrutura de arquivos

```
nextassembler/
├── nextassembler.nf          # script principal DSL2
├── nextflow.config           # configuração global, parâmetros, profiles, CPUs
├── install_envs.sh           # pré-instala os ambientes conda
├── conf/
│   └── bioinfo2.config       # configuração de recursos para o servidor bioinfo2
├── envs/
│   ├── tools.yaml            # → nextassembler-tools
│   └── medaka.yaml           # → nextassembler-medaka (isolada)
└── modules/local/
    ├── nanofilt.nf
    ├── fastp.nf
    ├── seqkit_downsample.nf
    ├── flye.nf
    ├── unicycler.nf
    ├── racon.nf
    ├── medaka.nf
    ├── polypolish.nf
    ├── nextpolish.nf
    └── quast.nf
```

---

## Regras importantes

| Regra | Motivo |
|---|---|
| **Nunca** rodar Racon após Medaka | Racon reintroduz erros que o Medaka já corrigiu |
| **Nunca** rodar Polypolish após NextPolish | Degrada a qualidade — a ordem importa |
| **Sempre** manter Medaka em ambiente isolado | TensorFlow/ONNX conflita com pacotes bioconda |
| **Sempre** pré-instalar os envs antes de rodar | Módulos referenciam pelo nome, não pelo YAML |
| Usar `-resume` sempre que possível | Retoma do ponto onde parou sem reprocessar etapas concluídas |

---

## Dicas de uso

**Retomar execução interrompida:**
```bash
nextflow run nextassembler.nf -resume ...
# requer: process.cache = lenient  +  workDir fixo no nextflow.config
```

**Economizar RAM com genomas grandes:**
```bash
--downsample 200000
```

**Usar NextPolish com múltiplos rounds:**
```bash
--polisher nextpolish --nextpolish_rounds 3
```

**Desativar polimento short-read:**
```bash
--polisher none
```

**Modelo Medaka personalizado:**
```bash
--medaka_model r1041_e82_400bps_sup_g615
```

**Usar referência como comparativo no QUAST (modo denovo):**
```bash
--reference referencia_conhecida.fasta
```

---

## Referência

Luan, T. et al. (2024). *A hybrid genome assembly and polishing pipeline for long-read sequencing data*. BMC Genomics, 25, 742.
[https://doi.org/10.1186/s12864-024-10582-x](https://doi.org/10.1186/s12864-024-10582-x)
