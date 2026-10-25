# Estado da entrega

Atualizado em 25/10/2026. Os registros anteriores abaixo preservam suas datas.

## Gráfico parte da priori (25/10)

Com 166 BUs do exterior, a linha contínua do gráfico (parcial apurado) começava em 30,8%
para A e 69,2% para B, e a ligação tracejada partia desse ponto. Por decisão do
operador, o gráfico passou a mostrar a projeção do resultado final em cada atualização,
a partir da previsão inicial em 0% das seções. O parcial permanece no quadro “Apurado
até agora” e aparece no tooltip.

- `scripts/contract.py` e `web/assets/data.js`: entradas de `history` aceitam os trios
  opcionais `forecast_*` e `forecast_2022_*`; o publicador grava a projeção dos dois
  cenários em cada nova entrada.
- `web/assets/chart.js`: `projectionPoints()` monta a série (primeira entrada em 0%,
  última revisão nas demais posições); a faixa acompanha o intervalo de cada
  atualização e segue constante depois de “Agora”. O tooltip mostra a projeção e o
  apurado até a posição; o percentual de seções usa duas casas abaixo de 1%.
- `web/assets/app.js` e `web/index.html`: legenda “Projeção durante a apuração” e
  “Projeção atual”, nota do gráfico e texto da leitura da incerteza.
- Testes: 57 JavaScript e 122 Python (venv do coletor, 1 ignorado).

Ordem da operação: deploy do Worker e do site (versão
`cbe52a87-abe5-4367-8bf5-c9cdc6b0071d`), que aceitam os dois formatos; cópia de
`public/latest.json` antes da alteração; preenchimento de 437 das 461 entradas do
histórico a partir do `historico.csv` do modelo, sob o lock do publicador (24 entradas
das 10h10 em diante, com parcial oficial 0 e BUs já no modelo, ficaram sem projeção);
SIGINT no publicador às 10h28. O preenchimento usou `scripts/backfill_history_forecast.py RUNTIME --write`. O launchd o reiniciou em menos de um segundo, na mesma
execução, e a primeira publicação nova (13:28:28Z) já trouxe a projeção no histórico.
Páginas abertas antes do deploy com o JavaScript anterior recusam o histórico novo e
mostram “Não foi possível atualizar” até serem recarregadas.

## Parcial com BUs recebidos (25/10)

Às 10h, o site mostrava zero votos apurados com 166 BUs do exterior já coletados, todos
com status `Recebido`. A projeção já incorporava esses BUs: 14.654 votos para A e 32.893
para B, que moveram a estimativa de 47,35341% para 47,35387%, conforme a atualização
gradual prevista no modelo. O parcial lia a totalização oficial, zerada até as 17h.

Por decisão do operador, o parcial passou a usar os BUs incorporados pelo modelo,
recebidos ou totalizados ([critério](ENTRADA_BU.md#parcial-publicado-no-site)):

- `integracao/exportar_previsao_site.R`: `montar_snapshot_site()` aceita `apurado`
  (seções, votos de A e de B) e o usa em `counting`. Sem o argumento, mantém o
  comportamento anterior.
- `integracao/executar_pipeline.R`: passa `secoes_apuradas_coletor`,
  `votos_a_observados` e `votos_b_observados` do resumo do checkpoint.
- `web/`: "totalizadas" passou a "apuradas" no quadro, no gráfico, no rodapé e nos
  detalhes da fonte. O avanço mostra a contagem de seções e usa duas casas decimais
  abaixo de 1% (por exemplo, "0,03% das seções apuradas (166 de 499.248)").
- `tests/check_r_adapter.R`: caso com totalização oficial zerada e BUs recebidos.

O publicador relê o R a cada ciclo; não houve reinício de serviço. O primeiro snapshot
com o parcial foi gerado às 13:10:00Z. O envio dele ao KV falhou com o 401 horário do
token OAuth do wrangler, que se repete desde a manhã e se resolve no ciclo seguinte.
O snapshot das 13:12:54Z chegou ao endpoint com 166 seções e 47.547 votos válidos.

Verificação: teste do adaptador R; 55 testes JavaScript; 121 testes Python com o venv
do coletor (1 ignorado; no Python do sistema, 14 falham por falta de `asn1tools`);
prévia local com o JSON de produção; deploy do Worker (versão
`3b63fb91-d6ea-47ed-97ff-8e1432596729`, 3 arquivos estáticos); `app.js`, `chart.js` e
`index.html` públicos idênticos aos locais. As alterações não foram commitadas.

## Início da coleta antecipado para 00h em 24/10

O operador autorizou antecipar o início das consultas para **25/10 às 00h**, Brasília.
A configuração operacional está em
[`../deployment/collector-2026.json`](../deployment/collector-2026.json), passada
explicitamente ao coletor por `--config` e lida também pelos supervisores. O fim
permanece em 26/10 às 8h. A única mudança nos campos da coleta é o horário inicial.
Os filtros, incluindo a exigência de estado `Totalizado`, os limites e a lista de
UFs com `ZZ` foram preservados.

Os dois supervisores foram recarregados no domínio `system`, sem processos antigos
remanescentes. O coletor confirmou espera pela nova janela, e o novo publicador
enviou os dois cenários à Cloudflare. O JSON público coincide com a saída local e o
upload. Foram verificados os hashes das fontes congeladas, o mesmo estado inicial,
runtime e checkpoint. Os 63 arquivos do release público também mantêm seus hashes.
A referência do teste de partida sem login foi preservada, e a reinicialização física
do Mac permanece pendente. Evidência em
[janela-coleta-20261024.json](validacao/janela-coleta-20261024.json).

## Preparação do teste de partida sem login em 24/10

O supervisor passou a registrar a identificação da partida do macOS e o estado da
sessão gráfica no instante em que inicia o filho. Os registros históricos privados
permitem distinguir um início na tela de login de um início após a entrada na conta.
O verificador exige uma nova partida, os dois jobs em `system`, confirmação de
`loginwindow` e os mesmos processos ainda ativos com status recente.

Passaram 89 testes Python. A referência da partida atual foi salva, e o verificador
recusou corretamente confirmar uma reinicialização que ainda não ocorreu. O novo
registro foi confirmado na recarga dos supervisores descrita acima. O procedimento está em
[SERVICOS.md](SERVICOS.md#teste-com-reinicialização-física). A reinicialização física
permanece pendente de execução pelo operador.

O exterior (`ZZ`) já constava da configuração. Na etapa de preparação, a janela ainda
começava em 25/10 às 17h, Brasília. Foi proposta a antecipação para 00h para consultar
eventuais arquivos de seção anteriores à divulgação dos totais. A aprovação e a
aplicação dessa mudança estão registradas acima, mantendo a exigência de hash `Totalizado`.
O art. 263 trata da disponibilização dos boletins recebidos, enquanto o art. 265,
§ 1º, fixa 17h para divulgação dos resultados presidenciais, inclusive do exterior.
Referência consultada em 24/10/2026:
[Resolução TSE nº 23.751/2026](https://www.tse.jus.br/legislacao/compilada/res/2026/resolucao-no-23-751-de-26-de-fevereiro-de-2026?texto=compilado).

## Instalação de sistema confirmada em 24/10

O operador executou o instalador com autenticação administrativa. Coletor e publicador
estão carregados no domínio `system`, com `RunAtLoad`, plists `root:wheel` de modo 0644
em `/Library/LaunchDaemons/` e execução dos componentes na conta comum do operador.
Os LaunchAgents anteriores foram retirados. A configuração local seleciona agora o
modo sistema por padrão.

O teste real interrompeu os dois supervisores e confirmou sua retomada automática,
com remoção dos filhos antigos. Houve um erro inicial de autenticação no envio à
Cloudflare, seguido de envio bem-sucedido na retentativa. O JSON público e os dois
cenários foram conferidos contra a saída do mesmo runtime e checkpoint.
Não foi feita reinicialização física do Mac nem encerramento da sessão gráfica.
Evidência em [launchdaemons-20261024.json](validacao/launchdaemons-20261024.json).

## Preparação para iniciar antes do login em 24/10

O gerenciador recebeu o modo `--scope system`, que prepara LaunchDaemons no domínio
`system`, com `UserName` da conta comum e instalação administrativa. Os dois plists
foram gerados e validados. Passaram 83 testes Python, incluindo testes de migração,
permissões definidas na instalação e retorno aos LaunchAgents em caso de falha.

Na etapa de preparação, a instalação aguardava autenticação administrativa e os
LaunchAgents continuavam ativos. Essa etapa foi concluída pela instalação de sistema
documentada acima. Evidência histórica em
[launchdaemons-preparacao-20261024.json](validacao/launchdaemons-preparacao-20261024.json).

## Supervisão automática e concordância de fontes em 24/10

Coletor e publicador foram transferidos para dois LaunchAgents do `launchd`, com início
no login e retomada após encerramento. Os supervisores respeitam o fim da janela
eleitoral, preservam o runtime e checkpoints e não deixam cópias antigas concorrentes.
Os detalhes estão em [SERVICOS.md](SERVICOS.md). Os testes reais encerraram processos
para verificar a retomada, sem reiniciar fisicamente o Mac.

Foi padronizada a concordância de “fontes” no feminino na documentação e nas mensagens
do código. As fontes estatísticas
congeladas e os parâmetros do modelo foram preservados. Evidência em
[servicos-20261024.json](validacao/servicos-20261024.json).

## Código no GitHub em 24/10

O código foi publicado em [mgaldino/petapura](https://github.com/mgaldino/petapura),
na branch `main`, com visibilidade pública expressamente autorizada pelo tutor.
O rodapé de Apuração, Sobre o modelo e Quem somos contém “Código no GitHub”.
O envio inicial corresponde ao commit `0f8a249`.

O repositório reúne o site, Workers, adaptadores, testes e 63 fontes R, Stan, Python e
JSON do release do modelo em produção, conferidos byte a byte. O diretório `modelo/`
também contém a especificação ASN.1 e as dependências do coletor. Seu README documenta
os dados e objetos ajustados necessários para executar o código. Os registros
administrativos, credenciais, arquivos de runtime e capturas privadas de analytics
permanecem locais.

Passaram 55 testes JavaScript e 69 testes Python na preparação. O acesso anônimo a
arquivos no GitHub, os destinos dos links nas três páginas e o rodapé móvel foram
conferidos após a publicação. Evidência em
[github-20261024.json](validacao/github-20261024.json).

## Fórmulas em LaTeX com MathJax em 24/10

A página “Sobre o modelo” usa MathJax 4.1.3 para as equações, priors e símbolos no
texto. A biblioteca é carregada por CDN, apenas nessa página. Os valores e as hipóteses
do modelo foram preservados. A configuração renderiza cada bloco depois de aberto,
usando sua largura efetiva, e refaz a composição quando essa largura muda.

Os três blocos abertos foram conferidos no navegador em desktop e em iframe de 320px,
inclusive após ampliar, reduzir e fechar/reabrir. Foram renderizados 42 contêineres de
matemática, sem erros TeX ou excesso de largura. Evidência em
[mathjax-20261024.json](validacao/mathjax-20261024.json).

## Conexão da atualização automática conferida em 24/10

Naquela conferência, o coletor estava ativo e aguardava 25/10 às 17h de Brasília. Foi encontrada e corrigida uma
interrupção operacional: o publicador dos cenários havia parado em 23/10 às 01h21.
O processo foi retomado em segundo plano, com o mesmo checkpoint e fontes congeladas.
O upload remoto foi concluído, e o JSON público coincide com a saída real do executor R,
contendo os dois cenários do mesmo snapshot. A página consulta esse endpoint a cada 30s;
coletor e publicador trabalham em ciclos de 60s, além do tempo de processamento.

O replay isolado com as fontes da produção passou em 107 verificações e 24 etapas.
Também passaram os 55 testes JavaScript e três testes do publicador. Não foram enviados
dados fictícios à produção. O Mac precisa continuar ligado, conectado e acordado.
Naquela conferência o publicador ainda não tinha reinício automático. A configuração
posterior de supervisão está descrita no início deste documento.
Evidência em [conexao-20261024.json](validacao/conexao-20261024.json).

## Introdução e espera pela apuração em 24/10

A abertura explica que o modelo projeta o resultado final com base nas urnas já apuradas.
Antes dos primeiros resultados, preserva as caixas dos cenários com “ND” (não disponível)
no percentual e na faixa. O gráfico fica em 50% / 50%, identificado como referência
visual de espera por urnas apuradas, inclusive na descrição acessível. Os números da
prior, o parcial e os detalhes de incerteza permanecem ocultos. Os valores dos cenários
e o gráfico efetivo aparecem automaticamente quando há seções totalizadas ou BUs incorporados.
O snapshot e os cálculos do modelo continuam preservados.

Passaram 55 testes JavaScript. Em cópia local isolada, foram verificadas sem recarregar
a página as transições zero → primeiro BU fictício → apuração concluída → correção
para zero, além do controle da demonstração. A abertura foi inspecionada em desktop
e em uma janela de 320 pixels. A revisão para ND e referência 50% / 50% foi conferida
novamente no navegador. Evidências em [espera-nd-20261024.json](validacao/espera-nd-20261024.json).
O registro [abertura-20261024.json](validacao/abertura-20261024.json) documenta a versão
anterior, em que o gráfico ficava oculto.

## Páginas separadas e menu em 23/10

“Quem somos” e “Sobre o modelo” agora têm páginas próprias em `/quem-somos/` e
`/sobre-o-modelo/`. O menu comum indica a página atual e permite voltar à apuração.
O conteúdo foi preservado integralmente. O analytics também carrega nas páginas
de conteúdo. Passaram 51 testes JavaScript, a conferência dos destinos do menu e a
inspeção das três páginas em desktop e a 320 pixels, sem transbordamento horizontal.
Registro em [paginas-20261023.json](validacao/paginas-20261023.json).

## Conteúdo institucional e metodologia em 23/10

Foram acrescentadas as seções “Quem somos” e “Como é feita a projeção”, com atalhos no
início da página. A explicação inclui preditores, hierarquia por UF, equações e priors,
mudanças entre eleições, aprendizado gradual e componentes locais. A correspondência
com a cópia congelada do modelo e as fontes institucionais estão em
[CONTEUDO.md](CONTEUDO.md). A lista de 12 estudantes foi incluída em “Quem somos”.
Os registros administrativos de conferência permanecem apenas no arquivo local.

## Preparação para publicação em 22/10

O site agora mostra separadamente os cenários com aprendizado e relação de 2022,
exportados do mesmo checkpoint. A prior real, com zero BUs e 499.248 seções, foi executada
e preservada: 47,3534% para Lula, faixa de 95% de 43,0195% a 51,4416%. Os dois cenários
coincidem na prior. Registro em [prior-20261022.json](validacao/prior-20261022.json).

Configuração do Workers, endpoint de leitura no KV, publicador autenticado e integração
configurável do Web Analytics estão implementados. O build de produção recusa dados de
demonstração e ausência de um dos cenários; a exigência de analytics é opcional no build.

Passaram 51 testes JavaScript, 69 Python e 107 verificações no replay de 24 etapas. A
troca de cenário e a largura móvel foram conferidas no navegador. O empacotamento
`wrangler deploy --dry-run` passou. A publicação em [petapura.eleicoes-pet.workers.dev](https://petapura.eleicoes-pet.workers.dev)
e o primeiro envio ao KV remoto foram concluídos. O JSON público corresponde ao snapshot
enviado pelo executor R. Web Analytics está cadastrado e configurado; o painel confirmou 2 visitas e 2
visualizações durante a verificação. Registro em [analytics-20261022.json](validacao/analytics-20261022.json). O publicador contínuo está ativo no Mac, consultando o export a cada 60 segundos, sem
iniciar outro coletor. Depende do Mac ligado e conectado. Operação em
[CLOUDFLARE.md](CLOUDFLARE.md).

## Implementado neste repositório

- Aplicação responsiva baseada no Observatório aprovado, sem dependência do Codex, frameworks ou bibliotecas de frontend.
- Resumo numérico de A, gráfico A vermelho/B azul, limiar de 50%, incerteza explícita, parcial após o gráfico e crédito ao PET de Ciências Sociais da USP.
- Endpoint JSON configurável e consultas periódicas, com timeout, uma requisição por vez, aviso de falha/desatualização e preservação do último resultado válido.
- Estados de espera, previsão inicial com zero BUs, contagem sem previsão, previsão com probabilidade ausente e apuração concluída.
- Contrato público versionado, validadores Python/JavaScript, proteção de identidade da eleição e de candidaturas e rejeição de campos internos fora do contrato.
- Publicação atômica, lock para um único escritor, histórico, idempotência e tratamento de correções.
- Leitor do export existente do coletor e funções R para exportar a previsão e montar um snapshot com os objetos já lidos pelo executor.
- Demonstração separada e identificada. Nenhum dado sintético preenche silenciosamente o endpoint real.
- Mockup aprovado e pesquisa de benchmark arquivados, com suas fontes e referências.
- Integração executável com a API atual `avancar_previsao_analise()`, checkpoint e publicador, em `integracao/executar_pipeline.R` e `scripts/run_local.py`.
- Simulação local interativa: 2.800 seções fictícias, 24 lotes, 400 sorteios por cálculo, avanço automático e página sem controles de operação. Usa o publicador original do coletor, o leitor TSE e o modelo adaptativo reais.
- Modo `--mode tse` lê o export existente e processa a população real, sem iniciar coletor e sem gravar no módulo do modelo. Modos real e fictício usam pastas separadas.

## Executado e verificado

| Verificação | Resultado |
|---|---|
| Testes JavaScript | 38 passaram: contrato, identidade, intervalos/probabilidade, consultas, timeout, falhas, regressão temporal e rótulos em empate |
| Testes Python | 63 passaram: publicação, coletor sintético, controles HTTP, concorrência, recuperação, isolamento e preservação do último válido |
| Interoperabilidade R | JSON exportado com 95%, probabilidade nula e zero BUs aceito pelos validadores Python e JavaScript |
| Integração com export real local | 499.248 seções e zero BUs; executor produziu a previsão inicial e o adaptador publicou o JSON do site |
| Inspeção no navegador | Aplicação com a demonstração, espera sem dados, intervalo de 95%, probabilidade ausente, previsão com zero BUs e fim da apuração |
| Layout compacto | Largura de 320 pixels sem rolagem horizontal; rodapé e rótulo Agora legíveis |
| Empacotamento | `dist/` gerado a partir de `web/` |

Os resultados automatizados estão em [testes.json](validacao/testes.json). A importação está registrada em [importacao-coletor.json](validacao/importacao-coletor.json). O esquema JSON é acompanhado de validadores com verificações relacionais; não há dependência de um pacote externo de JSON Schema na aplicação.

## Integração verificada nesta etapa

O replay completo passou em **81 verificações**, com 24 estágios de zero a 100%, intervalos de 95% preservados, BR/SOMA_UFS, repetição idempotente, retomada após ponteiro atrasado e rejeição de fixture no modo real. No fim, votos e percentual coincidiram com a verdade sintética e o intervalo colapsou. O replay levou 22,508 segundos nesta máquina. Fontes e estado inicial do módulo do modelo tiveram os mesmos hashes antes e depois.

O caminho real também foi executado com o export local disponível, de **499.248 seções e zero BUs**, em aproximadamente **10,5 segundos**. Produziu a previsão inicial com quantis de 95% através do executor e do adaptador público. Não consultou a rede. Registro em [tse-modelo-site.json](validacao/tse-modelo-site.json); replay em [replay-integrado.json](validacao/replay-integrado.json).

A primeira integração foi conferida no navegador com controles de teste. Esses controles foram removidos na correção posterior, e a simulação passou a avançar automaticamente. O layout integrado a 320 pixels permaneceu sem rolagem horizontal. A probabilidade de vitória continua indisponível no adaptador.

## Falta para a operação pública

1. Verificar o fluxo nas condições finais de operação, incluindo ritmo real de chegada/correções dos BUs T2, falhas de rede e desempenho sustentado. O caminho integrado e o replay sintético já foram executados localmente.
2. Publicação concluída em 22/10 no Workers; acompanhar a operação contínua do coletor e publicador na janela da apuração.

A publicação no Workers foi concluída em 22/10, conforme o registro no início deste documento. O guia para testar agora está em [LOCAL.md](LOCAL.md).

## Limites da verificação

Os testes estatísticos e a calibração dos intervalos pertencem ao modelo. As fixtures e os exemplos deste site são sintéticos e não demonstram cobertura preditiva eleitoral. A importação real verificou a leitura do export local disponível em 20/10; não é um teste com votos futuros do segundo turno. A inspeção de largura compacta foi em navegador, sem auditoria completa de acessibilidade ou teste em todos os aparelhos.

## Correção da execução automática

A falha relatada era a leitura de um checkpoint antigo por uma versão mais nova da API do modelo. Cada execução agora preserva as fontes/configurações e seus hashes em `model-source/`; o leitor R e o coletor sintético usam essa mesma versão. Execuções anteriores sem esse registro são mantidas e uma nova execução compatível é criada.

O teste HTTP automático partiu de uma cópia da execução que falhou, percorreu as 24 etapas sem enviar ações e chegou a 100% sem erros em 60,998 segundos. Os checkpoints anteriores foram preservados e os votos finais coincidiram com a fixture. Reabrir a execução concluída também passou. Registro em [automatico.json](validacao/automatico.json). A página agora atualiza automaticamente, sem botões de reprodução, avanço, reinício ou seleção de intervalo.
