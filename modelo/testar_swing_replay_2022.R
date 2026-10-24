# Mesma pergunta de testar_swing_nacional.R com dados REAIS: replay do 2º turno de 2022 nos
# municípios reservados (ajuste de treino nos demais), chegada na ordem do 1º turno de 2026.
# O swing é somado ao logit real de cada seção; preserva a forma da relação de 2022 que o
# modelo linear não reproduz (a fonte dos erros no teste em ordem do voto T1).
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
nordeste <- c("AL","BA","CE","MA","PB","PE","PI","RN","SE")

raw <- file.path(root,"..","data","eleicoes_2022_2026","raw")
t1 <- as.data.table(arrow::read_parquet(file.path(raw,"section_votes_2022_T1.parquet")))
t2 <- as.data.table(arrow::read_parquet(file.path(raw,"section_votes_2022_T2.parquet")))
d <- .analise_componentes$features(t1,t2)[aptos>0&aptos_t2>0&comparecimento>0&comp_t2>0&validos>0&validos_t2>0]
m <- unique(d[,.(uf,cd_mun)])[order(uf,cd_mun)];m[,teste:=seq_len(.N)%%5L==0L,by=uf]
reserve <- normalizar_chaves_analise(d[m[teste==TRUE,.(uf,cd_mun)],on=.(uf,cd_mun)][,..chaves_analise])
fit22 <- readRDS(file.path(root,"output","comparecimento_preditor_20261020","T1","voto_t1","posterior.rds"))
p22 <- .analise_componentes$prior_online(fit22)
state22 <- list(prior=p22,population=preparar_populacao_analise(t1,reserve,p22),id="replay_2022",
  provenance=list(drift_version="v2_central",profile="central"))
bus22 <- merge(reserve,t2[,.(uf,cd_mun,zona,secao,aptos,comparecimento,validos,votos_a=c13,votos_b=validos-c13,brancos,nulos)],
  by=chaves_analise,sort=TRUE)

logit_real <- qlogis((bus22$votos_a+.5)/(bus22$validos+1))
verdade <- function(delta) {
  t <- copy(bus22)
  t[,votos_a:=pmin(validos,pmax(0L,as.integer(round((validos+1)*plogis(logit_real+delta)-.5))))][,votos_b:=validos-votos_a]
  t[]
}
pct <- function(t)100*sum(t$votos_a)/sum(t$validos)
base <- pct(verdade(0))
calibrar <- function(alvo,ufs=unique(bus22$uf))uniroot(function(x)pct(verdade(x*(bus22$uf%in%ufs)))-base-alvo,c(-1,1))$root
d2 <- calibrar(2);d4 <- calibrar(4)
cenarios <- list(sem_swing=verdade(0),swing_nacional_2=verdade(d2),swing_nacional_4=verdade(d4),
  swing_so_nordeste=verdade(d4*(bus22$uf%in%nordeste)))

# Horário de 2026 por seção; sem a seção em 2026, mediana da zona, do município ou da UF.
ch <- fread(file.path(root,"data","processed","chegada_t1_2026.csv.gz"))[,t:=as.numeric(recebido)]
ord <- ch[bus22[,..chaves_analise],on=chaves_analise,.(uf,cd_mun,zona,secao,t)]
ord[,origem:=fifelse(is.na(t),NA_character_,"secao")]
for (k in list(c("uf","cd_mun","zona"),c("uf","cd_mun"),"uf")) {
  med <- ch[!is.na(t),.(tm=median(t)),by=k]
  ord[med,on=k,`:=`(origem=fifelse(is.na(t),paste(k,collapse="_"),origem),t=fifelse(is.na(t),i.tm,t))]
}
exigir_analise(!anyNA(ord$t),"seções do replay sem horário de chegada")
set.seed(618382L);ord[,`:=`(u=runif(.N),row=.I)]
ordens <- list(ordem_t1_2026=ord[order(t,u)]$row,inversa=ord[order(-t,u)]$row)
fracs <- seq(0,1,by=.1)
tasks <- CJ(cenario=names(cenarios),ordem=names(ordens),f=fracs)
rows <- parallel::mclapply(seq_len(nrow(tasks)),function(i) {
  data.table::setDTthreads(1)
  k <- tasks[i];tr <- cenarios[[k$cenario]]
  o <- tr[ordens[[k$ordem]][seq_len(round(k$f*nrow(tr)))]]
  r <- resultados_previsao_analise(state22,o,NULL,400L,618360L,local)$resumo
  data.table(cenario=k$cenario,ordem=k$ordem,urnas=k$f,projecao=r$pct_a_projetado,q025=r$pct_a_q025,q975=r$pct_a_q975,
    apurado=if(nrow(o))100*sum(o$votos_a)/sum(o$validos) else NA_real_,peso=r$peso_atualizacao,inicial=r$pct_a_coef_iniciais,inicial_q025=r$pct_a_2022_q025,inicial_q975=r$pct_a_2022_q975,resultado_final=pct(tr))
},mc.cores=10,mc.preschedule=FALSE)
exigir_analise(!any(vapply(rows,function(x)inherits(x,"try-error"),TRUE)),paste(unlist(rows),collapse=" | "))
tab <- rbindlist(rows)[order(cenario,ordem,urnas)]
fwrite(tab,file.path(out,paste0("replay_2022_projecao_por_decil",sufixo,".csv")))
jsonlite::write_json(list(scope="real 2022 T2 BUs of reserved municipalities (1 in 5 per UF), training fit on the others; swing added to each section's smoothed logit",
  arrival="2026 T1 BU availability time per section; zone, municipality or UF median when the section is absent in 2026",
  matching=as.list(ord[,.N,by=origem][,setNames(N,origem)]),logit_shift=list(nacional_2=d2,nacional_4=d4,nordeste=d4),
  final=lapply(cenarios,pct),peso_maximo=peso_maximo),file.path(out,paste0("replay_2022_proveniencia",sufixo,".json")),pretty=TRUE,auto_unbox=TRUE,digits=NA)
# Sensibilidade: Fortaleza (CE 13897) é 1/3 dos válidos que chegam nos dois últimos decis e
# tem resíduo de +0,10 no logit em 2022. Mesmo replay sem esse município, ordem de 2026.
sem_fortaleza <- !(bus22$uf=="CE"&bus22$cd_mun==13897L)
state_sf <- state22;state_sf$population <- state22$population[!(uf=="CE"&cd_mun==13897L)]
exigir_analise(nrow(state_sf$population)==sum(sem_fortaleza),"população sem Fortaleza difere dos BUs")
ord_sf <- ord[sem_fortaleza][,row:=.I]
tasks_sf <- CJ(cenario=c("sem_swing","swing_nacional_2"),f=fracs)
rows_sf <- parallel::mclapply(seq_len(nrow(tasks_sf)),function(i) {
  data.table::setDTthreads(1)
  k <- tasks_sf[i];tr <- cenarios[[k$cenario]][sem_fortaleza]
  o <- tr[ord_sf[order(t,u)]$row[seq_len(round(k$f*nrow(tr)))]]
  r <- resultados_previsao_analise(state_sf,o,NULL,400L,618360L,local)$resumo
  data.table(cenario=k$cenario,ordem="ordem_t1_2026_sem_fortaleza",urnas=k$f,projecao=r$pct_a_projetado,q025=r$pct_a_q025,
    q975=r$pct_a_q975,apurado=if(nrow(o))100*sum(o$votos_a)/sum(o$validos) else NA_real_,peso=r$peso_atualizacao,inicial=r$pct_a_coef_iniciais,inicial_q025=r$pct_a_2022_q025,inicial_q975=r$pct_a_2022_q975,resultado_final=pct(tr))
},mc.cores=10,mc.preschedule=FALSE)
exigir_analise(!any(vapply(rows_sf,function(x)inherits(x,"try-error"),TRUE)),paste(unlist(rows_sf),collapse=" | "))
tab <- rbind(tab,rbindlist(rows_sf))[order(cenario,ordem,urnas)]
fwrite(tab,file.path(out,paste0("replay_2022_projecao_por_decil",sufixo,".csv")))
options(width=200)
print(tab[,.(cenario,ordem,urnas=100*urnas,proj=sprintf("%.1f (%.1f a %.1f)",projecao,q025,q975),apurado=round(apurado,1),final=round(resultado_final,1))],nrows=200)
