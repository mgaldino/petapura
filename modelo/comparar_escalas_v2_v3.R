# Projeção de Lula e intervalo de 95% de 10% em 10% das urnas, com a escala de mudança
# atual (V2) e a estimada em 2010-2022 (V3 candidata, MUDANCA_HISTORICA.md). Modelo atual
# com componentes locais v2 e atualização gradual; sem âncora oficial. Nada é alterado.
args_all <- commandArgs(FALSE)
root <- dirname(normalizePath(sub("^--file=","",args_all[grepl("^--file=",args_all)])[1]))
source(file.path(root,"previsao_execucao.R"),encoding="UTF-8")
source(file.path(root,"teste_integrado_comum.R"),encoding="UTF-8")
out <- file.path(root,"output","comparacao_escalas_v2_v3_20261021")
dir.create(out,recursive=TRUE,showWarnings=FALSE)
local <- ler_componentes_locais()
v3 <- list(alpha_global_sd=.22,alpha_uf_sd=.126,voto_global_sd=.025,voto_uf_sd=.040,comp_sd=.017,outros_sd=.05,validos_sd=.033)
com_v3 <- function(state,fit){s <- state;s$prior <- do.call(.analise_componentes$prior_online,c(list(fit),v3));s}
fracs <- seq(0,1,by=.1)

# Dados simulados: verdade "realista" do teste de fluxo (semente 618370) na população de 2026.
state <- carregar_ponto_partida_analise(file.path(root,"data","processed","estado_inicial_v2"))
fit <- readRDS(file.path(root,"data","processed","voto_t1_fits.rds"))$lula
truth <- gerar_verdade_teste(state,componentes_2022_teste(root),"realista",seed=618370L,zero_validos=25L)
# Replay de 2022: municípios reservados, ajuste de treino, BUs T2 reais.
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
truth22 <- copy(bus22)[state22$population[,c(chaves_analise,"x_lula"),with=FALSE],on=chaves_analise]
truth22[,municipio:=.GRP,by=.(uf,cd_mun)][,residuo:=0]

cenarios <- list(
  list(nome="Simulado, chegada aleatória",truth=truth,ordem="aleatoria",states=list(V2=state,V3=com_v3(state,fit))),
  list(nome="Simulado, ordem crescente do voto de Lula no 1º turno",truth=truth,ordem="voto_t1_crescente",
    states=list(V2=state,V3=com_v3(state,fit))),
  list(nome="Replay real de 2022, ordem crescente do voto de Lula no 1º turno",truth=truth22,ordem="voto_t1_crescente",
    states=list(V2=state22,V3=com_v3(state22,fit22))))
tasks <- CJ(c=seq_along(cenarios),v=c("V2","V3"),f=fracs)
rows <- parallel::mclapply(seq_len(nrow(tasks)),function(i) {
  data.table::setDTthreads(1)
  t <- tasks[i];cen <- cenarios[[t$c]]
  perm <- ordem_chegada_teste(cen$truth,cen$ordem,618373L)
  o <- cen$truth[perm[seq_len(round(t$f*nrow(cen$truth)))],
    .(uf,cd_mun,zona,secao,aptos,comparecimento,validos,votos_a,votos_b,brancos,nulos)]
  r <- resultados_previsao_analise(cen$states[[t$v]],o,NULL,400L,618360L,local)$resumo
  data.table(cenario=cen$nome,escala=t$v,urnas=t$f,projecao=r$pct_a_projetado,q025=r$pct_a_q025,q975=r$pct_a_q975,
    peso_atualizacao=r$peso_atualizacao,resultado_final=pct_verdade_teste(cen$truth))
},mc.cores=10,mc.preschedule=FALSE)
exigir_analise(!any(vapply(rows,function(x)inherits(x,"try-error"),TRUE)),paste(unlist(rows),collapse=" | "))
tab <- rbindlist(rows)[order(cenario,escala,urnas)]
fwrite(tab,file.path(out,"projecao_por_decil.csv"))
w <- dcast(tab,cenario+urnas~escala,value.var=c("projecao","q025","q975"))
print(w[,.(cenario,urnas,V2=sprintf("%.1f (%.1f a %.1f)",projecao_V2,q025_V2,q975_V2),
  V3=sprintf("%.1f (%.1f a %.1f)",projecao_V3,q025_V3,q975_V3))],nrows=100)
print(unique(tab[,.(cenario,resultado_final)]))
