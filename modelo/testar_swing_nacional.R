# O modelo capta um swing nacional sem inventar swing quando não há? Verdades SINTÉTICAS
# sobre a população real de 2026, chegada na ordem em que os BUs do 1º turno de 2026
# ficaram disponíveis no TSE (cs_da/cs_ha da coleta do electoralFraud) e na ordem inversa.
# Modelo atual: escala V2, componentes locais v2, atualização gradual até 15%; sem âncora.
args_all <- commandArgs(FALSE)
root <- dirname(normalizePath(sub("^--file=","",args_all[grepl("^--file=",args_all)])[1]))
source(file.path(root,"previsao_execucao.R"),encoding="UTF-8")
source(file.path(root,"teste_integrado_comum.R"),encoding="UTF-8")
out <- file.path(root,"output","swing_nacional_20261021")
dir.create(out,recursive=TRUE,showWarnings=FALSE)
local <- ler_componentes_locais()
# PESO_MAXIMO < 1 limita o peso do modelo atualizado depois de 15% dos válidos T1: (1 - PESO_MAXIMO) fica com
# o modelo inicial ("média dos dois modelos"). Só para teste; o executor usa componentes_locais.
peso_maximo <- as.numeric(Sys.getenv("PESO_MAXIMO","1"))
exigir_analise(is.finite(peso_maximo)&&peso_maximo>0&&peso_maximo<=1,"PESO_MAXIMO fora de (0, 1]")
if(peso_maximo<1){peso_gradual <- peso_atualizacao;peso_atualizacao <- function(fracao,local)peso_maximo*peso_gradual(fracao,local)}
sufixo <- if(peso_maximo<1)sprintf("_peso%03d",round(100*peso_maximo)) else ""
state <- carregar_ponto_partida_analise(file.path(root,"data","processed","estado_inicial_v2"))
prior <- state$prior;pop <- state$population
comp <- componentes_2022_teste(root)
nordeste <- c("AL","BA","CE","MA","PB","PE","PI","RN","SE")

# Base fixa da verdade: relação de 2022 (média da prior), choques municipais e razão de
# válidos do cenário realista. O swing desloca o logit das UFs escolhidas.
X <- .analise_componentes$X_comparecimento(pop,prior$spec);group <- match(pop$uf,prior$levels)
mu <- preditor_linear_teste(prior,X,group,prior$mean)
mun <- pop[,.(uf,cd_mun)][,id:=.GRP,by=.(uf,cd_mun)]$id
set.seed(618380L)
tau2 <- comp$residuo[["entre"]]
noise <- rnorm(max(mun),0,sqrt(tau2))[mun]+rnorm(nrow(pop),0,sqrt(prior$sigma^2-tau2))
ratio <- exp(log(comp$rho_uf[pop,on="uf"]$rho)+rnorm(max(mun),0,sqrt(comp$razao[["entre"]]))[mun]+
  rnorm(nrow(pop),0,sqrt(comp$razao[["dentro"]])))
validos <- pmax(1,round(pop$validos_base*ratio))
verdade <- function(delta) {
  t <- pop[,..chaves_analise]
  t[,`:=`(validos=validos,votos_a=round(validos*plogis(mu+noise+delta)))]
  t[,`:=`(votos_b=validos-votos_a,brancos=round(.02*validos),nulos=round(.03*validos))]
  t[,comparecimento:=validos+brancos+nulos][,aptos:=pmax(round(pop$aptos),comparecimento)]
  t[]
}
pct <- function(t)100*sum(t$votos_a)/sum(t$validos)
base <- pct(verdade(0))
# Deslocamento do logit que produz o swing nacional desejado, em pontos.
calibrar <- function(alvo,ufs=prior$levels)uniroot(function(x)pct(verdade(x*(pop$uf%in%ufs)))-base-alvo,c(-1,1))$root
d2 <- calibrar(2);d4 <- calibrar(4)
cenarios <- list(sem_swing=verdade(0),swing_nacional_2=verdade(d2),swing_nacional_4=verdade(d4),
  swing_so_nordeste=verdade(d4*(pop$uf%in%nordeste)))

ch <- fread(file.path(root,"data","processed","chegada_t1_2026.csv.gz"))
ord <- ch[pop[,..chaves_analise],on=chaves_analise]
set.seed(618381L);ord[,u:=runif(.N)]
# fread lê o horário como POSIXct; seções sem horário (55) ou fora do arquivo chegam por último.
ord[,t:=as.numeric(recebido)][is.na(t),t:=Inf]
ord[,row:=.I]
ordens <- list(ordem_t1_2026=ord[order(t,u)]$row,inversa=ord[order(-t,u)]$row)
fracs <- seq(0,1,by=.1)
tasks <- CJ(cenario=names(cenarios),ordem=names(ordens),f=fracs)
rows <- parallel::mclapply(seq_len(nrow(tasks)),function(i) {
  data.table::setDTthreads(1)
  k <- tasks[i];tr <- cenarios[[k$cenario]]
  o <- tr[ordens[[k$ordem]][seq_len(round(k$f*nrow(tr)))]]
  r <- resultados_previsao_analise(state,o,NULL,400L,618360L,local)$resumo
  data.table(cenario=k$cenario,ordem=k$ordem,urnas=k$f,projecao=r$pct_a_projetado,q025=r$pct_a_q025,q975=r$pct_a_q975,
    apurado=if(nrow(o))100*sum(o$votos_a)/sum(o$validos) else NA_real_,peso=r$peso_atualizacao,inicial=r$pct_a_coef_iniciais,inicial_q025=r$pct_a_2022_q025,inicial_q975=r$pct_a_2022_q975,resultado_final=pct(tr))
},mc.cores=10,mc.preschedule=FALSE)
exigir_analise(!any(vapply(rows,function(x)inherits(x,"try-error"),TRUE)),paste(unlist(rows),collapse=" | "))
tab <- rbindlist(rows)[order(cenario,ordem,urnas)]
fwrite(tab,file.path(out,paste0("projecao_por_decil",sufixo,".csv")))
jsonlite::write_json(list(scope="synthetic T2 truths on the real 2026 population; arrival order of 2026 T1 BU availability (TSE arquivo-urna cs_da/cs_ha) and its reverse",
  logit_shift=list(nacional_2=d2,nacional_4=d4,nordeste=d4),final=lapply(cenarios,pct),initial_forecast_basis="2022 relationship (prior mean)",peso_maximo=peso_maximo),
  file.path(out,paste0("proveniencia",sufixo,".json")),pretty=TRUE,auto_unbox=TRUE,digits=NA)
options(width=200)
print(tab[,.(cenario,ordem,urnas=100*urnas,proj=sprintf("%.1f (%.1f a %.1f)",projecao,q025,q975),apurado=round(apurado,1),final=round(resultado_final,1))],nrows=200)
