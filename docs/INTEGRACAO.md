# Integração entre modelo e site

Versão 1, preparada em 20/10/2026. O contrato contém somente agregados nacionais do segundo turno presidencial. O site não estima o modelo nem recebe coeficientes, sorteios completos ou dados individuais.

Extensão de 22/10: `forecast` preserva o cenário com aprendizado; `forecast_2022` contém
o cenário relação de 2022, com o mesmo formato. O campo é opcional para manter a leitura
dos snapshots antigos, mas obrigatório no build de produção e no endpoint do Workers.
Ambos devem usar o mesmo `source_snapshot_id` e `generated_at`, correspondentes ao mesmo
checkpoint. Não se calcula uma média entre cenários. A prior anterior à janela de
apuração é identificada como previsão inicial; depois do início configurado, a ausência
de atualização volta a gerar o aviso de desatualização.

## Fronteira entre os projetos

| Responsável | Produto |
|---|---|
| Coletor existente | Manifesto consistente, totalização oficial escolhida e BUs |
| Executor do modelo | Previsão do resultado final, quantis, nível do intervalo, probabilidade quando calculada, versão e identidade do snapshot usado |
| Adaptadores deste repositório | JSON público validado, histórico e publicação atômica |
| Aplicação | Leitura periódica, apresentação, gráfico e aviso de falha/desatualização |

O módulo em desenvolvimento na outra sessão foi localizado em `2026/lab-regressao-aula/projeto_agna/previsao_tempo_real`, no repositório Regressao. Seu executor atual `previsao_execucao.R` já produz previsão por seção/UF/total e checkpoints. A integração local deste repositório chama essa API, preservando o estado inicial e a prior V2. Nenhum arquivo desse módulo é alterado por este site.

## Conteúdo do snapshot

O [JSON Schema](../schema/snapshot.schema.json) descreve os tipos. Os validadores em Python e JavaScript verificam também as relações entre campos.

| Campo | Regra |
|---|---|
| `version` | Inteiro `1` |
| `snapshot_id` | Identidade imutável da publicação; novo conteúdo exige nova identidade |
| `source_snapshot_id` | ID do snapshot do coletor usado para os totais e a previsão |
| `generated_at` | UTC explícito, terminado em `Z`; inclui data e segundos |
| `mode` | `waiting`, `live` ou `demo`; o endpoint real rejeita `demo` |
| `election` | 2026, segundo turno, Presidência; IDs esperados conferidos com a configuração |
| `candidates` | Identidade e nome de A e B; A em vermelho, B em azul |
| `counting` | Contagens oficiais, horário de recebimento e fonte escolhida; pode ser `null` |
| `forecast` | Previsão final e metadados; pode ser `null` |
| `history` | Histórico de contagens, mantido pelo publicador; até 4.000 entradas |

Percentuais de votos e limites são números de **0 a 100**. `interval.level` e `win_probability_a` usam **0 a 1**. Contagens são inteiros não negativos; votos de A + B devem ser iguais aos válidos. `reported_sections` não pode superar `total_sections`. Somente BR ou a soma completa de UFs/exterior podem representar a totalização nacional.

Um intervalo de 95% deve chegar com `level: 0.95` e seus limites originais. O site não o converte em 90%. A probabilidade pode ser `null`; ela não é inferida da média, do intervalo ou de uma hipótese normal. O ponto pode ser uma média fora do intervalo central em distribuições assimétricas; por isso não se impõe que ele esteja entre os quantis.

O horário textual original do TSE fica em `counting.source.generated_raw`, sem presumir um fuso que não tenha sido informado. `counting.generated_at` é o horário UTC de publicação do snapshot recebido. O horário do modelo fica em `forecast.generated_at`.

As notas em `forecast.notes` explicam hipóteses e limitações do modelo. São texto simples; não executam HTML. Campos fora do contrato são rejeitados para evitar publicar acidentalmente componentes internos do ajuste.

## Executor integrado pronto

`python3 scripts/run_local.py` inicia a simulação de ponta a ponta; `--mode tse` acompanha o export real já produzido pelo coletor. A ponte `integracao/executar_pipeline.R` carrega o estado inicial, recupera o checkpoint e chama `avancar_previsao_analise()`. Usa `cp$snapshot_manifest`, `cp$official_details$chosen` e `cp$results$resumo` do mesmo checkpoint, sem reler o ponteiro vivo após calcular.

O adaptador mapeia `pct_a_projetado`, `pct_a_q025` e `pct_a_q975` diretamente para a votação e o intervalo de 95%. Preserva a versão da prior e a identidade do estado inicial. `win_probability_a` fica nulo; essa saída ainda não é exportada pelo adaptador. A nota metodológica informa quando a âncora foi ou não aplicada.

Saídas e checkpoints ficam em `local/demo/` ou `local/tse/`, fora do módulo do modelo. O publicador original do coletor é usado na demo sem consultas de rede. A origem fictícia tem marcador no manifesto, `mode=demo` no JSON público e identificação persistente na página. O modo TSE recusa o marcador fictício. Ver [guia local](LOCAL.md) e [evidência do replay](validacao/replay-integrado.json).

## Alternativa: executor produz o snapshot completo

Use os objetos do snapshot que o executor já leu. Não releia o ponteiro do coletor depois de calcular a previsão: ele pode ter avançado nesse intervalo.

```r
source("/caminho/observatorio-presidencial-2026/integracao/exportar_previsao_site.R", encoding = "UTF-8")

# Os valores abaixo vêm do modelo; não são calculados pelo adaptador.
previsao_site <- exportar_previsao_site(
  caminho = "saida/previsao-site.json",
  snapshot_id = dados$manifesto$snapshot_id,
  versao_modelo = versao_modelo,
  percentual_a = percentual_a,
  limite_inferior = quantil_inferior,
  limite_superior = quantil_superior,
  nivel_intervalo = nivel_intervalo,
  probabilidade_vitoria_a = probabilidade_vitoria_a,
  notas = notas_metodologicas
)

montar_snapshot_site(
  caminho = "saida/snapshot-site.json",
  manifesto = dados$manifesto,
  totalizacao_escolhida = dados$detalhes_fontes$chosen,
  previsao = previsao_site,
  nome_a = nome_a,
  nome_b = nome_b
)
```

Em seguida, um único publicador:

```sh
python3 scripts/publish_snapshot.py \
  --input /caminho/saida/snapshot-site.json \
  --output /caminho/site-servido/data/latest.json
```

O publicador valida tudo antes da troca, protege contra escritores simultâneos, rejeita regressão temporal e reutilização indevida de IDs, incorpora o histórico e substitui o arquivo inteiro. O mesmo snapshot é idempotente. Correções de votos ou de seções são aceitas em um snapshot novo; o avanço pode diminuir em uma correção legítima.

## Alternativa: importar o export do coletor

```sh
python3 scripts/import_tse.py \
  --source /caminho/data/live/tse_export \
  --forecast /caminho/previsao-site.json \
  --name-a "Nome de A" --name-b "Nome de B"
```

`--forecast` é opcional. Sem ele, a página apresenta somente dados observados e sinaliza a ausência de previsão. O importador confere SHA256 do arquivo escolhido, identidade da eleição/candidaturas, caminho dentro do export e estabilidade do manifesto durante a leitura. Usa `chosen`, nunca soma BR e UFs. Se o coletor tiver avançado para outro ID enquanto o modelo calculava, a combinação é recusada; use o snapshot completo capturado em memória no caminho preferido.

Os arquivos do coletor são apenas lidos. A entrada não é um endpoint público de BUs, e o navegador não acessa diretamente centenas de milhares de seções.

## Antes, durante e ao final da apuração

- Zero BUs não impede uma previsão inicial, se o modelo fornecê-la. Não há limiar artificial de 2%.
- Se só houver contagem, a votação projetada permanece indisponível; não se apresenta o parcial como previsão.
- A chance de vitória fica ausente enquanto não for calculada.
- Com todas as seções totalizadas e votos válidos positivos, a interface usa o resultado observado e informa o fim da apuração.
- O envelope visual converge para o intervalo do resultado final. A ligação tracejada não estima a ordem de chegada dos votos. O tooltip no trecho futuro informa a estimativa final, sem inventar valores intermediários.

Para o gráfico, o histórico bruto permanece no JSON. A apresentação consolida revisões na mesma posição e usa pontos até o avanço atual, evitando desenhar votos antigos além da posição corrigida de “Agora”.

## Rede e hospedagem

A URL em `web/config.json` pode ser relativa ou um endpoint HTTP(S). Para outro domínio, configure CORS permitindo a origem do site. Sirva `latest.json` com `Content-Type: application/json; charset=utf-8` e `Cache-Control: no-store` (ou revalidação equivalente). Uma resposta deve conter o snapshot inteiro.

O cliente consulta a cada 30 segundos, com timeout de 10 segundos e uma consulta por vez. Falha HTTP, JSON inválido, eleição errada ou payload incoerente preserva o último estado válido e mostra um aviso. Após três minutos sem dados atuais, o site sinaliza desatualização. O horário da contagem e o do modelo entram nessa verificação.

Há exemplos sintéticos em `tests/fixtures/`, incluindo uma faixa de 95%, probabilidade ausente, previsão com zero BUs e apuração completa. Eles são testes; não devem alimentar o endpoint real.

## Versão do código por execução

As fontes e configurações do modelo são copiadas de forma consistente para `local/<modo>/runs/<id>/model-source/`, com SHA256 conferido antes de executar R. O coletor sintético também usa essa cópia. Isso mantém a API que criou o checkpoint mesmo se o módulo original for atualizado em outra sessão. Uma execução antiga sem esse registro é preservada e substituída por uma nova compatível. Os ajustes e pacotes históricos continuam sendo lidos do projeto do modelo; nenhum parâmetro estatístico é escolhido pela interface.
