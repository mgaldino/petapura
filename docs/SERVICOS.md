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

Os supervisores usam a mesma configuração operacional passada ao coletor por
`--config` para reconhecer a janela. Ela está em
[`../deployment/collector-2026.json`](../deployment/collector-2026.json) e começa em
**25/10 às 00h**, terminando em **26/10 às 8h**, Brasília. O início foi antecipado de
17h para 00h em 24/10 para consultar eventuais boletins do exterior publicados mais
cedo. O coletor aguarda o início como antes. O publicador pode conferir o export
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

O campo `collector_config` aponta para a configuração operacional, e o comando do
coletor recebe esse mesmo caminho em `--config`. Os filtros, a lista de UFs com `ZZ`,
os limites de consultas e o fim da janela foram preservados. O `config.json` do
release em `modelo/` e as fontes congeladas no runtime mantêm os hashes originais.

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

## Teste com reinicialização física

O supervisor grava, a cada início, uma evidência privada em
`local/services/startups/ID_DA_PARTIDA/`. O registro inclui a identificação da partida
do macOS, horário de início, PID do supervisor e do filho, usuário da sessão gráfica
e dono de `/dev/console`. O registro permanece após atualizações do status e depois
do login. Uma falha na leitura dessas informações é registrada como indisponibilidade,
sem presumir que não havia login.

Antes de reiniciar, registre a partida atual:

```sh
python3 scripts/startup_evidence.py prepare
```

Salve o trabalho aberto e reinicie pelo menu Apple. Mantenha o Mac ligado à energia,
com a tampa aberta e a rede disponível. Ao aparecer a tela de login, aguarde **três
minutos sem entrar na conta**. Depois entre normalmente e execute:

```sh
python3 scripts/startup_evidence.py verify
```

O verificador exige uma identificação de partida diferente da referência, registros
dos dois serviços com `loginwindow` e UID zero na sessão gráfica, jobs ativos em
`system` e os mesmos supervisores e filhos ainda em execução, com status recente.
O resultado fica em `local/services/boot-test-result.json`. Saída zero confirma os
dois serviços. Saída 2 indica que o teste não comprovou o início antes do login,
inclusive quando falta evidência ou ocorreu outro reinício de processo após o login.
Nesses casos, confira o resultado e os logs antes de repetir o teste.

Esse teste confirma o início dos processos. A publicação na Cloudflare e a leitura
dos dados do TSE também precisam ser conferidas após a partida, pois dependem de rede
e da disponibilidade dos serviços externos.

Referências da Apple consultadas em 24/10/2026:
[daemons e agentes](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html),
[gerenciamento de scripts](https://support.apple.com/guide/terminal/apdc6c1077b-5d5d-4d35-9c19-60f2397b2369/mac) e
[referência do plist](https://github.com/apple-oss-distributions/launchd/blob/main/man/launchd.plist.5).
