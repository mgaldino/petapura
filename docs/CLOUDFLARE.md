# Publicação no Cloudflare Workers

Publicado em 22/10/2026: **[petapura.eleicoes-pet.workers.dev](https://petapura.eleicoes-pet.workers.dev)**.
A autenticação, o registro do subdomínio, a implantação pública, o cadastro de Web Analytics
e o primeiro envio remoto foram concluídos. A página e o endpoint responderam por HTTPS;
o JSON público corresponde exatamente ao snapshot enviado pelo executor R. A página foi
conferida no navegador com os dois cenários. O painel de analytics confirmou 2 visitas e 2 visualizações de página durante a
verificação inicial. Na conferência final, o painel marcou 4 visitas e 4 visualizações
com a exclusão de bots ativada. A demonstração não inclui o beacon.
Registro em `validacao/analytics-20261022.json` e captura em
`validacao/analytics-recebido-20261022.png`. Esses números incluem os acessos de teste.

Identificadores públicos em `../deployment/cloudflare.json`. O token do beacon é público;
credenciais de acesso à conta continuam fora do repositório.

## Supervisão configurada em 24/10

Coletor e publicador estão sob dois LaunchAgents do `launchd`. Eles iniciam no login
e retomam após encerramento inesperado, preservando o mesmo runtime e checkpoints.
A operação e os comandos atuais estão em [SERVICOS.md](SERVICOS.md). Para consultar:

```sh
python3 scripts/manage_services.py status
```

As observações anteriores de PIDs abaixo registram a história da implantação. O estado
atual deve ser consultado no `launchd` e em `local/services/`, não nos recibos históricos.

## Conferência operacional de 24/10/2026

O coletor estava ativo (PID 27739), aguardando a janela configurada para 25/10 às 17h
até 26/10 às 8h, Brasília. O export ainda tinha zero BUs, como esperado antes da janela.
O publicador de produção estava parado, com o último ciclo registrado em 23/10 às
01h21 de Brasília. Ele foi retomado em segundo plano (PID 22593), mantendo o runtime,
o checkpoint e as fontes congeladas existentes. O processo não inicia outro coletor.

O envio remoto foi concluído e o endpoint público respondeu HTTP 200, com
`Cache-Control: no-store`, entregando exatamente o JSON do modelo e do upload. Os dois
cenários têm o mesmo snapshot de origem e o mesmo horário de cálculo. Um snapshot sem
novos dados conserva sua identidade e horário, mesmo quando o ciclo de consulta roda.

O replay isolado executado com as mesmas fontes congeladas da produção passou em 107
verificações e 24 etapas, de zero a 100% das seções fictícias. Passaram também os 55
testes JavaScript e os três testes do publicador remoto. Dados fictícios não foram
enviados à produção. Evidência em `validacao/conexao-20261024.json`.

Coletor e publicador operam em ciclos de 60 segundos, além do tempo de processamento;
a página consulta os resultados a cada 30 segundos. A propagação do KV acrescenta seu
próprio tempo. A operação continua dependendo deste Mac ligado, conectado e acordado.
O coletor inicia `caffeinate` durante a janela se o Mac estiver acordado naquele momento.
Naquela conferência, ainda não havia serviço de reinício automático do publicador.
A supervisão instalada posteriormente em 24/10 está descrita acima.

## Componentes

- `dist/`: frontend baseado no mockup aprovado, com os dois cenários separados.
- `worker/index.js`: serve `/data/latest.json` sem cache HTTP. Valida a identidade da
  eleição e das candidaturas, a presença dos dois cenários e a origem real.
- KV `SNAPSHOTS`, chave `latest`: último JSON completo, enviado por um único publicador
  autenticado pelo Wrangler. Não há endpoint público de escrita.
- `deployment/initial-prior.json`: prior real usada antes do primeiro envio ao KV. Falha
  de leitura do KV retorna 503; o navegador preserva o último resultado válido.
- `scripts/run_cloudflare.py`: lê o export existente do coletor e executa o modelo em R.
  Não inicia outro coletor nem modifica o módulo original. Fontes são congeladas por execução.

O Worker serve a página e os resultados; o cálculo continua no executor R. Durante a
apuração, o Mac ou servidor com o coletor e o publicador precisa ficar ligado, conectado
e sem suspensão. A prior permanece disponível com essa máquina desligada, mas os dados
não avançam até o próximo envio. O KV pode levar cerca de 60 segundos para propagar uma
atualização; o site consulta a cada 30 segundos.

## Login e publicação

Foi instalada a ferramenta oficial Wrangler 4.152.0 em
`local/cloudflare-tooling/node_modules/.bin/wrangler`, pasta ignorada pelo Git, sem nova
dependência de frontend. O Node do Homebrew estava com uma biblioteca ausente; a
validação usou o Node 24.19.0 incluído no ambiente do aplicativo:

```sh
export PATH="/Users/manoelgaldino/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin:$PATH"
export WRANGLER_LOG_PATH="local/cloudflare/wrangler.log"
local/cloudflare-tooling/node_modules/.bin/wrangler login
local/cloudflare-tooling/node_modules/.bin/wrangler whoami
python3 scripts/build.py --production --snapshot deployment/initial-prior.json
local/cloudflare-tooling/node_modules/.bin/wrangler deploy
```

O subdomínio da conta é `eleicoes-pet.workers.dev` e o Worker se chama `petapura`.
O namespace KV `petapura-snapshots` foi provisionado no primeiro deploy; seu ID está
preservado em `wrangler.jsonc`. Não contrate nem altere planos pagos. Senhas e tokens de acesso
nunca devem entrar em `web/`, `dist/` ou no Git.

## Analytics

No painel Cloudflare, crie ou reutilize um site em Web Analytics para o hostname público
do Worker. O site já está cadastrado e o token público do beacon está preservado em
`web/config.json`. `PET_ANALYTICS_TOKEN` permite substituí-lo em um build. Esse token é
público; não é uma credencial da conta. Em seguida:

```sh
python3 scripts/build.py --production --snapshot deployment/initial-prior.json --require-analytics
local/cloudflare-tooling/node_modules/.bin/wrangler deploy
```

O build copia o token público para `dist/config.json`. O script usa `type="module"`,
como indicado pelo snippet oficial atual do painel Cloudflare. `--require-analytics` bloqueia o build se o
token estiver ausente. Sem ele, o site funciona e o tracking permanece desativado.
`assets/analytics.js` carrega o beacon oficial manualmente, excluindo localhost e a
demonstração `?demo=1`. O recebimento foi confirmado no painel em 22/10, além da presença do script no navegador.
O painel de produção está disponível no link preservado em `deployment/cloudflare.json`.

## Atualizações do modelo

Depois do deploy e do login, enviar um resultado:

```sh
python3 scripts/run_cloudflare.py --once --wrangler "$PWD/local/cloudflare-tooling/node_modules/.bin/wrangler"
```

Para acompanhar o export a cada 60 segundos, retirar `--once`. Somente um processo pode
usar `local/cloudflare-production/`. Mudanças do código do modelo exigem outro
`--runtime`. Falhas do cálculo ou do upload preservam o último resultado remoto e geram
nova tentativa no próximo ciclo. Ctrl+C encerra o publicador, mantendo o resultado no KV.

O comando não inicia o coletor nem agenda seu acionamento para domingo. A operação exige
iniciar e acompanhar coletor, executor e envio. O primeiro envio remoto e a igualdade com o JSON público foram verificados em 22/10.
Os testes de falha/retomada são locais; falhas reais da rede de produção não foram provocadas.

## Verificações de 22/10

- 51 testes JavaScript e 69 Python passaram, sem skips.
- Replay sintético: 107 verificações em 24 etapas, em 50,705 s. Os dois cenários são
  preservados, coincidem na prior e reproduzem o observado com 100% das urnas. Isso
  verifica integração de software, não calibração eleitoral.
- Prior real: 499.248 seções e zero BUs, em `validacao/prior-20261022.json`.
- Troca de cenário conferida no navegador. Iframe de 320 pixels com viewport útil de
  308 pixels, sem excesso de largura do conteúdo.
- `wrangler deploy --dry-run --outdir local/workers-build` passou sem publicação.
- Runtime local oficial do Workers: página, JSON real dos dois cenários e cabeçalhos
  verificados por HTTP; POST recusado com 405. Registro em `validacao/workers-local-20261022.json`.

Fontes consultadas em 22/10/2026:
[Static Assets](https://developers.cloudflare.com/workers/static-assets/),
[Wrangler KV](https://developers.cloudflare.com/workers/wrangler/commands/kv/),
[propagação do KV](https://developers.cloudflare.com/kv/api/write-key-value-pairs/) e
[Web Analytics](https://developers.cloudflare.com/web-analytics/get-started/).

## Publicação verificada

Versão `1a1a10f2-2a30-4dc4-8e93-0fb0311e70eb`, com o token público de Web Analytics
configurado. Evidência do endpoint e da correspondência com o upload em
`validacao/publicacao-20261022.json`. Depois do teste com `--once`, o publicador contínuo foi iniciado no Mac, consultando o
export a cada 60 segundos. PID observado em 22/10: `2022`; estado local em
`local/cloudflare/publisher-status.json`. Esse processo não inicia outro coletor.
É necessário manter o Mac ligado e conectado e preservar a execução desse processo.
Esse início manual foi substituído em 24/10 pelos LaunchAgents descritos em
[SERVICOS.md](SERVICOS.md). Eles retomam os componentes na sessão do usuário, inclusive
após novo login, com logs próprios e sem duplicar as instâncias.
