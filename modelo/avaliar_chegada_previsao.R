# Teste 5: erros e intervalos das previsões por cenário de chegada.
# (a) Simulação na população real de 2026: verdades SINTÉTICAS "correto" e "realista".
# (b) Replay de 2022 fora da amostra: BUs T2 REAIS dos municípios reservados, com o
#     ajuste de treino que não os usou. Não substitui a validação com BUs T2 de 2026.
# Usa as mesmas rotinas do executor (estado_local_previsao e resultados_previsao_analise).
args_all <- commandArgs(FALSE)
root <- dirname(normalizePath(sub("^--file=","",args_all[grepl("^--file=",args_all)])[1]))
source(file.path(root,"previsao_execucao.R"),encoding="UTF-8")
source(file.path(root,"teste_integrado_comum.R"),encoding="UTF-8")
out <- file.path(root,"output","testes_integrados_20261020")
dir.create(out,recursive=TRUE,showWarnings=FALSE)
reps <- as.integer(Sys.getenv("REPETICOES","40"))
workers <- as.integer(Sys.getenv("PROCESSOS","10"))
draws <- 400L
local <- ler_componentes_locais()
fracs <- c(0,.01,.05,.10,.25)
orders <- c("aleatoria","ufs_velocidades","municipios_blocos","voto_t1_crescente","adversa_residuo")
random_orders <- c("aleatoria","ufs_velocidades","municipios_blocos")
started <- proc.time()[["elapsed"]]

avaliar_fracao <- function(state,truth,rows,ordem,fracao,semente) {
  o <- truth[rows,.(uf,cd_mun,zona,secao,aptos,comparecimento,validos,votos_a,votos_b,brancos,nulos)]
  t0 <- proc.time()[["elapsed"]]
  r <- resultados_previsao_analise(state,o,NULL,draws,semente,local)
  tp <- pct_verdade_teste(truth)
  tuf <- truth[,.(verdade=100*sum(votos_a)/sum(validos)),keyby=uf]
  u <- r$uf[tuf,on="uf"]
  data.table(ordem=ordem,fracao=fracao,bus=nrow(o),verdade=tp,projecao=r$resumo$pct_a_projetado,
    q025=r$resumo$pct_a_q025,q975=r$resumo$pct_a_q975,coef_iniciais=r$resumo$pct_a_coef_iniciais,
    erro_pp=r$resumo$pct_a_projetado-tp,cobre=r$resumo$pct_a_q025<=tp&tp<=r$resumo$pct_a_q975,
    amplitude_pp=r$resumo$pct_a_q975-r$resumo$pct_a_q025,
    uf_cobre=mean(u$pct_a_q025<=u$verdade&u$verdade<=u$pct_a_q975),
    uf_rmse_pp=sqrt(mean((u$pct_a_projetado-u$verdade)^2)),
    comp_media_log_odds_1pp=r$resumo$comp_log_odds_por_1pp,peso_atualizacao=r$resumo$peso_atualizacao,
    segundos=proc.time()[["elapsed"]]-t0)
}

replicar <- function(state,truth,rep,ordens,seed_base) {
  data.table::setDTthreads(1)
  rows <- list(avaliar_fracao(state,truth,integer(),"nenhuma",0,618360L+rep))
  for(ordem in ordens) {
    perm <- ordem_chegada_teste(truth,ordem,seed_base+rep*100L+match(ordem,orders))
    for(f in fracs[fracs>0])rows[[length(rows)+1L]] <- avaliar_fracao(state,truth,perm[seq_len(round(f*nrow(truth)))],ordem,f,618360L+rep)
  }
  rbindlist(rows)[,repeticao:=rep]
}

# Mudança da projeção em relação à previsão inicial (0% dos BUs) da mesma repetição.
mudanca_inicio <- function(d,by)d[,mudanca_pp:=projecao-projecao[ordem=="nenhuma"],by=by]
resumir <- function(d,by) d[,.(repeticoes=.N,vies_pp=mean(erro_pp),rmse_pp=sqrt(mean(erro_pp^2)),
  mudanca_abs_media_pp=mean(abs(mudanca_pp)),mudanca_abs_max_pp=max(abs(mudanca_pp)),peso_atualizacao=mean(peso_atualizacao),
  erro_abs_max_pp=max(abs(erro_pp)),cobertura=mean(cobre),ep_cobertura=sqrt(mean(cobre)*(1-mean(cobre))/.N),
  amplitude_media_pp=mean(amplitude_pp),cobertura_uf=mean(uf_cobre),rmse_uf_pp=mean(uf_rmse_pp),
  segundos_medios=mean(segundos)),keyby=by]

# ---------- (a) Simulação na população real de 2026 ----------
state <- carregar_ponto_partida_analise(file.path(root,"data","processed","estado_inicial_v2"))
comp <- componentes_2022_teste(root)
tasks <- CJ(cenario=c("correto","realista"),rep=seq_len(reps))
sim <- parallel::mclapply(seq_len(nrow(tasks)),function(i) {
  t <- tasks[i]
  truth <- gerar_verdade_teste(state,comp,t$cenario,seed=700000L+t$rep*10L+(t$cenario=="realista"))
  replicar(state,truth,t$rep,orders,800000L+(t$cenario=="realista")*50000L)[,cenario:=t$cenario]
},mc.cores=workers,mc.preschedule=FALSE)
failed <- vapply(sim,function(x)inherits(x,"try-error")||!is.data.table(x),TRUE)
exigir_analise(!any(failed),paste("Falhas na simulação:",paste(unlist(sim[failed]),collapse=" | ")))
sim <- rbindlist(sim)
setcolorder(sim,c("cenario","repeticao"))
mudanca_inicio(sim,c("cenario","repeticao"))
fwrite(sim,file.path(out,"chegada_simulacao_2026.csv"))
sim_summary <- resumir(sim,c("cenario","ordem","fracao"))
fwrite(sim_summary,file.path(out,"chegada_simulacao_2026_resumo.csv"))

# ---------- (b) Replay de 2022 fora da amostra com BUs T2 reais ----------
raw <- file.path(root,"..","data","eleicoes_2022_2026","raw")
read <- function(f)as.data.table(arrow::read_parquet(file.path(raw,f)))
t1 <- read("section_votes_2022_T1.parquet");t2 <- read("section_votes_2022_T2.parquet")
d <- .analise_componentes$features(t1,t2)[aptos>0&aptos_t2>0&comparecimento>0&comp_t2>0&validos>0&validos_t2>0]
m <- unique(d[,.(uf,cd_mun)])[order(uf,cd_mun)]
m[,teste:=seq_len(.N)%%5L==0L,by=uf]                    # mesma partição de avaliar_comparecimento_preditor.R
reserve <- normalizar_chaves_analise(d[m[teste==TRUE,.(uf,cd_mun)],on=.(uf,cd_mun)][,..chaves_analise])
work <- tempfile("replay-2022-");dir.create(work)
fit_train <- readRDS(file.path(root,"output","comparecimento_preditor_20261020","T1","voto_t1","posterior.rds"))
exigir_analise(isTRUE(fit_train$gate$pass)&&identical(fit_train$structure,"voto_t1"),"Ajuste de treino inadequado")
fit_path <- file.path(work,"ajuste_treino.rds");saveRDS(list(lula=fit_train),fit_path)
t1_path <- file.path(raw,"section_votes_2022_T1.parquet")
# Snapshot inicial vazio publicado pelo código real do coletor (HTTP simulado).
coleta <- file.path(work,"coleta");dir.create(coleta)
inv_csv <- file.path(work,"inventario.csv");fwrite(reserve,inv_csv)
empty_csv <- file.path(work,"vazio.csv")
writeLines(paste(c("uf","cd_mun","zona","secao","aptos","comparecimento","validos","votos_a","votos_b","brancos",
  "nulos","hash","hash_status","source_utc","collected_utc","bu_sha256"),collapse=","),empty_csv)
cfg <- jsonlite::read_json(file.path(root,"config.json"),simplifyVector=TRUE)
areas <- lapply(cfg$ufs,function(u)list(st=0,ts=nrow(reserve[uf==u]),votos_a=0,votos_b=0,dg="25/10/2026",hg="17:00:00"))
names(areas) <- cfg$ufs
areas$BR <- list(st=0,ts=nrow(reserve),votos_a=0,votos_b=0,dg="25/10/2026",hg="17:00:00")
spec <- file.path(work,"spec.json")
jsonlite::write_json(list(inventory=inv_csv,observed=empty_csv,official=areas),spec,auto_unbox=TRUE,digits=NA)
python <- Find(function(p)nzchar(p)&&file.exists(p)&&identical(suppressWarnings(
  system2(p,c("-c",shQuote("import asn1tools")),stdout=FALSE,stderr=FALSE)),0L),
  c(file.path(root,".venv","bin","python"),path.expand("~/Documents/DCP/Papers/electoralFraud/.venv_tse_bu/bin/python")))
status <- system2(python,c(shQuote(file.path(root,"publicar_teste_integrado.py")),shQuote(coleta),shQuote(spec)),stdout=TRUE,stderr=TRUE)
exigir_analise(is.null(attr(status,"status")),paste(status,collapse="\n"))
state22 <- inicializar_analise(file.path(work,"estado"),fit_path,t1_path,file.path(root,"config.json"),
  file.path(coleta,"tse_export"))
bus22 <- merge(reserve,t2[,.(uf,cd_mun,zona,secao,aptos,comparecimento,validos,votos_a=c13,votos_b=validos-c13,brancos,nulos)],
  by=chaves_analise,sort=TRUE)
exigir_analise(nrow(bus22)==nrow(reserve)&&all(bus22$votos_b>=0),"BUs T2 de 2022 incompletos para a reserva")
.analise_componentes$validar_observados_voto(bus22)
pop22 <- state22$population
X22 <- .analise_componentes$X_comparecimento(pop22,state22$prior$spec)
mu22 <- preditor_linear_teste(state22$prior,X22,match(pop22$uf,state22$prior$levels),state22$prior$mean)
truth22 <- copy(bus22)[pop22[,c(chaves_analise,"x_lula"),with=FALSE],on=chaves_analise]
truth22[,`:=`(municipio=.GRP),by=.(uf,cd_mun)]
truth22[,residuo:=.analise_componentes$safe_logit(votos_a,validos)-mu22]
exigir_analise(identical(truth22[,..chaves_analise],pop22[,..chaves_analise]),"Ordem da reserva divergente")
replay <- parallel::mclapply(seq_len(reps),function(rep)
  replicar(state22,truth22,rep,if(rep==1L)orders else random_orders,900000L),
  mc.cores=workers,mc.preschedule=FALSE)
failed <- vapply(replay,function(x)inherits(x,"try-error")||!is.data.table(x),TRUE)
exigir_analise(!any(failed),paste("Falhas no replay:",paste(unlist(replay[failed]),collapse=" | ")))
replay <- rbindlist(replay)
setcolorder(replay,"repeticao")
mudanca_inicio(replay,"repeticao")
fwrite(replay,file.path(out,"replay_2022_reserva.csv"))
fwrite(resumir(replay,c("ordem","fracao")),file.path(out,"replay_2022_reserva_resumo.csv"))
jsonlite::write_json(list(scope=c(simulacao="real 2026 frozen population; synthetic truths",
    replay="2022 out-of-sample: real T2 BUs of held-out municipalities, training fit, V2 central Q"),
  measured_utc=agora_analise(),repetitions=reps,draws=draws,fractions=fracs,orders=orders,
  local_components=list(version=local$versao,sha256=local$sha256),
  reserve_sections=nrow(reserve),reserve_municipalities=uniqueN(reserve[,.(uf,cd_mun)]),
  replay_truth_pct=pct_verdade_teste(truth22),train_fit_n=fit_train$n,
  components_2022=list(municipal_var=comp$residuo[["entre"]],within_var=comp$residuo[["dentro"]],
    model_sigma2=comp$sigma2_modelo),seconds=proc.time()[["elapsed"]]-started,
  code_sha256=list(avaliar_chegada_previsao.R=hash_arquivo_analise(file.path(root,"avaliar_chegada_previsao.R")),
    teste_integrado_comum.R=hash_arquivo_analise(file.path(root,"teste_integrado_comum.R")),
    previsao_execucao.R=hash_arquivo_analise(file.path(root,"previsao_execucao.R")),
    componentes_locais.R=hash_arquivo_analise(file.path(root,"componentes_locais.R")))),
  file.path(out,"verificacao_chegada.json"),pretty=TRUE,auto_unbox=TRUE,digits=NA)
unlink(work,recursive=TRUE)
print(sim_summary[,.(cenario,ordem,fracao,vies_pp=round(vies_pp,3),rmse_pp=round(rmse_pp,3),cobertura,amplitude_media_pp=round(amplitude_media_pp,2),cobertura_uf=round(cobertura_uf,3))])
print(resumir(replay,c("ordem","fracao"))[,.(ordem,fracao,repeticoes,vies_pp=round(vies_pp,3),rmse_pp=round(rmse_pp,3),cobertura,amplitude_media_pp=round(amplitude_media_pp,2),cobertura_uf=round(cobertura_uf,3))])
