# Executar o fluxo local

O acompanhamento experimental com **comparecimento variando por UF** está em
[COMPARECIMENTO_UF_LOCAL.md](COMPARECIMENTO_UF_LOCAL.md). Ele usa uma execução própria
e o mesmo export do coletor, sem publicar seus resultados no site.

## Simulação integrada

Na raiz do repositório:

```sh
python3 scripts/run_local.py
```

Abra <http://127.0.0.1:4173/>. A inicialização prepara uma população fictícia de 2.800 seções e uma previsão com zero boletins. A simulação avança automaticamente até 100%, com oito segundos entre os cálculos. A página mostra as atualizações sem botões de reprodução, avanço, reinício ou seleção de intervalo.

O fluxo é: BUs fictícios → publicador original do coletor → export com manifesto e SHA256 → leitor R original → posterior adaptativa dos 59 coeficientes → previsão e checkpoint → adaptador público → validador/publicador Python → navegador. A média e os quantis são calculados pelo modelo a cada lote. A página lê a nova saída automaticamente. O gráfico mantém o histórico das contagens recebidas.

O T1, os BUs e a ordem de chegada da demonstração são fictícios. O ajuste histórico, a prior V2 e as rotinas de atualização são os do modelo existente. As fontes e suas configurações ficam preservadas em `model-source/` dentro de cada execução, com SHA256. Alterações feitas no módulo original pela outra sessão passam a valer em uma execução nova; não mudam a API de um checkpoint já criado. A faixa continua sendo de 95%, com os limites produzidos pelo executor. A probabilidade de vitória fica ausente: essa saída ainda não é exportada pelo adaptador. O nível de incerteza visto na simulação não demonstra cobertura eleitoral real.

Execuções anteriores que não têm fontes preservadas são mantidas e substituídas por uma nova execução compatível, sem reaproveitar checkpoints de outra API.

Os arquivos ficam em `local/demo/runs/<id>/`, ignorados pelo Git. Cada execução conserva a fixture, seus hashes e semente, o estado inicial isolado, o export do coletor, os últimos três checkpoints, o JSON público e `pipeline.log`. `local/demo/current.json` identifica a execução atual. Encerrar e executar novamente o mesmo comando retoma o último estado e continua automaticamente, ou mantém o resultado final quando a apuração já terminou.

O módulo do modelo é localizado na estrutura de pastas atual. Para indicar outro caminho:

```sh
python3 scripts/run_local.py --model-dir /caminho/previsao_tempo_real
```

Também aceita `PET_MODEL_DIR`. Requer Python 3.10+, R e `data.table`, `arrow`, `jsonlite`, `digest`, já usados pelo modelo; o pacote inicial real e o ajuste histórico devem estar presentes. Não executa MCMC nem instala pacotes. `--rscript` permite escolher o executável R.

Para outra semente, população ou número de sorteios, use uma pasta de execução nova:

```sh
python3 scripts/run_local.py --runtime local/outro-teste --seed 1234 --sections-per-uf 100 --draws 400
```

Ctrl+C no terminal encerra o servidor e o executor local. Se este foi iniciado em segundo plano por outra ferramenta, use `kill -INT PID` com o PID informado na entrega. Para testar outra porta, acrescente `--port 4175`.

## Dados do coletor TSE existente

```sh
python3 scripts/run_local.py --mode tse
```

Esse modo lê `data/live/tse_export` e o estado inicial real da pasta do modelo, atualiza a previsão a cada 60 segundos e serve o resultado localmente. Não inicia nem altera a vigia. O coletor já existente é responsável pelo acesso ao TSE. Checkpoints e saídas desta integração ficam em `local/tse/`, separados das saídas da outra sessão.

Podem ser informados `--source /caminho/tse_export`, `--initial-state /caminho/estado_inicial_v2`, `--interval 60`, `--name-a "Nome de A"` e `--name-b "Nome de B"`. A origem e o checkpoint precisam ter a mesma eleição, candidaturas e inventário. Um snapshot identificado como fictício é recusado nesse modo. Não configure `--runtime` dentro do módulo do modelo ou de `web/`.

Para processar uma única vez, sem abrir servidor:

```sh
python3 scripts/run_local.py --mode tse --once
```

O JSON público fica em `local/tse/runs/<id>/public/latest.json`. Em falhas, o servidor preserva a última saída válida. Repetir o mesmo snapshot reutiliza o checkpoint; se a publicação foi interrompida, o adaptador pode completá-la sem refazer a posterior. Novos BUs, revisões e remoções seguem a recomposição desde a prior original implementada no modelo.

## Verificação reproduzível

```sh
node --test tests/data.test.js
PET_MODEL_DIR=/caminho/previsao_tempo_real python3 -m unittest discover -s tests -p 'test_*.py'
python3 tests/replay_pipeline.py --model-dir /caminho/previsao_tempo_real
python3 tests/check_automatic.py --model-dir /caminho/previsao_tempo_real
```

O replay R verifica 24 etapas de zero a 100%, BR/SOMA_UFS, média e quantis preservados, repetição, retomada, recusa de dados fictícios no modo real e igualdade dos totais finais. Registra entradas, hashes, tempos e resultados em `local/validacao-<id>/verification.json`. O teste `check_automatic.py` inicia o servidor e o worker reais, acompanha os 24 lotes por HTTP sem enviar ações, confere o fim e encerra o processo. `--legacy-runtime` permite partir de uma cópia de uma execução antiga. Os testes HTTP abrem apenas portas temporárias em localhost.

Hospedagem e publicação externa continuam separadas deste comando local.

Para iniciar uma execução com uma cópia de fontes que já passou no teste automático, o operador pode usar `--model-code /caminho/model-source`. Os dados e ajustes históricos continuam vindo de `--model-dir`. Isso permite servir exatamente a versão validada mesmo enquanto o módulo original evolui em outra sessão.
