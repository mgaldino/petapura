# Revisão independente da integração local

Revisor: subagente model_api, em 20/10/2026. Implementador: agente principal.

A revisão final não encontrou novo defeito material nos arquivos com os hashes abaixo. Os 22 testes independentes passaram, incluindo controles HTTP, concorrência, retomada, bloqueio de caminhos e preservação da execução anterior quando o reinício falha. O replay R e o ciclo com o export real foram executados pelo implementador e não são atribuídos ao revisor.

| Finding anterior | Classificação ao verificar | Evidência e resolução |
|---|---|---|
| current.json atrasado e falha após export podiam republicar etapa | CONFIRMED | prepare recupera status.stage com SHA; work reutiliza export da próxima etapa; testes de retomada/retry e replay estágio 8 passaram |
| modo TSE podia publicar fixture como live | CONFIRMED | R recusa manifesto marcado PET SYNTHETIC REPLAY no modo real; replay executou a recusa |
| lock era criado antes de validar destino proibido | CONFIRMED | Pipeline é construído/validado antes de runtime_lock; teste confere ausência de escrita |
| nota dizia que âncora fora aplicada mesmo quando false | CONFIRMED | nota agora depende de resumo$ancora_oficial; mapeamento revisado contra ancorar.R |
| sorteios pré-âncora não permitem probabilidade coerente com quantis ancorados | CONFIRMED | probabilidade permanece null; quantis q025/q975 de resumo são preservados a 95% |

Essas observações chegaram durante a implementação e foram conferidas no código antes da correção. O registro formal abaixo identifica a versão final revisada, posterior às correções; não atribui retroativamente esse hash aos arquivos anteriores.

Não há decisão substantiva pendente do usuário nem alteração da especificação do modelo.

- `scripts/run_local.py`: `1703e188214cc2ada06182701c7ad6f572e252fae582b9f04d6fea37acc83aea`
- `integracao/executar_pipeline.R`: `f9990f837f45557f44513be000c08f467029b6ed63f71ba4bd300b5eb52b8412`
