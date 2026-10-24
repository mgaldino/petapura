# Laboratório: comparecimento T1 como preditor da votação T2 por seção.
# Execute por blocos. Os ajustes MCMC já estão preparados.
library(data.table)
library(here)
here::i_am("projeto_agna/previsao_tempo_real/laboratorio.R")
root <- here::here("projeto_agna", "previsao_tempo_real")
source(file.path(root,"bayes.R"),encoding="UTF-8")
source(file.path(root,"voto_t1.R"),encoding="UTF-8")
fits <- readRDS(file.path(root,"data","processed","voto_t1_fits.rds"))
out <- file.path(root,"output","comparecimento_preditor_20261020")

# 1. Unidade e denominadores (10 min).
base <- fread(file.path(root,"data","processed","voto_t1_baseline_2026.csv"))
base[,.(uf,cd_mun,zona,secao,aptos,x_lula,x_outros,taxa_comp_t1,p_base,validos_base)] |> head()
# Comparecimento T1 = presentes T1 / aptos T1. Já é conhecido em 2026.
# Resposta = Lula T2 / válidos T2. Aptos não são o denominador da resposta.
# Peso das seções pendentes = número de válidos T1, fixo até receber o BU.

# 2. Qual inclinação deve variar? (20 min).
fread(file.path(out,"comparacao.csv"))
fread(file.path(out,"comparacao_mqo.csv"))
fread(file.path(out,"diagnosticos_finais.csv"))
# Compare as quatro estruturas nos mesmos municípios reservados.
# As duas versões com uma inclinação variável têm o mesmo número de parâmetros.
# Por que o intercepto variável não representa uma diferença de inclinação?
# O log score favorece ambas; o ganho de RMSE é 0,00143 p.p. A escolha operacional
# por parcimônia mantém a inclinação de voto T1 variável e comparecimento comum.

# 3. Sinal do comparecimento e heterogeneidade (15 min).
effects <- fread(file.path(out,"associacao_final_por_uf.csv"))
effects[estrutura=="voto_t1"][1] # O coeficiente comum se repete em cada UF.
effects[estrutura=="ambos"]     # Versão exploratória com inclinação de comparecimento por UF.
# As unidades são +1 ponto percentual de comparecimento, não uma unidade 0-1.
# Mudança na votação é calculada na referência p=50%, mantendo controles fixos.
# Por que estes coeficientes não identificam o efeito causal de aumentar comparecimento?
# Não há comparecimento T2 nem variação de comparecimento entre turnos no modelo.

# 4. Apuração simulada e pesos (15 min).
fread(file.path(out,"ensaio_sequencial_2022.csv"))
fread(file.path(out,"diagnostico_pesos_2022.csv"))
# As ordens de chegada são simuladas. Os pesos T1 são uma aproximação dos
# válidos T2 desconhecidos; não há uma regressão para prever comparecimento.
# A operação substitui previsão e peso pelo BU efetivo, sem recalibrar
# coeficientes com as primeiras seções seletivamente apuradas.

# 5. Fonte nacional congelada e âncora oficial (15 min).
current <- file.path(root,"data","live","bayes_output","previsao_atual.csv")
if(file.exists(current)) print(fread(current))
# Compare seções totalizadas pelo TSE e BUs baixados. Nacional e estados
# são fontes alternativas. A âncora oficial aproxima a composição das seções
# ainda não baixadas dentro de UF. Compare com pct_a_somente_bu.
# Entrega: 8-10 linhas sobre estrutura, comparecimento, pesos, incerteza e fontes.
