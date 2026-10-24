# Modelo estatístico e coletor do Pet Apura

Este diretório publica os fontes do release que alimenta o site. Os 63 arquivos
R, Stan, Python e JSON listados em `source-manifest.json` foram comparados byte a byte
com o runtime de produção em 24/10/2026. O manifesto registra o hash SHA-256 de cada
arquivo e a identidade da execução. O inventário privado de caminhos de outros projetos
foi omitido. A especificação ASN.1 e o arquivo de dependências Python acompanham o coletor.

## Arquivos principais

| Arquivo | Função |
|---|---|
| `comparecimento_preditor.stan` e `comparecimento_preditor.R` | Regressão hierárquica histórica de 2022 |
| `online_conjugado.R` | Prior conjunta de 2026 e atualização dos coeficientes |
| `componentes_locais.R` e `componentes_locais_v2.json` | Componentes compartilhados de voto e razão de válidos |
| `escalas_online_v2.json` | Hipóteses de mudança entre eleições |
| `previsao_execucao.R` | Projeção por seção, UF e total, incluindo os dois cenários |
| `executar_previsao.R` | Interface de atualização, acompanhamento e inspeção |
| `coletor.py` e `publicar_tse.py` | Coleta dos BUs totalizados e export consistente dos dados observados |
| `spec/bu.asn1` | Especificação do formato dos boletins de urna |

Os dois cenários incorporam os votos observados. O cenário com aprendizado atualiza a
relação entre turnos e os componentes compartilhados. O cenário relação de 2022 mantém
a distribuição inicial nas seções pendentes. O ponto de entrada para o site é a ponte
[`../integracao/executar_pipeline.R`](../integracao/executar_pipeline.R).

## Requisitos e entradas

Para o coletor: Python 3.10 ou superior em macOS/Linux e `asn1tools`, na versão fixada
em `requirements.txt`. A instalação pode ser feita em um ambiente virtual próprio:

```sh
python3 -m venv modelo/.venv
modelo/.venv/bin/python -m pip install -r modelo/requirements.txt
```

Para projetar a partir de um ajuste existente: R com `data.table`, `arrow`, `jsonlite`
e `digest`. Para refazer o ajuste histórico também são necessários `cmdstanr`, CmdStan
e as dependências de análise chamadas pelos scripts R.

A execução depende de entradas que não acompanham este repositório:

- Votos por seção do TSE de 2022, primeiro e segundo turnos, e primeiro turno de 2026,
  com o esquema usado pelos scripts de preparação.
- Ajuste histórico em `data/processed/voto_t1_fits.rds`.
- Estado inicial íntegro em `data/processed/estado_inicial_v2/`.
- Inventário e export do coletor em `data/live/tse_export/`.

`preparar_voto_t1.R`, `preparar_componentes_locais.R` e as funções de
`analise_execucao.R` documentam as etapas de preparação. Alguns scripts históricos
usam caminhos relativos da organização original dos dados, explicitados no código.
Publicar os fontes não equivale a distribuir os objetos ajustados ou a disponibilizar
uma reprodução integral do ajuste apenas com `git clone`.

Com as entradas preparadas em uma pasta de modelo, o site pode usar estes fontes:

```sh
python3 scripts/run_local.py --mode tse \
  --model-dir /caminho/modelo-com-dados \
  --model-code modelo \
  --source /caminho/modelo-com-dados/data/live/tse_export \
  --initial-state /caminho/modelo-com-dados/data/processed/estado_inicial_v2
```

O guia [`../docs/LOCAL.md`](../docs/LOCAL.md) descreve a simulação e os testes. A
operação publicada está em [`../docs/CLOUDFLARE.md`](../docs/CLOUDFLARE.md).

Os replays verificam a integração do software. Os intervalos continuam condicionados
às hipóteses do modelo e não constituem uma garantia de cobertura empírica eleitoral.
