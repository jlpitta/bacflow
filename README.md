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
- [QC de reads (raw vs. trimmed)](#qc-de-reads-raw-vs-trimmed)
- [Os 7 fluxos de execução](#os-7-fluxos-de-execução)
- [Controle de CPUs](#controle-de-cpus)
- [Profiles (gerenciador de pacotes)](#profiles-gerenciador-de-pacotes)
- [Testando o pipeline](#testando-o-pipeline)
- [Estrutura de arquivos](#estrutura-de-arquivos)
- [Estrutura de resultados](#estrutura-de-resultados)
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
├── SIM ──► NanoFilt¹ ──► [Flye] ──► [Racon] (opc.) ──► [Medaka] ──► [QUAST³/BUSCO⁴/CheckM2⁵ pré-polish]
│                                                                    │
│           Short reads (se houver) ─► FASTP² ─► [Polypolish] ou [NextPolish] (opc.)
│                                                                    │
│                                                                    ▼
│                                                      [QUAST³/BUSCO⁴/CheckM2⁵ pós-polish]
│
└── NÃO ──► Short reads ─► FASTP² ─► [Unicycler] ──► [QUAST³/BUSCO⁴/CheckM2⁵]
            (short-read-only, sem Racon/Medaka/polish adicional,
             sem estado "pré-polish" real — chamada única, como sempre)

¹ NanoFilt é bracketado por QC raw-vs-trimmed: NanoStat (antes/depois) + NanoComp
  (comparativo HTML) — roda sempre em paralelo, não bloqueia o fluxo
² FASTP é bracketado por QC raw-vs-trimmed: FastQC (antes/depois) — roda sempre
  em paralelo, não bloqueia o fluxo
³ QUAST roda 2x no caminho Flye (denovo e reference): logo após Racon/Medaka
  (quast_prepolish/) e de novo após Polypolish/NextPolish (quast_postpolish/) —
  se nenhum polish foi aplicado (sem short reads ou --polisher none), os dois
  relatórios saem idênticos, o que é a informação correta nesse caso
⁴ BUSCO só roda quando --reference NÃO é informado (modo reference sempre tem
  --reference, então nunca aciona BUSCO): sem referência, o QUAST não detecta
  melhora do polish (ele corrige erro de base, não a estrutura/contiguidade),
  então a completude gênica do BUSCO é o sinal real de melhora
⁵ CheckM2 roda **sempre**, com ou sem --reference (diferente do BUSCO): mede
  completude E contaminação, uma dimensão que nem QUAST nem BUSCO cobrem
```

Ver [QC de reads](#qc-de-reads-raw-vs-trimmed) para detalhes de onde cada relatório é gerado.

### Ferramentas utilizadas

| Etapa | Ferramenta | Função |
|---|---|---|
| QC long reads (raw/trimmed) | NanoStat | Estatísticas antes e depois do NanoFilt |
| QC long reads (comparativo) | NanoComp | HTML comparativo raw-vs-trimmed por amostra |
| Filtragem long reads | NanoFilt | Q-score ≥ 10, comprimento ≥ 500 bp |
| QC short reads (raw/trimmed) | FastQC | Relatório antes e depois do FASTP |
| Filtragem short reads | FASTP | Q ≥ 20, comprimento ≥ 50 bp |
| Downsampling | SeqKit | Limitar número de reads (opcional) |
| Montagem (long reads) | Flye | Montagem *de novo* a partir de long reads, com polishing híbrido |
| Montagem (short-read-only) | Unicycler | Montagem *de novo* só com Illumina (baseado em SPAdes), quando não há long reads |
| Polishing long reads | Racon | Polishing rápido pré-Medaka (opcional, só no caminho Flye) |
| Polishing long reads | Medaka 1.11.3 | Correção de erros com modelo de rede neural (só no caminho Flye) |
| Avaliação (pré-polish) | QUAST | Métricas da montagem logo após Racon/Medaka (só caminho Flye — `qc/quast_prepolish/`) |
| Avaliação (pré-polish, sem referência) | BUSCO | Completude gênica logo após Racon/Medaka (só caminho Flye, só sem `--reference` — `qc/busco_prepolish/`) |
| Avaliação (pré-polish, sempre) | CheckM2 | Completude + contaminação logo após Racon/Medaka (só caminho Flye — `qc/checkm2_prepolish/`) |
| Polishing short reads | **Polypolish** (padrão) | Correção final com Illumina, base a base (só no caminho Flye) |
| Polishing short reads | NextPolish (alternativa) | Correção multi-round com Illumina, `--polisher nextpolish` (só no caminho Flye) |
| Avaliação (pós-polish) | QUAST | Métricas da montagem final — pós-polish no caminho Flye (`qc/quast_postpolish/`), única chamada no caminho Unicycler (`qc/quast/`) |
| Avaliação (pós-polish, sem referência) | BUSCO | Completude gênica final — pós-polish no caminho Flye (`qc/busco_postpolish/`), única chamada no caminho Unicycler (`qc/busco/`) — só sem `--reference` |
| Avaliação (pós-polish, sempre) | CheckM2 | Completude + contaminação final — pós-polish no caminho Flye (`qc/checkm2_postpolish/`), única chamada no caminho Unicycler (`qc/checkm2/`) |

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

O script detecta automaticamente `mamba`, `micromamba` ou `conda` (nessa ordem de preferência), instala os três ambientes (`bacflow-tools`, `bacflow-medaka`, `bacflow-checkm2`), baixa o banco de dados do CheckM2 (~1.7 GB, só na primeira vez — pula automaticamente se já existir) e exibe instruções para configurar o `nextflow` no terminal. Há duas opções:

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
# bacflow-tools    ~/miniforge3/envs/bacflow-tools
# bacflow-medaka   ~/miniforge3/envs/bacflow-medaka
# bacflow-checkm2  ~/miniforge3/envs/bacflow-checkm2
```

> **Importante:** os módulos referenciam os ambientes pelo **caminho absoluto** (`$HOME/miniforge3/envs/bacflow-tools` / `bacflow-medaka` / `bacflow-checkm2`), assumindo a instalação padrão do Miniforge/Mambaforge no `$HOME` do usuário — não pelo nome nem pelo caminho do YAML (referenciar só pelo nome faz o Nextflow tentar *instalar um pacote* com esse nome do bioconda, em vez de reaproveitar o ambiente já criado). Se seu Conda/Mamba estiver instalado em outro local, ajuste o `conda` directive em cada `modules/local/*.nf`. A pré-instalação é obrigatória antes da primeira execução.

---

## Ambientes Conda

| Ambiente | YAML | Ferramentas |
|---|---|---|
| `bacflow-tools` | `envs/tools.yaml` | nextflow=26.04.6, nanofilt, nanostat, fastp, fastqc=0.12.1, nanocomp=1.25.6, busco=6.1.0, flye, unicycler, minimap2, racon, seqkit, samtools, polypolish, nextpolish, bwa, quast, multiqc |
| `bacflow-medaka` | `envs/medaka.yaml` | medaka=1.11.3, setuptools=69.5.1 (**isolada** — conflito TensorFlow/ONNX com bioconda) |
| `bacflow-checkm2` | `envs/checkm2.yaml` | checkm2=1.1.0 (**isolada** — conflito real de dependências com `bacflow-tools`, descoberto na prática) |

O Medaka é mantido em ambiente isolado obrigatoriamente, pois suas dependências (TensorFlow, ONNX) conflitam com pacotes do canal bioconda. O pin de `setuptools=69.5.1` é necessário porque versões mais recentes removeram o módulo `pkg_resources`, do qual o `medaka=1.11.3` depende.

O CheckM2 também precisa de ambiente isolado: tentar instalá-lo dentro do `bacflow-tools` gera um conflito de dependências irresolúvel (`abseil-cpp`/`libboost`, puxado pelas dependências de ML do CheckM2 — scikit-learn, lightgbm). Além do ambiente, o CheckM2 exige um banco de dados DIAMOND (~1.7 GB) baixado separadamente — o `install_envs.sh` já faz isso automaticamente (ver [Instalação](#instalação)).

> `NanoComp` vem do pacote bioconda **`nanocomp`**, não `nanoplot` (que fornece o `NanoPlot`, uma ferramenta diferente — relatório detalhado de 1 dataset, sem comparação).

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

Amostras sem `short_reads_1/2` seguem o fluxo Flye → Medaka → QUAST pré-polish → QUAST pós-polish (idêntico ao pré, já que não há polish pra aplicar), independente do `--polisher` configurado.

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

- `amostra01` (long + short): Flye → Medaka → QUAST pré-polish → Polypolish → QUAST pós-polish
- `amostra02` (só long): Flye → Medaka → QUAST pré-polish → QUAST pós-polish (idêntico, sem polish — nenhuma amostra é derrubada silenciosamente do resultado por não ter short reads)
- `amostra03` (só short): Unicycler → QUAST direto (chamada única), sem NanoFilt/Racon/Medaka/polish; `genome_size` pode ficar vazio, já que só o Flye usa esse parâmetro

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
| `--reference` | `null` | Draft para modo `reference`; referência comparativa QUAST no modo `denovo`. Quando **não** informado em modo `denovo`, ativa BUSCO pré/pós-polish em vez da comparação QUAST baseada em referência |
| `--busco_lineage` | `bacteria_odb10` | Lineage do BUSCO (só usado quando `--reference` não é informado) |
| `--checkm2_db` | `~/checkm2_db/CheckM2_database/uniref100.KO.1.dmnd` | Caminho do banco DIAMOND do CheckM2 (roda sempre, com ou sem `--reference`) |
| `--medaka_model` | *(da plataforma)* | Sobrescreve o modelo Medaka padrão |
| `--t` | — | Total de CPUs disponíveis |
| `--min_quality` | `10` | Q-score mínimo NanoFilt |
| `--min_length` | `500` | Comprimento mínimo de reads NanoFilt (bp) |
| `--downsample` | `0` | Máx de reads para montagem (`0` = sem limite; ex: `200000` para economizar RAM) |
| `--outdir` | `results` | Diretório de saída |

---

## QC de reads (raw vs. trimmed)

Roda **automaticamente em todo run**, independente de qual dos 7 fluxos ou modo (`denovo`/`reference`) está em uso — não é controlado por flag, não bloqueia a montagem (executa em paralelo) e não é opcional.

| Tipo de read | Antes do filtro | Ferramenta | Depois do filtro | Onde comparar |
|---|---|---|---|---|
| Long reads | `NANOSTAT_RAW` sobre o FASTQ original | NanoFilt (Q/comprimento) | `NANOSTAT_TRIMMED` sobre `lr.filtered` | `NANOCOMP` — HTML único com os dois lado a lado |
| Short reads | `FASTQC_RAW` sobre R1/R2 originais | FASTP (trim + filtro) | `FASTQC_TRIMMED` sobre R1/R2 limpos | Abrir os dois HTMLs do FastQC lado a lado |

- NanoStat/NanoComp usam os long reads **antes do `--downsample`** — downsample é redução de amostragem, não mudança de qualidade, então fica fora dessa comparação (mas o NanoFilt/filtro de qualidade já é capturado).
- Amostras short-read-only (sem `long_reads`) só geram QC de short reads (FastQC); amostras híbridas ou long-only geram os dois.
- Nenhum parâmetro novo — os thresholds usados no relatório "trimmed" são os mesmos de `--min_quality`/`--min_length` (NanoFilt) e os fixos do FASTP (Q≥20, comprimento≥50bp).

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
| `process_low` | NanoFilt, FASTP, FastQC, NanoStat, NanoComp, QUAST (+ pré/pós-polish) | `t / 4` |
| `process_medium` | Racon, Medaka, Polypolish, NextPolish, BUSCO, CheckM2 (+ pré/pós-polish) | `t / 2` |
| `process_high` | Flye, Unicycler | `t` (todos) |

Exemplo com `--t 32`: NanoFilt + FASTP + os QC (FastQC/NanoStat/NanoComp) rodam em paralelo (8 CPUs cada), Flye/Unicycler usa todas as 32.

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

## Testando o pipeline

O repositório inclui dados de teste prontos em [`genome_test/`](genome_test/) — não é preciso ter dados próprios pra validar a instalação:

| Dataset | O quê | Uso |
|---|---|---|
| `mycoplasma_genitalium_synthetic/` | Reads simulados a partir de um genoma real (580 kb) | Smoke test rápido (poucos minutos) |
| `staphylococcus_aureus_real/` | Reads ONT + Illumina **100% reais**, mesma cepa, subamostrados a ~25x, contra referência de cepa diferente | Validação de verdade do polimento (mais lento, genoma de 2.8 Mb) |

```bash
nextflow run bacflow.nf --t 4 \
    --long_reads genome_test/mycoplasma_genitalium_synthetic/long_reads.fastq.gz \
    --short_reads_1 genome_test/mycoplasma_genitalium_synthetic/short_reads_1.fastq.gz \
    --short_reads_2 genome_test/mycoplasma_genitalium_synthetic/short_reads_2.fastq.gz \
    --genome_size 580000 \
    --sample_name teste \
    --reference genome_test/mycoplasma_genitalium_synthetic/reference.fasta
```

Ver [`genome_test/README.md`](genome_test/README.md) para detalhes de origem, accessions e um exemplo real de resultado (melhora do polish medida por QUAST e CheckM2).

---

## Estrutura de arquivos

```
bacflow/
├── bacflow.nf          # script principal DSL2
├── nextflow.config           # configuração global, parâmetros, profiles, CPUs
├── install_envs.sh           # pré-instala os ambientes conda
├── envs/
│   ├── tools.yaml            # → bacflow-tools
│   ├── medaka.yaml           # → bacflow-medaka (isolada)
│   └── checkm2.yaml          # → bacflow-checkm2 (isolada)
├── genome_test/               # dados de teste prontos (ver Testando o pipeline)
│   ├── mycoplasma_genitalium_synthetic/
│   └── staphylococcus_aureus_real/
└── modules/local/
    ├── nanofilt.nf
    ├── nanostat.nf        # NANOSTAT_RAW + NANOSTAT_TRIMMED
    ├── nanocomp.nf        # comparativo raw-vs-trimmed (long reads)
    ├── fastp.nf
    ├── fastqc.nf          # FASTQC_RAW + FASTQC_TRIMMED
    ├── seqkit_downsample.nf
    ├── flye.nf
    ├── unicycler.nf
    ├── racon.nf
    ├── medaka.nf
    ├── polypolish.nf
    ├── nextpolish.nf
    ├── quast.nf           # QUAST + QUAST_PREPOLISH + QUAST_POSTPOLISH
    ├── busco.nf           # BUSCO + BUSCO_PREPOLISH + BUSCO_POSTPOLISH
    └── checkm2.nf          # CHECKM2 + CHECKM2_PREPOLISH + CHECKM2_POSTPOLISH
```

---

## Estrutura de resultados

```
results/{sample}/
├── qc/
│   ├── nanostat_raw/               {sample}.nanostat_raw.txt
│   ├── nanofilt/                   {sample}.filtered.fastq.gz
│   ├── nanostat_trimmed/           {sample}.nanostat_trimmed.txt
│   ├── nanocomp/                   NanoComp-report.html, NanoStats.txt
│   ├── fastqc_raw/                 *_fastqc.html, *_fastqc.zip
│   ├── fastp/                      {sample}.fastp.html/.json, *.clean.fastq.gz
│   ├── fastqc_trimmed/             *_fastqc.html, *_fastqc.zip
│   ├── quast_prepolish/quast_output/   report.html, report.tsv, ... (só caminho Flye, logo após Racon/Medaka)
│   ├── quast_postpolish/quast_output/  report.html, report.tsv, ... (só caminho Flye, após Polypolish/NextPolish)
│   ├── quast/quast_output/         report.html, report.tsv, ... (só caminho Unicycler, chamada única)
│   ├── busco_prepolish/busco_output/   short_summary.txt, full_table.tsv, ... (só caminho Flye, sem --reference)
│   ├── busco_postpolish/busco_output/  short_summary.txt, full_table.tsv, ... (só caminho Flye, sem --reference)
│   ├── busco/busco_output/         short_summary.txt, full_table.tsv, ... (só caminho Unicycler, sem --reference)
│   ├── checkm2_prepolish/checkm2_output/   quality_report.tsv, ... (só caminho Flye, sempre)
│   ├── checkm2_postpolish/checkm2_output/  quality_report.tsv, ... (só caminho Flye, sempre)
│   └── checkm2/checkm2_output/     quality_report.tsv, ... (só caminho Unicycler, sempre)
├── assembly/
│   ├── flye/               {sample}.assembly.fasta (+ flye_output/assembly_info.txt)
│   └── unicycler/          {sample}.assembly.fasta (caminho short-only)
└── polishing/
    ├── racon/               {sample}.racon.fasta (opcional)
    ├── medaka/              {sample}.medaka.fasta
    ├── polypolish/          {sample}.polypolish.fasta (padrão)
    └── nextpolish/          {sample}.nextpolish.fasta (alternativa, --polisher nextpolish)
```

Uma amostra só gera **um** dos pares de cada avaliação: `_prepolish/`+`_postpolish/` se veio pelo caminho Flye (denovo ou reference), ou a chamada única se veio pelo caminho Unicycler. Diretórios `busco*/` só existem quando `--reference` não foi informado; `checkm2*/` existem sempre.

Estrutura validada com execução real de ponta a ponta em 18–20/07/2026: dados sintéticos nos 3 caminhos (denovo híbrido, reference, short-only) e nos cenários com/sem `--reference`; dados 100% reais (`genome_test/staphylococcus_aureus_real/`) confirmando melhora real do polish — indels 120→56/100kbp (QUAST), completude 90.7%→100.0% e contaminação 8.53%→0.05% (CheckM2).

---

## Regras importantes

| Regra | Motivo |
|---|---|
| **Nunca** rodar Racon após Medaka | Racon reintroduz erros que o Medaka já corrigiu |
| **Nunca** rodar Polypolish após NextPolish | Degrada a qualidade — a ordem importa |
| **Sempre** manter Medaka em ambiente isolado | TensorFlow/ONNX conflita com pacotes bioconda |
| **Sempre** pré-instalar os envs antes de rodar | Módulos referenciam por caminho absoluto (`$HOME/miniforge3/envs/...`), não pelo YAML nem por nome |
| Ambientes conda assumem Miniforge/Mambaforge instalado em `$HOME/miniforge3/` | Referenciar só pelo nome faz o Nextflow tentar *instalar* um pacote bioconda com esse nome em vez de reaproveitar o ambiente local — ajustar o `conda` directive nos módulos se usar outro local de instalação |
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
