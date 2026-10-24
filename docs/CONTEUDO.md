# Conteúdo institucional e explicação do modelo

Preparado em 23/10/2026. A pedido do tutor, os conteúdos foram movidos integralmente para páginas próprias, acessíveis pelo menu comum:

- `/quem-somos/`: `web/quem-somos/index.html`.
- `/sobre-o-modelo/`: `web/sobre-o-modelo/index.html`.
- `/`: apuração e leitura da incerteza em `web/index.html`.

As páginas de conteúdo carregam o mesmo Web Analytics por `web/assets/page.js`. A navegação marca a página atual com `aria-current="page"`. Os dois links institucionais retirados a pedido do tutor continuam ausentes. O registro da mudança de navegação está em `docs/validacao/paginas-20261023.json`.

## Renderização das fórmulas em 24/10/2026

As equações, as priors e os símbolos no texto de `/sobre-o-modelo/` foram convertidos
para LaTeX e renderizados com MathJax 4.1.3, carregado pelo jsDelivr somente nessa página.
O script de configuração é `web/assets/mathjax-config.js`. Ele espera a abertura de
cada bloco para compor a matemática na largura disponível e refaz a composição ao
redimensionar. A notação de meia-normal passou a ser explícita como normal positiva,
com definição no texto. Os parâmetros e as hipóteses publicados foram preservados.

A conferência visual cobriu todos os três blocos em desktop e em uma janela de 320px,
além de ampliação, redução e reabertura dos blocos. Não houve erro TeX ou excesso de
largura nas fórmulas renderizadas. Se o CDN estiver indisponível, o LaTeX original
permanece no conteúdo. Evidência em `validacao/mathjax-20261024.json`.

Referências técnicas consultadas em 24/10/2026:
[configuração](https://docs.mathjax.org/en/latest/web/configuration.html),
[composição assíncrona](https://docs.mathjax.org/en/latest/web/typeset.html),
[quebra de linhas](https://docs.mathjax.org/en/latest/output/linebreaks.html) e
[versão 4.1.3](https://github.com/mathjax/MathJax/releases/tag/4.1.3).

## Fontes institucionais

- [Programa de Educação Tutorial na USP](https://prg.usp.br/programa-de-educacao-tutorial-pet/), consultado em 23/10/2026: vínculo com o MEC, ensino, pesquisa e extensão.
- [Serviço federal de ingresso no PET](https://www.gov.br/pt-br/servicos/cadastrar-se-como-discente-de-grupo-de-tutoria-do-pet), consultado em 23/10/2026: grupos de graduação orientados por professor tutor.
- [Página de Manoel Galdino](https://mgaldino.github.io/), consultada em 23/10/2026: Departamento de Ciência Política da USP e tutoria do PET de Ciências Sociais. A grafia do nome foi conferida nessa fonte e nos documentos locais de tutoria de 2025.
- [PET de Ciências Sociais no DCP](https://dcp.fflch.usp.br/graduacao/pet-ciencias-sociais), consultado em 23/10/2026: vínculo institucional. A ficha específica da PRG ainda menciona tutor antigo, portanto não foi usada para identificar a tutoria atual.

A página “Quem somos” apresenta o tutor e 12 estudantes em ordem alfabética. Os
documentos administrativos usados na conferência dos nomes permanecem apenas no
arquivo local do projeto.

## Correspondência com o modelo em produção

A revisão usou a cópia congelada em `local/cloudflare-production/runs/e93d394069e84d86b835473645592ee0/model-source/`, com manifesto SHA-256 próprio. Não houve alteração de fontes, parâmetros ou checkpoints do modelo.

| Conteúdo publicado | Fonte conferida |
|---|---|
| Resposta suavizada em logit, votos nas demais candidaturas e logit dos válidos | `bayes.R`, funções `safe_logit()` e `features()` |
| Quatro preditores, centralização por UF/nacional, escalas históricas fixas e priors nacionais | `comparecimento_preditor.R`, funções `spec_comparecimento()`, `X_comparecimento()` e `fit_comparecimento()` |
| Intercepto e inclinação do voto por UF, normal multivariada, meia-normal e LKJ(2) | `comparecimento_preditor.stan`, estrutura `voto_t1` |
| Aproximação normal conjunta e Q somada uma vez | `online_conjugado.R`, funções `prior_online()` e `covariancia_mudanca_online()` |
| Sete desvios padrão de Q | `escalas_online_v2.json`, perfil central |
| Componentes municipais, razão de válidos e atualização gradual | `componentes_locais.R` e `componentes_locais_v2.json` |
| Uso dos votos observados nos dois cenários, 400 sorteios, quantis e âncora oficial | `previsao_execucao.R`, `integracao/executar_pipeline.R` e checkpoint publicado |

O checkpoint em produção confirma 400 sorteios, fração plena 0,15, expoente 2, variância municipal 0,00291313 e variância residual total aproximada de 0,02219225. O ajuste histórico lido no projeto de origem confirma 472.024 seções, estrutura `voto_t1` e coeficientes variáveis 1 e 2 (intercepto e voto T1), com a mesma variância residual.

O texto apresenta os cenários como hipóteses sobre as seções pendentes. Não promete superioridade geral do aprendizado nem cobertura empírica de 95%. A frase anteriormente retirada sobre combinar os resultados em uma média permanece ausente.

## Verificação desta mudança

- Build de produção com snapshot real, dois cenários e analytics obrigatório.
- IDs sem duplicatas, atalhos internos com destino e três blocos técnicos expansíveis, além do bloco de incerteza preexistente.
- Inspeção visual em largura de desktop e de 320 pixels. Todos os blocos técnicos abertos sem transbordamento horizontal na largura de 320 pixels.
- Conteúdo e diff conferidos. Nenhum cálculo ou configuração de analytics foi modificado.

O registro de publicação e de verificação HTTP fica em `docs/validacao/conteudo-20261023.json`.
