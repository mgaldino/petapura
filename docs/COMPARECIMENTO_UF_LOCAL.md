# Comparecimento variando por UF: acompanhamento local

Esta execução usa o ajuste histórico `ambos`, já estimado em 2022: intercepto,
coeficiente do voto de Lula no primeiro turno e coeficiente do comparecimento variam
entre as 27 UFs e o exterior (`ZZ`). Os coeficientes de votos nas demais candidaturas
e da proporção de válidos continuam compartilhados. São 86 coeficientes conjuntos.

O ajuste histórico passou pelos diagnósticos salvos: R-hat máximo 1,00509, ESS mínimo
1.191,55, nenhuma divergência e nenhum limite de profundidade atingido. Não foi
executado outro MCMC. A extensão reutiliza a posterior conjunta desse ajuste.

As escalas V2 e os componentes locais permanecem os escolhidos anteriormente. A escala
`comp_sd = 0,02` gera um choque nacional compartilhado pelas inclinações de
comparecimento de todas as UFs. As diferenças históricas entre as inclinações e sua
covariância vêm do ajuste `ambos`. Não foi acrescentada uma nova dispersão de mudança
de comparecimento específica de UF. O aprendizado atualiza o vetor conjunto de 86
coeficientes; a relação de 2022 mantém a distribuição inicial nas seções pendentes.

## Operação

- Painel: <http://127.0.0.1:4174/>, acessível somente neste Mac.
- Consulta ao mesmo export do coletor: a cada 60 segundos, além do tempo de cálculo.
- Atualização visual do painel: a cada 5 segundos.
- Relatório atual: `local/comparecimento-uf/latest-report.json`.
- Relatório legível: `local/comparecimento-uf/relatorio.md`.
- Histórico por checkpoint: `local/comparecimento-uf/history.jsonl`.
- Estado operacional: `/api/status` ou `local/comparecimento-uf/status.json`.

A previsão inicial local em 24/10 foi de 47,3666% para Lula, com faixa de 95% entre
42,9222% e 51,4993%. Os dois cenários coincidem antes dos BUs. O painel apresenta
também os resultados por UF e pelos 13 países do exterior acompanhados no chat.
A comparação com a projeção pública aparece somente quando os dois modelos usam o
mesmo snapshot de origem. O horário da última consulta é separado do horário em que
a previsão foi calculada, sem fabricar atualizações quando os dados não mudam.

Um heartbeat deste chat verifica o resultado a cada cinco minutos até 26/10 às 8h,
Brasília. Ele reporta os primeiros BUs ou checkpoints novos com mais boletins e
permanece em silêncio sem novidade. Usa `chat-last-reported.json` para evitar
repetições. O painel oferece a atualização mais frequente.

O serviço local é um LaunchAgent chamado `br.usp.petapura.turnout-uf`. Ele retoma em
caso de falha e inicia no login da conta. Os LaunchDaemons do coletor e do publicador
público permanecem no domínio `system`, com início antes do login. A execução local
encerra normalmente no fim da janela, em 26/10 às 8h. O monitor depende do Mac ligado
e do aplicativo disponível para as verificações do chat.

## Reprodução e administração

```sh
python3 scripts/run_turnout_local.py --prepare-only --rscript /caminho/Rscript
python3 scripts/run_turnout_local.py --once --rscript /caminho/Rscript
python3 scripts/run_turnout_local.py --rscript /caminho/Rscript
```

O último comando roda em primeiro plano. Antes de executá-lo manualmente, retire o
serviço existente para não disputar o lock:

```sh
launchctl bootout gui/$(id -u)/br.usp.petapura.turnout-uf
```

O plist permanece em `~/Library/LaunchAgents/`, voltando a iniciar no próximo login.
Para retomá-lo imediatamente:

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/br.usp.petapura.turnout-uf.plist
```

`--install-agent` instala a primeira vez. Ele recusa sobrescrever um serviço já
instalado. `--base` permite outra pasta de execução. Se a extensão mudar, prepare uma
pasta nova e não reaproveite os checkpoints anteriores.

## Isolamento e verificações

O preparo copia as fontes congeladas da produção para `local/comparecimento-uf/`,
acrescenta a extensão versionada em `experimentos/comparecimento_uf/extensao.R`,
registra novos hashes e cria outro estado inicial. O fit, o estado, os checkpoints,
o pipeline e as saídas têm pastas próprias. O coletor é compartilhado por leitura do
export existente. Esta execução não inicia outro coletor e não tem etapa de upload
para Cloudflare. O código público, as fontes congeladas e os checkpoints do site
continuam preservados. Não foram enviados os dados de teste à produção.

Passaram 97 testes Python, a verificação estatística da parametrização e o replay
integrado com 107 verificações em 24 etapas. O replay testa os dois cenários,
aprendizado, idempotência, retomada, igualdade aos votos finais e recusa de dados
sintéticos no modo real. A verificação estatística confere os 86 coeficientes, a
decomposição da covariância, a invariância da prior de 59 coeficientes e a recusa de
checkpoints de produção. Também passou o acompanhamento automático por HTTP das 24
etapas, sem comandos de avanço, usando o servidor e o worker reais. O teste de
interrupção confirmou retomada automática com o mesmo checkpoint e preservação dos
processos públicos. Essas verificações são funcionais, não uma validação de
cobertura dos intervalos em eleições reais.

Evidências locais: `initial-validation.json`, `statistical-verification.json`,
`restart-verification.json` e `operational-verification.json`, em
`local/comparecimento-uf/`, e o replay em
`local/validacao-comparecimento-uf-20261024/verification.json`.
O teste automático está em `local/validacao-uf-http-20261024/verification.json`.

```sh
Rscript --vanilla experimentos/comparecimento_uf/verificar.R
python3 tests/replay_turnout.py --model-dir /caminho/modelo-com-dados \
  --runtime local/validacao-uf-nova --rscript /caminho/Rscript
python3 tests/check_turnout_automatic.py --runtime local/validacao-uf-http-nova
```
