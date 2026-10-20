# Observatório presidencial 2026

Site de apuração e projeção do segundo turno presidencial. Projeto do **PET de Ciências Sociais da USP**.

A votação final projetada de A é a informação principal. O gráfico acompanha a apuração com A em vermelho, B em azul e uma referência de 50%. O parcial aparece depois do gráfico; a chance de vitória fica nos detalhes. As faixas usam o nível efetivamente informado pelo modelo.

## Executar

Requer Python 3.10 ou superior em macOS ou Linux (o publicador usa locks POSIX). Não é necessário instalar pacotes para executar o site, importar os dados ou publicar snapshots.

```sh
python3 scripts/serve.py
```

- Aplicação: <http://127.0.0.1:4173/>
- Demonstração identificada com dados fictícios: <http://127.0.0.1:4173/?demo=1>

Abra pelo endereço local, em vez de abrir `web/index.html` diretamente no Finder. O site lê arquivos JSON e usa módulos JavaScript pelo servidor.

O endereço principal começa em **aguardando dados**. Ele nunca substitui dados reais ausentes por uma demonstração.

## Organização

| Pasta | Conteúdo |
|---|---|
| [`web/`](web/index.html) | Aplicação HTML, CSS e JavaScript, sem framework ou dependências externas |
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

O executor do modelo pode construir o snapshot com `montar_snapshot_site()` usando o manifesto e os totais que já leu. Isso evita combinar uma previsão com um snapshot posterior do coletor. O publicador acrescenta o histórico e troca o JSON por inteiro, de forma atômica.

Há também um importador de **dados observados**, que não calcula previsões:

```sh
python3 scripts/import_tse.py --source /caminho/previsao_tempo_real/data/live/tse_export
```

O modelo permanece no projeto de origem; este repositório contém a aplicação e seus adaptadores de saída. Os formatos antigos de previsão não são tratados como se fossem a saída final do modelo adaptativo.

## Verificar e empacotar

Requer Node.js 20 ou superior somente para os testes JavaScript; a aplicação no navegador não depende de Node.

```sh
node --test tests/data.test.js
python3 -m unittest discover -s tests -p 'test_*.py'
python3 scripts/build.py
```

O último comando produz `dist/`, pronto para hospedagem estática. Também há atalhos `npm run dev`, `npm test` e `npm run build`, sem etapa de instalação.

Consulte [operação e publicação](docs/OPERACAO.md), [decisões de apresentação](docs/DESIGN.md) e [estado da entrega](docs/STATUS.md). Publicação e conexão à saída definitiva do modelo são etapas registradas separadamente.
