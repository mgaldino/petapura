# Operação do site

## Desenvolvimento

```sh
python3 scripts/serve.py --port 4173
```

O endereço principal consulta `web/data/latest.json`. A demonstração usa uma entrada separada e explicitamente identificada. O servidor local declara UTF-8 para HTML, JavaScript, CSS e JSON; serve somente a aplicação em `web/`.

Para reproduzir as amostras e empacotar:

```sh
python3 scripts/generate_demo.py
python3 scripts/build.py
```

`generate_demo.py` reconstitui os dados fictícios do mockup e devolve `web/data/latest.json` ao estado de espera. Use esse comando somente em desenvolvimento. `build.py` substitui apenas a pasta gerada `dist/` pela versão de `web/`.

## Atualização de dados

O produtor do modelo escreve o snapshot completo; um único processo executa o publicador após cada resultado calculado. Não inicie um segundo coletor do TSE para servir o site.

```sh
python3 scripts/publish_snapshot.py \
  --input /caminho/saida/snapshot-site.json \
  --output /caminho/site-servido/data/latest.json
```

O arquivo de saída e seu histórico são atualizados atomicamente. O lock é liberado ao encerrar o processo. Uma falha não apaga o último JSON válido. Backups e retenção de snapshots completos podem ficar sob a operação do modelo; este site mantém até 4.000 pontos no JSON corrente.

## Publicação

`dist/` é um site estático, sem dependência do aplicativo Codex ou de chamadas `window.openai`. Pode ser servido por hospedagem estática. O endpoint dos dados pode ficar no mesmo domínio ou em um serviço separado, conforme o [contrato](INTEGRACAO.md).

Em produção, mantenha o JSON corrente fora do diretório substituído pelo build, ou use um endpoint de dados separado. `build.py` gera uma nova cópia de `web/`; não é uma rotina de preservação de dados de operação.

Para atualizações durante a apuração, o endpoint precisa servir o JSON que o executor publica. Fazer um novo deploy da página a cada boletim não é necessário quando os dados são servidos por um endpoint separado.

Ainda devem ser definidos o domínio/hospedagem e a URL definitiva do modelo. Esta entrega não publica conteúdo nem cria um serviço remoto. O servidor `serve.py` serve para desenvolvimento local; a hospedagem final deve oferecer HTTPS e os cabeçalhos de cache descritos no contrato.

## Verificação antes da operação

1. Conferir os IDs da eleição e das candidaturas em `web/config.json`.
2. Executar os testes do repositório e um replay do fluxo completo com o modelo definitivo.
3. Conferir o nível e a origem dos intervalos, a presença/ausência da probabilidade e as notas metodológicas fornecidas pelo modelo.
4. Testar o endpoint e sua atualização no domínio final, inclusive falha e retomada.
5. Confirmar que a URL pública usa dados reais e que a demonstração continua identificada e separada.

São verificações do caminho integrado. Os testes sintéticos do site não validam empiricamente a cobertura dos intervalos eleitorais.
