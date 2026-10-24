# Supervisão automática no macOS

Na máquina de produção, o coletor e o publicador dos dois cenários são supervisionados
pelo `launchd`, com dois LaunchDaemons instalados no domínio `system`:

- `/Library/LaunchDaemons/br.usp.petapura.collector.plist`
- `/Library/LaunchDaemons/br.usp.petapura.publisher.plist`

Eles iniciam na partida do macOS, antes do login, e executam como a conta comum do
operador, conforme `UserName` e `GroupName` nos plists. A configuração foi instalada
e verificada em 24/10/2026. Os LaunchAgents anteriores foram retirados. O Mac precisa
estar ligado, conectado e acordado durante a coleta.

## Execução antes do login: modo sistema

O gerenciador também prepara LaunchDaemons em `/Library/LaunchDaemons/`, carregados
no domínio `system` desde a inicialização do macOS. A instalação requer administrador.
O coletor e o publicador executam com `UserName` e `GroupName` da conta comum do
operador. A conta de administrador é usada somente para instalar os plists, não para
executar a coleta ou o modelo como root.

```sh
python3 scripts/manage_services.py prepare --scope system --user NOME_DA_CONTA
sudo /caminho/python3 scripts/manage_services.py install --scope system --user NOME_DA_CONTA
python3 scripts/manage_services.py status --scope system
```

O instalador valida a configuração antes de retirar os LaunchAgents. Ele preserva
cópias dos plists anteriores, transfere os serviços para `system`, confere os processos
filhos com o UID da conta e restaura os serviços anteriores se essa etapa falhar.
Os plists de sistema ficam com dono `root:wheel` e modo 0644. A configuração local
continua com o operador como dono e modo 0600. O ambiente aponta para o diretório
residencial real da conta, para reutilizar a autenticação do Wrangler.

Depois da migração, `local/services/settings.json` registra `service_scope: system`
e `service_user`. Os comandos passam a selecionar esse modo por padrão. Instalar,
recarregar ou parar serviços de sistema exige `sudo`. Os arquivos de LaunchAgent são
retirados com backup para não criar cópias concorrentes no próximo login.

Com FileVault ativado, a partida ainda depende do desbloqueio do volume. O instalador
não altera FileVault, início automático de sessão ou proteções do sistema. A inspeção
do domínio `system` e o teste dos processos não substituem uma reinicialização física
sem login para testar toda a sequência de partida e disponibilidade de rede.

A preparação do modo sistema pode ser feita sem administrador e preserva os serviços
em execução. A instalação efetiva só ocorre depois da autenticação no Terminal.

## Política de retomada

`RunAtLoad` inicia os serviços na partida, no modo sistema, ou no login, no modo usuário.
Cada supervisor executa o comando configurado
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
sudo /caminho/python3 scripts/manage_services.py install --scope system --user NOME_DA_CONTA
python3 scripts/manage_services.py status
```

`prepare` gera e valida os plists em `local/services/launchdaemons/` no modo sistema,
ou `launchagents/` no modo usuário, sem instalá-los.
`install` instala os arquivos e carrega os dois serviços no domínio selecionado.
Uma nova execução do comando recarrega serviços do próprio projeto e preserva uma
cópia do plist anterior quando seu conteúdo muda. `status` consulta o estado real no
`launchd`.

Para retirar temporariamente os serviços do domínio de sistema:

```sh
sudo /caminho/python3 scripts/manage_services.py stop --scope system
```

Os plists permanecem instalados, portanto a próxima partida do Mac volta a iniciá-los.
`install` também os retoma imediatamente. Alterar a janela do coletor requer recarregar
os supervisores para que leiam os novos limites.

## Logs e evidência

`local/services/collector-status.json` e `publisher-status.json` registram o PID do
supervisor, o PID atual do filho, a janela e o estado. Os logs são `collector.out.log`,
`collector.err.log`, `publisher.out.log` e `publisher.err.log`, nessa mesma pasta. Os
recibos de início configurados são atualizados a cada nova geração de processo.

A instalação de sistema e o teste real de interrupção dos dois supervisores estão em
[`validacao/launchdaemons-20261024.json`](validacao/launchdaemons-20261024.json).
Foram conferidos o domínio `system`, os donos e as permissões dos plists, a execução
com o UID do operador, a ausência de LaunchAgents concorrentes e a publicação dos
dois cenários. O teste reiniciou processos sob o `launchd`, sem reiniciar fisicamente
o Mac ou encerrar a sessão gráfica. A partida antes do login está configurada e foi
inspecionada, mas não foi testada com uma reinicialização física sem login.

O registro [`validacao/servicos-20261024.json`](validacao/servicos-20261024.json)
documenta a instalação inicial por LaunchAgents, substituída pelo modo sistema.

Referências da Apple consultadas em 24/10/2026:
[daemons e agentes](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html),
[gerenciamento de scripts](https://support.apple.com/guide/terminal/apdc6c1077b-5d5d-4d35-9c19-60f2397b2369/mac) e
[referência do plist](https://github.com/apple-oss-distributions/launchd/blob/main/man/launchd.plist.5).
