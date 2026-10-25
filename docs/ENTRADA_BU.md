# Entrada operacional de BUs

Política acrescentada em 25/10/2026 por solicitação expressa do usuário. Ela substitui
a restrição operacional anterior a `Totalizado`. As fontes estatísticas congeladas,
as escalas e os estados iniciais continuam com os mesmos identificadores.

## Descoberta e validação

O serviço usa `scripts/collector_live.py`, que verifica o SHA-256 do coletor original
e reutiliza seu decoder BER, seu lock e a publicação atômica de snapshots.
`deployment/collector-2026.json` configura as entradas aceitas:

- A lista geral do TSE continua sendo consultada para todas as UFs.
- Os índices individuais do exterior (`ZZ`) também são consultados quando a lista
  ainda não anunciou o arquivo. São até 200 novas consultas por ciclo, com rotação.
  Um índice ausente recebe espera de 15 minutos. Um anúncio novo ignora essa espera.
- `Recebido` e `Totalizado` são aceitos em qualquer UF. `Totalizado` tem prioridade.
- Cada arquivo precisa identificar a eleição 6258, as candidaturas 13 e 22 e a mesma
  seção solicitada. Votos, brancos, nulos, comparecimento e aptos devem ser coerentes.
- `Recebido` é um BU disponível no TSE. Esse status não afirma que a seção já integra
  a totalização oficial. Os dois números ficam separados no status operacional.

## Parcial publicado no site

Desde 25/10/2026, a partir do snapshot publicado às 10h12 de Brasília, o quadro "Apurado até agora" e as linhas
observadas do gráfico usam os mesmos BUs que entram no modelo, com status `Recebido`
ou `Totalizado`. Um BU publicado pelo TSE aparece no parcial no primeiro ciclo em que
o modelo o incorpora, inclusive antes do início da totalização oficial às 17h.

No snapshot, `counting.reported_sections` é o número de seções com BU incorporado
(`secoes_apuradas_coletor` no resumo do checkpoint). `votes_a` e `votes_b` são as
somas desses BUs (`votos_a_observados` e `votos_b_observados`), e `valid_votes` é a
soma dos dois. `total_sections` e `source` continuam vindo da totalização oficial
escolhida. Depois das 17h, o percentual de seções do site pode diferir do painel do
TSE, porque o site conta BUs recebidos ainda não totalizados e depende do ritmo do
coletor. A projeção usa exatamente o mesmo conjunto mostrado no parcial.

### Previsão sem aprendizado para as seções apuradas

Desde 25/10/2026, às 11h10, o quadro mostra também a previsão do modelo sem aprendizado
para as mesmas seções já apuradas (`counting.prior_share_a`). É a média da previsão por
seção, ponderada pelos votos válidos observados em cada seção apurada, e se compara
diretamente com o percentual apurado das mesmas seções. A diferença indica o quanto o
resultado dessas seções se afastou da priori.

A previsão por seção foi congelada às 11h09 por `scripts/freeze_prior_sections.py` em
`previsao-sem-aprendizado.csv`, na pasta da execução (fora do Git), com manifesto em
`previsao-sem-aprendizado.json` (checkpoint 490, SHA-256 `59ae5076…`). Nas seções então
pendentes, usa `pct_a_2022`, que mantém coeficientes, choques municipais e razão de válidos
na prior. Nas 171 seções já apuradas, usa `pct_a_modelo`, calculado com peso de
aprendizado de 6,6 × 10⁻⁶; a diferença em relação à prior é desprezível nessa escala.
A cada ciclo, `previsao_sem_aprendizado_apuradas()`, em `integracao/executar_pipeline.R`,
cruza a tabela com as seções apuradas do `secoes.csv` do checkpoint. Sem a tabela, ou com
alguma seção apurada fora dela, o campo fica ausente e o site omite a linha.

A montagem está em `montar_snapshot_site(..., apurado = )`, em
`integracao/exportar_previsao_site.R`. `integracao/executar_pipeline.R` informa o
argumento a partir do checkpoint. Sem `apurado`, a função mantém o comportamento
anterior e usa a totalização oficial.

## Duplicação, confirmação e revisão

Dentro da eleição fixada no banco, a chave é `(uf, cd_mun, zona, secao)`. Existe apenas
uma observação ativa por chave na tabela `results`, independentemente do caminho de
descoberta. O campo `entry_paths` registra os caminhos usados. O banco preserva
versões em `bu_versions` e decisões em `bu_events`, além dos bytes e hashes originais
no arquivo bruto do coletor.

Uma confirmação posterior como `Totalizado` substitui o status da mesma seção. Uma
correção válida substitui seus votos. O executor recompõe a atualização a partir do
prior original e do conjunto atual de BUs, de modo que a revisão não é adicionada
por cima da versão anterior.

Para vários `Recebido`, a versão com data/hora de recepção inequivocamente mais recente
tem prioridade. Dois `Totalizado` distintos, empates entre versões contraditórias,
identificação interna errada ou mudança dos bytes sob o mesmo hash deixam a seção
em quarentena. A observação ativa é retirada, e o histórico permanece disponível.
Uma resposta mais antiga ou uma regressão de `Totalizado` para `Recebido` preserva a
última versão válida e registra o conflito. Uma falha de rede também preserva essa
versão. A reconsulta verifica índice, prioridade e integridade do conteúdo.

## Seções que mudaram

O inventário vigente do TSE define as unidades de BU. Seções agregadas (`nsp` e `nsa`)
são representadas pela seção principal. Principal e agregadas não entram como BUs
independentes. O coletor verifica referências e pertencimento a uma única unidade.

Uma correção de BU com a mesma chave segue a substituição descrita acima. Mudança de
numeração, criação, extinção ou mudança da composição de uma agregação exige
reconciliar a população com os dados do primeiro turno. Não se deve supor que uma
seção renumerada tenha os mesmos eleitores da antiga. Havendo correspondência
oficial, ela deve ser registrada. Para uma agregação diferente, somam-se primeiro
os numeradores e denominadores do T1 e depois calculam-se as covariáveis.

Quando não houver correspondência segura, o preparador existente dispõe de fallback
de zona e depois UF para covariáveis ausentes, com indicação dessa origem. Isso exige
uma nova versão da população inicial, preservando a anterior e mantendo fit e escalas
fixos. Esta alteração operacional não cria uma correspondência automática.

Durante a execução, qualquer mudança nas chaves ou nas agregações do inventário
interrompe a publicação do novo snapshot, grava `inventory-change.json` e preserva
o último snapshot válido. A retomada requer a reconciliação e a nova população.

Em 25/10/2026, a comparação dos cadastros oficiais do exterior entre T1 e T2 encontrou
1.351 unidades em cada turno, nenhuma chave acrescentada ou removida e nenhuma
composição de agregação alterada. Essa verificação entre turnos abrange `ZZ`.

## Verificação e operação

`tests/test_collector_live.py` cobre descoberta, repetição, confirmação, revisão,
conflitos, identidade, contabilização, espera por índices ausentes e mudança de
inventário. `scripts/check_live_input.py` reproduz a coleta a partir de uma conferência
preservada, sem rede e sem alterar a produção, e prepara snapshots isolados para R.

O serviço supervisionado recebe o comando da camada operacional em
`local/services/settings.json`. Há um único coletor e o mesmo banco compartilhado.
Os dois modelos leem o export existente a cada 60 segundos. A janela continua
terminando em 26/10/2026 às 08h de Brasília. Não iniciar coleta depois dela.

O mapa de países do painel local foi ampliado de 19 para 28 municípios, cobrindo
os 21 países da conferência preservada, inclusive a Índia. As chaves e os nomes de
municípios foram conferidos com o cadastro ZZ. Esse mapa organiza a apresentação
por país e não altera os cálculos nacionais ou os coeficientes.
