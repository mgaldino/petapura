# Supervisão automática no macOS

O coletor e o publicador dos dois cenários são supervisionados pelo `launchd`, com dois
LaunchAgents instalados na conta do operador:

- `~/Library/LaunchAgents/br.usp.petapura.collector.plist`
- `~/Library/LaunchAgents/br.usp.petapura.publisher.plist`

Eles iniciam ao entrar na conta do macOS, inclusive depois de reiniciar o Mac. Não é
necessário abrir o Codex, ChatGPT ou um terminal. Essa configuração usa a sessão do
usuário e não inicia os processos antes do login. O Mac precisa estar ligado,
conectado e acordado durante a coleta.

## Política de retomada

`RunAtLoad` inicia os serviços no login. Cada supervisor executa o comando configurado
e retorna uma falha ao `launchd` se o filho encerrar antes do fim da janela eleitoral,
mesmo que o filho retorne zero. `KeepAlive.SuccessfulExit = false` provoca a retomada,
com `ThrottleInterval = 20` para limitar as tentativas repetidas. Os locks próprios do
coletor e do pipeline e um lock por supervisor impedem instâncias concorrentes.

O encerramento abrupto do supervisor também provoca a retomada. O `launchd` limpa os
demais processos de seu grupo (`AbandonProcessGroup = false`), evitando deixar uma
cópia antiga do coletor, de R ou do publicador ocupando o lock.

Os supervisores usam o mesmo `config.json` do coletor para reconhecer o fim da janela.
Na configuração de 2026, ela começa em **25/10 às 17h** e termina em **26/10 às 8h**,
Brasília. O coletor aguarda o início como antes. O publicador pode conferir o export
antes do início. No término, ambos são encerrados de forma controlada e retornam
sucesso, sem um ciclo infinito de reinicialização depois da eleição. Em sinais de
parada, o supervisor tenta primeiro `SIGINT` para permitir a limpeza prevista no
pipeline, preservando o último checkpoint completo.

O coletor mantém sua regra de `caffeinate` dentro da janela. Não foram alteradas as
configurações globais de energia, de login ou de autenticação. A supervisão retoma
processos encerrados, sem funcionar como detector de congelamento de um processo
que continue vivo.

## Configuração e comandos

Os caminhos reais ficam em `local/services/settings.json`, fora do Git. O exemplo
[`../deployment/services.example.json`](../deployment/services.example.json) documenta
o formato, com caminhos que precisam ser ajustados à máquina. O ambiente inclui o
Node necessário ao Wrangler. As credenciais continuam no perfil já autenticado do
operador, fora do arquivo de configuração e dos plists.

Antes da primeira instalação, encerre as instâncias iniciadas manualmente, depois de
conferir sua identidade e aguardar a liberação dos locks. Os serviços já configurados
devem ser operados por estes comandos, em vez de iniciar novas cópias diretamente:

```sh
python3 scripts/manage_services.py prepare
python3 scripts/manage_services.py install
python3 scripts/manage_services.py status
```

`prepare` gera e valida os plists em `local/services/launchagents/`, sem instalá-los.
`install` instala os arquivos no perfil e carrega os dois serviços na sessão atual.
Uma nova execução do comando recarrega serviços do próprio projeto e preserva uma
cópia do plist anterior quando seu conteúdo muda. `status` consulta o estado real no
`launchd`.

Para retirar os serviços somente da sessão atual:

```sh
python3 scripts/manage_services.py stop
```

Os plists permanecem instalados, portanto o próximo login volta a iniciá-los.
`install` também os retoma imediatamente. Alterar a janela do coletor requer recarregar
os supervisores para que leiam os novos limites.

## Logs e evidência

`local/services/collector-status.json` e `publisher-status.json` registram o PID do
supervisor, o PID atual do filho, a janela e o estado. Os logs são `collector.out.log`,
`collector.err.log`, `publisher.out.log` e `publisher.err.log`, nessa mesma pasta. Os
recibos de início configurados são atualizados a cada nova geração de processo.

A conferência de instalação e os testes reais de interrupção estão em
[`validacao/servicos-20261024.json`](validacao/servicos-20261024.json). O teste reiniciou
processos sob o `launchd`, sem reiniciar fisicamente o Mac. A retomada após reiniciar
o computador está configurada e foi inspecionada nos plists, mas não foi testada com
uma reinicialização física.

Referências da Apple consultadas em 24/10/2026:
[daemons e agentes](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html),
[gerenciamento de scripts](https://support.apple.com/guide/terminal/apdc6c1077b-5d5d-4d35-9c19-60f2397b2369/mac) e
[referência do plist](https://github.com/apple-oss-distributions/launchd/blob/main/man/launchd.plist.5).
