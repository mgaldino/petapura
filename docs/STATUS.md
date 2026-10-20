# Estado da entrega

Atualizado em 20/10/2026.

## Implementado neste repositório

- Aplicação responsiva baseada no Observatório aprovado, sem dependência do Codex, frameworks ou bibliotecas de frontend.
- Resumo numérico de A, gráfico A vermelho/B azul, limiar de 50%, incerteza explícita, parcial após o gráfico e crédito ao PET de Ciências Sociais da USP.
- Endpoint JSON configurável e consultas periódicas, com timeout, uma requisição por vez, aviso de falha/desatualização e preservação do último resultado válido.
- Estados de espera, previsão inicial com zero BUs, contagem sem previsão, previsão com probabilidade ausente e apuração concluída.
- Contrato público versionado, validadores Python/JavaScript, proteção de identidade da eleição e de candidaturas e rejeição de campos internos fora do contrato.
- Publicação atômica, lock para um único escritor, histórico, idempotência e tratamento de correções.
- Leitor do export existente do coletor e funções R para exportar a previsão e montar um snapshot com os objetos já lidos pelo executor.
- Demonstração separada e identificada. Nenhum dado sintético preenche silenciosamente o endpoint real.
- Mockup aprovado e pesquisa de benchmark arquivados, com seus fontes e referências.

## Executado e verificado

| Verificação | Resultado |
|---|---|
| Testes JavaScript | 35 passaram: contrato, identidade, intervalos/probabilidade, consultas, timeout, falhas, regressão temporal e rótulos em empate |
| Testes Python | 19 passaram: publicação, lock, atomicidade, preservação do último válido, correções e importação do coletor |
| Interoperabilidade R | JSON exportado com 95%, probabilidade nula e zero BUs aceito pelos validadores Python e JavaScript |
| Importação do export real local | Leitura consistente de totalização nacional escolhida, com zero boletins; sem produzir previsão e sem alterar o coletor |
| Inspeção no navegador | Aplicação com a demonstração, espera sem dados, intervalo de 95%, probabilidade ausente, previsão com zero BUs e fim da apuração |
| Layout compacto | Largura de 320 pixels sem rolagem horizontal; rodapé e rótulo Agora legíveis |
| Empacotamento | `dist/` gerado a partir de `web/` |

Os resultados automatizados estão em [testes.json](validacao/testes.json). A importação está registrada em [importacao-coletor.json](validacao/importacao-coletor.json). O esquema JSON é acompanhado de validadores com verificações relacionais; não há dependência de um pacote externo de JSON Schema na aplicação.

## Falta para operar com a previsão real

1. O executor desenvolvido na outra sessão deve produzir a previsão adaptativa final: percentual, quantis, nível, versão, snapshot usado e probabilidade quando disponível. As funções de saída deste repositório estão prontas para receber esses valores.
2. Ligar essa saída ao publicador em um ciclo operacional único e executar um replay integrado com o executor definitivo. O leitor do export observado já foi verificado; a previsão adaptativa completa ainda não foi recebida por este site.
3. Definir hospedagem/domínio e a URL pública dos dados, ajustar os cabeçalhos de cache/CORS quando necessários e publicar a aplicação.

Esses itens não exigem refazer o desenho nem o código de apresentação. São a conexão à saída definitiva, a verificação conjunta e a publicação. Nenhum serviço remoto foi criado ou publicado nesta entrega.

## Limites da verificação

Os testes estatísticos e a calibração dos intervalos pertencem ao modelo. As fixtures e os exemplos deste site são sintéticos e não demonstram cobertura preditiva eleitoral. A importação real verificou a leitura do export local disponível em 20/10; não é um teste com votos futuros do segundo turno. A inspeção de largura compacta foi em navegador, sem auditoria completa de acessibilidade ou teste em todos os aparelhos.
