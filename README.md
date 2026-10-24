# Pet Apura · Presidência 2026

Site de apuração e projeção do segundo turno presidencial. Projeto do **PET de Ciências Sociais da USP**.

**Site:** [petapura.eleicoes-pet.workers.dev](https://petapura.eleicoes-pet.workers.dev/)
**Código:** [github.com/mgaldino/petapura](https://github.com/mgaldino/petapura)

O repositório reúne o site, o endpoint no Cloudflare Workers, os adaptadores de
publicação e os [fontes do modelo estatístico e do coletor](modelo/README.md).
Os fontes em `modelo/` correspondem ao release usado em produção, com hashes
conferidos. Dados eleitorais de entrada e objetos ajustados são requisitos separados,
documentados nesse diretório. Os registros administrativos do PET e as capturas do
painel de analytics permanecem locais.

A votação final projetada de A é a informação principal, apresentada nos cenários
**com aprendizado** e **relação de 2022**. Antes dos primeiros boletins, as caixas
mostram **ND (não disponível)** e o gráfico fica em **50% / 50%**, identificado como
referência visual de espera. O parcial aparece depois do gráfico. As faixas usam o
nível informado pelo modelo. A metodologia e a equipe têm páginas próprias no menu.

## Executar

Requer Python 3.10 ou superior em macOS ou Linux (o publicador usa locks POSIX). O servidor e o publicador usam somente a biblioteca padrão do Python. A simulação integrada também requer R e os pacotes já usados pelo modelo: `data.table`, `arrow`, `jsonlite` e `digest`. Não instala dependências automaticamente.

```sh
python3 scripts/run_local.py
```

Esse comando abre uma **simulação integrada**: gera 2.800 seções fictícias nas 27 UFs e no exterior, publica snapshots pelo código original do coletor, executa o modelo adaptativo e serve a página. Começa com previsão inicial e zero BUs e avança automaticamente até concluir a apuração. A página não exige controles de reprodução nem escolha de intervalo. Cada lote executa novamente a previsão; não é uma sequência de percentuais pré-gravados.

- Aplicação: <http://127.0.0.1:4173/>
- Demonstração identificada com dados fictícios: <http://127.0.0.1:4173/?demo=1>

O modelo é localizado na estrutura atual `DCP/Cursos/Regressao/.../previsao_tempo_real`. Em outra máquina, informe `--model-dir /caminho/previsao_tempo_real` ou a variável `PET_MODEL_DIR`. Guia completo: [executar e testar localmente](docs/LOCAL.md).

Abra pelo endereço local, em vez de abrir `web/index.html` diretamente no Finder. O site lê arquivos JSON e usa módulos JavaScript pelo servidor.

Para servir somente o frontend estático, use `python3 scripts/serve.py`: nesse caso o endereço principal começa em **aguardando dados**, e `?demo=1` mostra os exemplos do mockup. O servidor integrado declara explicitamente o modo fictício; o endpoint de produção continua rejeitando dados de demonstração.

## Organização

| Pasta | Conteúdo |
|---|---|
| [`web/`](web/index.html) | Aplicação HTML, CSS e JavaScript, sem framework. MathJax na metodologia e beacon do Cloudflare nas páginas públicas |
| [`modelo/`](modelo/README.md) | Fontes R, Stan e Python do modelo e do coletor, configurações e manifesto de hashes |
| [`mockup/`](mockup/README.md) | Mockup aprovado, versão independente para navegador e dados sintéticos originais |
| [`docs/`](docs/STATUS.md) | Estado, decisões de design, operação e integração |
| [`docs/benchmark/`](docs/benchmark/README.md) | Pesquisa visual, PDF, capturas e referências que antecederam o mockup |
| [`schema/`](schema/snapshot.schema.json) | Esquema versionado dos dados públicos |
| [`scripts/`](scripts/publish_snapshot.py) | Validação, importação do coletor, publicação atômica, prévia e empacotamento |
| [`integracao/`](integracao/exportar_previsao_site.R) | Funções de saída para o executor em R |
| [`tests/`](tests/data.test.js) | Testes JavaScript/Python e fixtures sintéticas |

## Integrar o modelo

O ponto de entrada é um snapshot JSON conforme o [contrato](docs/INTEGRACAO.md). A URL é configurada em [`web/config.json`](web/config.json). O site consulta essa URL a cada 30 segundos, valida os dados e preserva a última resposta válida em falhas.

```sh
python3 scripts/publish_snapshot.py --input /caminho/snapshot-do-modelo.json
```

A ponte `integracao/executar_pipeline.R` já chama `avancar_previsao_analise()` do modelo atual, lê o checkpoint consistente e exporta seu percentual e quantis de 95%. Para usar o coletor existente, execute `python3 scripts/run_local.py --mode tse`; ele lê o export e grava checkpoints somente em `local/tse/`. Não inicia outro coletor.

O executor do modelo também pode construir o snapshot com `montar_snapshot_site()` usando o manifesto e os totais que já leu. Isso evita combinar uma previsão com um snapshot posterior do coletor. O publicador acrescenta o histórico e troca o JSON por inteiro, de forma atômica.

Há também um importador de **dados observados**, que não calcula previsões:

```sh
python3 scripts/import_tse.py --source /caminho/previsao_tempo_real/data/live/tse_export
```

O executor de produção continua usando seu runtime isolado. A cópia pública em
`modelo/` permite inspecionar os fontes que deram origem aos cálculos. Para executá-la,
é necessário fornecer os dados e o estado inicial descritos em seu README. Os formatos
antigos de previsão não são tratados como saída final do modelo adaptativo.

## Verificar e empacotar

Requer Node.js 20 ou superior somente para os testes JavaScript; a aplicação no navegador não depende de Node.

```sh
node --test tests/*.test.js
PET_MODEL_DIR="$PWD/modelo" python3 -m unittest discover -s tests -p 'test_*.py'
python3 scripts/build.py
```

O último comando produz `dist/`, pronto para hospedagem estática. Também há atalhos `npm run dev` (pipeline integrado), `npm run preview` (frontend estático), `npm test` e `npm run build`, sem etapa de instalação.

O replay que executa o modelo R do início ao fim é separado dos testes unitários: `python3 tests/replay_pipeline.py --model-dir /caminho/previsao_tempo_real`. As evidências estão em `docs/validacao/`.

Consulte [operação e publicação](docs/OPERACAO.md), [decisões de apresentação](docs/DESIGN.md) e [estado da entrega](docs/STATUS.md). O site está publicado em [petapura.eleicoes-pet.workers.dev](https://petapura.eleicoes-pet.workers.dev).

## Workers e dois cenários (22/10)

A página agora apresenta separadamente os cenários **com aprendizado** e **relação de
2022**, cada um com sua projeção e faixa de 95% do mesmo checkpoint. O gráfico permite
alternar entre eles. A prior real está em `deployment/initial-prior.json`: 47,3534% para
Lula, faixa de 43,0195% a 51,4416%, com 499.248 seções e zero BUs; os cenários coincidem.

`python3 scripts/build.py --production --snapshot deployment/initial-prior.json` prepara
o pacote. `wrangler.jsonc` configura a página e o endpoint de resultados no Cloudflare
Workers; `scripts/run_cloudflare.py` envia as atualizações calculadas em R.

Publicado em 22/10 em **[petapura.eleicoes-pet.workers.dev](https://petapura.eleicoes-pet.workers.dev)**,
com Web Analytics ativo e acessos de teste já recebidos no painel. A página pública e
o primeiro envio do modelo ao KV foram verificados; o JSON público corresponde ao snapshot enviado. Instruções e
evidências em [CLOUDFLARE.md](docs/CLOUDFLARE.md).
