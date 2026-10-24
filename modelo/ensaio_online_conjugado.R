# Avaliação candidata: não troca coeficientes, painel nem automação ativos.
args_all <- commandArgs(FALSE)
root <- dirname(normalizePath(sub("^--file=","",args_all[grepl("^--file=",args_all)])[1]))
source(file.path(root,"bayes.R"),encoding="UTF-8")
source(file.path(root,"voto_t1.R"),encoding="UTF-8")
source(file.path(root,"online_conjugado.R"),encoding="UTF-8")
raw <- file.path(root,"..","data","eleicoes_2022_2026","raw")
t1 <- as.data.table(arrow::read_parquet(file.path(raw,"section_votes_2022_T1.parquet")))
t2 <- as.data.table(arrow::read_parquet(file.path(raw,"section_votes_2022_T2.parquet")))
d <- features_voto_t1(t1,t2)[aptos>0&aptos_t2>0&comparecimento>0&comp_t2>0&validos>0&validos_t2>0]
m <- unique(d[,.(uf,cd_mun)])[order(uf,cd_mun)]
m[,teste:=seq_len(.N)%%5L==0L,by=uf]
test <- d[m[teste==TRUE,.(uf,cd_mun)],on=.(uf,cd_mun)]
fit <- readRDS(file.path(root,"output","comparecimento_preditor_20261020","T1","voto_t1","posterior.rds"))
prior <- prior_online(fit)
no_drift <- prior_online(fit,alpha_global_sd=0,alpha_uf_sd=0,voto_global_sd=0,
  voto_uf_sd=0,comp_sd=0,outros_sd=0,validos_sd=0)
base <- baseline_voto_t1(fit,test)
mu0 <- predict_online(prior,base)
out <- file.path(root,"output","online_conjugado_20261020")
dir.create(out,recursive=TRUE,showWarnings=FALSE)
saveRDS(prior,file.path(out,"prior_validacao.rds"))

# Mudança SINTÉTICA: +0,2*(comparecimento_T1 - 0,60) no logit da votação.
# Com controle centrado por UF, muda intercepto e inclinação de forma coerente.
# A escolha é um teste de mecanismo, não uma hipótese adotada para 2026.
delta <- .2
truth_coefficients <- prior$mean
truth_coefficients[2L*length(prior$levels)+1L] <-
  truth_coefficients[2L*length(prior$levels)+1L]+delta*fit$spec$scale["taxa_comparecimento"]
for(g in seq_along(prior$levels)) {
  center <- fit$spec$center_uf[uf==prior$levels[g],comp_media]
  truth_coefficients[g] <- truth_coefficients[g]+delta*(center-.60)
}
set.seed(618341)
ysyn <- predict_online(prior,base,truth_coefficients)+rnorm(nrow(base),0,prior$sigma)
syn_valid <- as.integer(base$validos_base)
syn_lula <- round(syn_valid*plogis(ysyn))
scenarios <- list(
  observado_2022=list(valid=test$validos_t2,lula=test$lula_t2,y=test$y_lula,
    truth_coefficient=NA_real_),
  mudanca_sintetica=list(valid=syn_valid,lula=syn_lula,y=safe_logit(syn_lula,syn_valid),
    truth_coefficient=truth_coefficients[2L*length(prior$levels)+1L]*.01/fit$spec$scale["taxa_comparecimento"]))
# A junção de baseline mantém a ordem das chaves de test, verificada abaixo.
stopifnot(identical(base[,..keys],test[,..keys]))
set.seed(618342)
orders_common <- list(aleatoria=sample.int(nrow(base)),menor_lula_t1=order(base$x_lula),
  menor_comparecimento_t1=order(base$taxa_comp_t1))
rows <- list()
fractions <- c(0,.001,.01,.1,.5,.9,1)
for(scenario in names(scenarios)) {
  truth <- scenarios[[scenario]]
  pop <- 100*sum(truth$lula)/sum(truth$valid)
  orders <- orders_common
  if(scenario=="observado_2022")
    orders$residuo_negativo_primeiro <- order(truth$y-mu0) # Seleção NÃO ignorável: teste adverso.
  for(name in names(orders)) for(f in fractions) {
    observed <- orders[[name]][seq_len(floor(nrow(base)*f))]
    pending <- setdiff(seq_len(nrow(base)),observed)
    stats_time <- system.time(s <- online_stats(prior,base[observed],truth$y[observed]))[["elapsed"]]
    update_time <- system.time(post <- posterior_online(prior,s))[["elapsed"]]
    mu <- predict_online(prior,base[pending],post$mean)
    known_a <- sum(truth$lula[observed]);known_v <- sum(truth$valid[observed])
    denominator <- known_v+sum(base$validos_base[pending])
    frozen <- 100*(known_a+sum(base$validos_base[pending]*logistic_normal_mean(mu0[pending],prior$sigma)))/denominator
    online <- 100*(known_a+sum(base$validos_base[pending]*logistic_normal_mean(mu,prior$sigma)))/denominator
    effect <- coefficient_online(prior,post)
    rows[[length(rows)+1L]] <- cbind(data.table(cenario=scenario,ordem=name,fracao=f,
      real=pop,congelado=frozen,adaptativo=online,erro_congelado_pp=frozen-pop,
      erro_adaptativo_pp=online-pop,coef_real_log_odds_por_1pp=truth$truth_coefficient,
      segundos_estatisticas=stats_time,segundos_update=update_time),effect)
    if(scenario=="mudanca_sintetica"&&name=="aleatoria") {
      fixed <- posterior_online(no_drift,s)
      fixed_mu <- predict_online(no_drift,base[pending],fixed$mean)
      prediction <- 100*(known_a+sum(base$validos_base[pending]*logistic_normal_mean(fixed_mu,no_drift$sigma)))/denominator
      rows[[length(rows)+1L]] <- cbind(data.table(cenario=scenario,ordem="aleatoria_sem_margem_mudanca",fracao=f,
        real=pop,congelado=frozen,adaptativo=prediction,erro_congelado_pp=frozen-pop,
        erro_adaptativo_pp=prediction-pop,coef_real_log_odds_por_1pp=truth$truth_coefficient,
        segundos_estatisticas=stats_time,segundos_update=NA_real_),coefficient_online(no_drift,fixed))
    }
  }
}
result <- rbindlist(rows)
stopifnot(all(abs(result[fracao==1,erro_adaptativo_pp])<1e-10))
fwrite(result,file.path(out,"ensaio.csv"))
fwrite(result[,.(max_erro_congelado_pp=max(abs(erro_congelado_pp)),
  max_erro_adaptativo_pp=max(abs(erro_adaptativo_pp))),by=.(cenario,ordem)],file.path(out,"resumo_erros.csv"))
benchmark <- system.time({
  for(i in 1:100) tmp <- posterior_online(prior,s)
})[["elapsed"]]/100
fwrite(data.table(coeficientes=length(prior$mean),update_medio_segundos=benchmark,
  maior_tempo_snapshot_segundos=max(result$segundos_estatisticas)),file.path(out,"tempo.csv"))
jsonlite::write_json(list(status="candidato_nao_ativo",synthetic_delta_raw=delta,
  synthetic_reference_turnout=.60,priors=prior$assumptions,selection_warning=
    "Chegada pode depender de resíduos não explicados por X; conjugação não elimina esse viés"),
  file.path(out,"proveniencia.json"),pretty=TRUE,auto_unbox=TRUE)
print(result[fracao%in%c(0,.01,.1,.5),.(cenario,ordem,fracao,erro_congelado_pp,erro_adaptativo_pp,
  media_log_odds_por_1pp,q025_log_odds,q975_log_odds)])
print(fread(file.path(out,"tempo.csv")))
