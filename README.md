# bacflow

Pipeline [Nextflow](https://www.nextflow.io/) DSL2 para **montagem de genomas**, com dois caminhos automáticos conforme os dados disponíveis por amostra: **long-read com polishing híbrido** (long reads + short reads Illumina, via Flye) ou **short-read-only** (só Illumina, via Unicycler). Combina ferramentas de montagem, polishing e avaliação de qualidade em um fluxo automatizado com gerenciamento de ambientes Conda.


---

## Sumário

- [Visão geral](#visão-geral)
- [Instalação](#instalação)
- [Ambientes Conda](#ambientes-conda)
- [Plataformas suportadas](#plataformas-suportadas)
- [Modos de execução](#modos-de-execução)
- [Modos de input](#modos-de-input)
- [Parâmetros](#parâmetros)
- [Os 7 fluxos de execução](#os-7-fluxos-de-execução)
- [Controle de CPUs](#controle-de-cpus)
- [Profiles (gerenciador de pacotes)](#profiles-gerenciador-de-pacotes)
- [Estrutura de arquivos](#estrutura-de-arquivos)
- [Regras importantes](#regras-importantes)

---

## Visão geral

O assembler é escolhido **automaticamente por amostra**, sem flag: quem tem
`long_reads` monta com Flye; quem só tem short reads monta com Unicycler.
Uma mesma `--samplesheet` pode misturar livremente amostras híbridas,
long-only e short-only.

```
Amostra tem long_reads?
│
├── SIM ──► NanoFilt ──► [Flye] ──► [Racon] (opc.) ──► [Medaka] ──┐
│                                                                  │
│           Short reads (se houver) ─► FASTP ─► [Polypolish] ou [NextPolish] (opc.)
│                                                                  │
└── NÃO ──► Short reads ─► FASTP ─► [Unicycler] ──────────────────┤
            (short-read-only, sem Racon/Medaka/polish adicional)  │
                                                                   ▼
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
| Montagem (long reads) | Flye | Montagem *de novo* a partir de long reads, com polishing híbrido |
| Montagem (short-read-only) | Unicycler | Montagem *de novo* só com Illumina (baseado em SPAdes), quando não há long reads |
| Polishing long reads | Racon | Polishing rápido pré-Medaka (opcional, só no caminho Flye) |
| Polishing long reads | Medaka 1.11.3 | Correção de erros com modelo de rede neural (só no caminho Flye) |
| Polishing short reads | **Polypolish** (padrão) | Correção final com Illumina, base a base (só no caminho Flye) |
| Polishing short reads | NextPolish (alternativa) | Correção multi-round com Illumina, `--polisher nextpolish` (só no caminho Flye) |
| Avaliação | QUAST | Métricas de qualidade da montagem |

---

## Instalação

### Pré-requisitos

- [Mamba](https://mamba.readthedocs.io/), [Micromamba](https://mamba.readthedocs.io/en/latest/user_guide/micromamba.html) ou [Conda](https://docs.conda.io/) — o script de instalação detecta automaticamente qual está disponível

> O Nextflow é instalado automaticamente dentro do ambiente `bacflow-tools`. Não é necessário instalá-lo separadamente.

### Clonar e instalar ambientes

```bash
git clone https://github.com/jlpitta/bacflow
cd bacflow

# instalar os ambientes conda (obrigatório antes da primeira execução)
bash install_envs.sh
```

O script detecta automaticamente `mamba`, `micromamba` ou `conda` (nessa ordem de preferência), instala os dois ambientes e exibe instruções para configurar o `nextflow` no terminal. Há duas opções:

**Opção A — alias permanente** (recomendado): adicione ao `~/.bashrc`:
```bash
alias nextflow='mamba run -n bacflow-tools nextflow'
# ou, se usar micromamba:
alias nextflow='micromamba run -n bacflow-tools nextflow'
```
Depois: `source ~/.bashrc`. A partir daí `nextflow` funciona diretamente em qualquer terminal.

**Opção B — ativar o ambiente manualmente** antes de cada uso:
```bash
mamba activate bacflow-tools   # ou: micromamba activate / conda activate
nextflow run bacflow.nf ...
```

```bash
# verificar ambientes instalados
mamba env list | grep bacflow
# bacflow-tools   ~/.conda/envs/bacflow-tools
# bacflow-medaka  ~/.conda/envs/bacflow-medaka
```

> **Importante:** os módulos referenciam os ambientes pelo **nome fixo** (`bacflow-tools` / `bacflow-medaka`), não pelo caminho do YAML. A pré-instalação é obrigatória antes da primeira execução.

---

## Ambientes Conda

| Ambiente | YAML | Ferramentas |
|---|---|---|
| `bacflow-tools` | `envs/tools.yaml` | nextflow, nanofilt, fastp, flye, unicycler, minimap2, racon, seqkit, samtools, polypolish, nextpolish, bwa, quast, multiqc, nanostat |
| `bacflow-medaka` | `envs/medaka.yaml` | medaka=1.11.3 (**isolada** — conflito TensorFlow/ONNX com bioconda) |

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

Monta o genoma do zero. Amostras com long reads usam Flye, seguido de polishing com Medaka e opcionalmente Polypolish ou NextPolish; amostras só com short reads usam Unicycler diretamente, sem etapas adicionais de polish.

### `--mode reference`

Usa um genoma de referência (`--reference ref.fasta`) como draft direto para o Medaka, pulando a etapa de montagem. Indicado para organismos bem caracterizados. Para espécies com alta divergência, prefira `denovo`. Requer `long_reads` em todas as amostras — não é compatível com montagem short-read-only.

---

## Modos de input

O pipeline aceita duas formas de entrada, mutuamente exclusivas:

### Single-sample — parâmetros diretos

**Long reads + short reads (híbrido, Flye):**

```bash
nextflow run bacflow.nf -resume \
    --t 32 \
    --long_reads lr.fastq.gz \
    --genome_size 5m \
    --sample_name amostra01 \
    --short_reads_1 r1.fastq.gz \
    --short_reads_2 r2.fastq.gz
```

**Somente short reads (short-read-only, Unicycler) — sem `--long_reads` nem `--genome_size`:**

```bash
nextflow run bacflow.nf -resume \
    --t 32 \
    --sample_name amostra01 \
    --short_reads_1 r1.fastq.gz \
    --short_reads_2 r2.fastq.gz
```

O pipeline detecta automaticamente a ausência de `--long_reads` e monta com Unicycler, emitindo um aviso no log.

### Multi-sample — samplesheet CSV

```bash
nextflow run bacflow.nf -resume \
    --t 64 \
    --samplesheet samples.csv
```

**Exemplo 1 — somente long reads (sem polimento short-read):**

```csv
sample,long_reads,short_reads_1,short_reads_2,genome_size
amostra01,data/A01/lr.fastq.gz,,,5m
amostra02,data/A02/lr.fastq.gz,,,4.8m
amostra03,data/A03/lr.fastq.gz,,,5m
```

Amostras sem `short_reads_1/2` seguem o fluxo Flye → Medaka → QUAST, independente do `--polisher` configurado.

**Exemplo 2 — long reads + short reads (com Polypolish por padrão):**

```csv
sample,long_reads,short_reads_1,short_reads_2,genome_size
amostra01,data/A01/lr.fastq.gz,data/A01/r1.fastq.gz,data/A01/r2.fastq.gz,5m
amostra02,data/A02/lr.fastq.gz,data/A02/r1.fastq.gz,data/A02/r2.fastq.gz,5m
amostra03,data/A03/lr.fastq.gz,data/A03/r1.fastq.gz,data/A03/r2.fastq.gz,4.8m
```

**Exemplo 3 — misto (híbrida + long-only + short-only na mesma samplesheet):**

```csv
sample,long_reads,short_reads_1,short_reads_2,genome_size
amostra01,data/A01/lr.fastq.gz,data/A01/r1.fastq.gz,data/A01/r2.fastq.gz,5m
amostra02,data/A02/lr.fastq.gz,,,4.8m
amostra03,,data/A03/r1.fastq.gz,data/A03/r2.fastq.gz,
```

- `amostra01` (long + short): Flye → Medaka → Polypolish → QUAST
- `amostra02` (só long): Flye → Medaka → QUAST, sem polish (nenhuma amostra é derrubada silenciosamente do resultado por não ter short reads)
- `amostra03` (só short): Unicycler → QUAST direto, sem NanoFilt/Racon/Medaka/polish; `genome_size` pode ficar vazio, já que só o Flye usa esse parâmetro

- Amostras processadas em **paralelo**, limitadas pelo `--t` global
- `genome_size` pode ser coluna no CSV (por amostra) ou `--genome_size` como parâmetro global; só é exigido para amostras com `long_reads`
- Saídas em `results/{sample}/`
- `--mode reference` exige `long_reads` em **todas** as amostras da samplesheet — misturar com short-only nesse modo gera erro

---

## Parâmetros

| Parâmetro | Padrão | Descrição |
|---|---|---|
| `--mode` | `denovo` | Modo: `denovo` ou `reference` |
| `--long_reads` | — | FASTQ long reads. Se omitido (com `--short_reads_1/2` presentes), monta short-read-only via Unicycler; obrigatório em `--mode reference` |
| `--samplesheet` | — | CSV multi-sample (alternativa a --long_reads); pode misturar amostras híbridas, long-only e short-only |
| `--short_reads_1` | — | R1 Illumina. Sozinho (sem `--long_reads`), monta short-read-only; combinado com `--long_reads`, é usado no polishing |
| `--short_reads_2` | — | R2 Illumina |
| `--genome_size` | — | Tamanho estimado do genoma (ex: `5m`, `4.8m`, `2g`). Obrigatório apenas para amostras com `--long_reads` (usado pelo Flye) |
| `--sample_name` | `sample` | Prefixo dos outputs e nome da subpasta em results/ |
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

## Os 7 fluxos de execução

Cada fluxo pode ser executado de duas formas:
- **Single-sample** — parâmetros diretos na linha de comando
- **Multi-sample** — samplesheet CSV com múltiplas amostras em paralelo

### Modo `denovo` / Flye

**Fluxo 1 — Mínimo: Flye + Medaka**

```bash
# single-sample
nextflow run bacflow.nf -resume \
    --t 16 \
    --long_reads lr.fastq.gz \
    --genome_size 5m \
    --sample_name amostra01

# multi-sample (samples.csv: sample,long_reads,genome_size)
nextflow run bacflow.nf -resume \
    --t 64 \
    --samplesheet samples.csv
```

**Fluxo 2 — Com Racon: Flye + Racon + Medaka**

```bash
# single-sample
nextflow run bacflow.nf -resume \
    --t 16 \
    --long_reads lr.fastq.gz \
    --genome_size 5m \
    --sample_name amostra01 \
    --use_racon

# multi-sample
nextflow run bacflow.nf -resume \
    --t 64 \
    --samplesheet samples.csv \
    --use_racon
```

**Fluxo 3 — Padrão-ouro: Flye + Medaka + Polypolish**

> Polypolish é o padrão quando short reads são fornecidas. Nenhum parâmetro extra necessário.

```bash
# single-sample
nextflow run bacflow.nf -resume \
    --t 32 \
    --long_reads lr.fastq.gz \
    --short_reads_1 r1.fastq.gz \
    --short_reads_2 r2.fastq.gz \
    --genome_size 5m \
    --sample_name amostra01

# multi-sample (samples.csv: sample,long_reads,short_reads_1,short_reads_2,genome_size)
nextflow run bacflow.nf -resume \
    --t 64 \
    --samplesheet samples.csv
```

**Fluxo 4 — Completo: Flye + Racon + Medaka + Polypolish**

```bash
# single-sample
nextflow run bacflow.nf -resume \
    --t 32 \
    --long_reads lr.fastq.gz \
    --short_reads_1 r1.fastq.gz \
    --short_reads_2 r2.fastq.gz \
    --genome_size 5m \
    --sample_name amostra01 \
    --use_racon

# multi-sample
nextflow run bacflow.nf -resume \
    --t 64 \
    --samplesheet samples.csv \
    --use_racon
```

### Modo `denovo` / Unicycler (short-read-only)

> Automático: qualquer amostra sem `long_reads` (e com `short_reads_1`/`2`) monta direto com Unicycler, sem Racon/Medaka/polish adicional. Não existe flag `--assembler` — a escolha é sempre pelos dados disponíveis.

**Fluxo 5 — Unicycler (short-read-only)**

```bash
# single-sample
nextflow run bacflow.nf -resume \
    --t 32 \
    --short_reads_1 r1.fastq.gz \
    --short_reads_2 r2.fastq.gz \
    --sample_name amostra01

# multi-sample (samples.csv: sample,long_reads,short_reads_1,short_reads_2,genome_size — long_reads e genome_size vazios)
nextflow run bacflow.nf -resume \
    --t 64 \
    --samplesheet samples.csv
```

### Modo `reference`

**Fluxo 6 — Referência + Medaka**

```bash
# single-sample
nextflow run bacflow.nf -resume \
    --t 16 \
    --mode reference \
    --long_reads lr.fastq.gz \
    --reference ref.fasta \
    --sample_name amostra01

# multi-sample
nextflow run bacflow.nf -resume \
    --t 64 \
    --mode reference \
    --samplesheet samples.csv \
    --reference ref.fasta
```

**Fluxo 7 — Referência + Medaka + Polypolish**

```bash
# single-sample
nextflow run bacflow.nf -resume \
    --t 32 \
    --mode reference \
    --long_reads lr.fastq.gz \
    --short_reads_1 r1.fastq.gz \
    --short_reads_2 r2.fastq.gz \
    --reference ref.fasta \
    --sample_name amostra01

# multi-sample
nextflow run bacflow.nf -resume \
    --t 64 \
    --mode reference \
    --samplesheet samples.csv \
    --reference ref.fasta
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

Tenho só short reads (sem long reads)?
  └─► Fluxo 5 (Unicycler short-read-only) — único caminho possível nesse caso

Genoma bem caracterizado / referência confiável disponível?
  └─► Fluxo 6 ou 7 (modo reference) — mais rápido, requer long reads em todas as amostras

Várias amostras ao mesmo tempo, com perfis diferentes (híbrida/long-only/short-only)?
  └─► Uma única --samplesheet samples.csv resolve todos — o assembler é escolhido
      automaticamente por amostra, sem precisar rodar comandos separados
```

---

## Controle de CPUs

O parâmetro `--t` define o total de CPUs desejadas. O pipeline distribui automaticamente:

| Nível | Processos | CPUs |
|---|---|---|
| `process_low` | NanoFilt, FASTP, QUAST | `t / 4` |
| `process_medium` | Racon, Medaka, Polypolish, NextPolish | `t / 2` |
| `process_high` | Flye, Unicycler | `t` (todos) |

Exemplo com `--t 32`: NanoFilt + FASTP rodam em paralelo (8 + 8 CPUs), Flye/Unicycler usa todas as 32.

`--t` escala pra qualquer servidor (`--t 100`, `--t 256` etc.), mas é **automaticamente limitado aos cores reais da máquina** (`Runtime.availableProcessors()`, detectado em tempo de execução no `nextflow.config`). Se você passar `--t 100` num servidor com apenas 32 CPUs, o pipeline usa no máximo 32 e emite um aviso no log — não ultrapassa o hardware disponível.

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
| Mamba (padrão) | `nextflow run bacflow.nf ...` |
| Conda | `nextflow run bacflow.nf -profile conda ...` |
| Micromamba | `nextflow run bacflow.nf -profile micromamba ...` |

---

## Estrutura de arquivos

```
bacflow/
├── bacflow.nf          # script principal DSL2
├── nextflow.config           # configuração global, parâmetros, profiles, CPUs
├── install_envs.sh           # pré-instala os ambientes conda
├── envs/
│   ├── tools.yaml            # → bacflow-tools
│   └── medaka.yaml           # → bacflow-medaka (isolada)
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
| Amostras short-only (Unicycler) **nunca** passam por Polypolish/NextPolish | Unicycler já incorpora os short reads na montagem — polish adicional seria redundante |
| Usar `-resume` sempre que possível | Retoma do ponto onde parou sem reprocessar etapas concluídas |

---

## Dicas de uso

**Retomar execução interrompida:**
```bash
nextflow run bacflow.nf -resume ...
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
