# Passo 1: fixação interpretativa de Q e sensibilidade, sem ativar atualização.
# Usa apenas covariáveis T1 de 2022 e o ajuste histórico já salvo. Respostas
# dos ensaios são sintéticas; não estima variância temporal a partir de 2022.
args_all <- commandArgs(FALSE)
root <- dirname(normalizePath(sub("^--file=","",args_all[grepl("^--file=",args_all)])[1]))
source(file.path(root,"bayes.R"),encoding="UTF-8")
source(file.path(root,"voto_t1.R"),encoding="UTF-8")
source(file.path(root,"online_conjugado.R"),encoding="UTF-8")
out <- file.path(root,"output","escalas_online_v2_20261020")
dir.create(out,recursive=TRUE,showWarnings=FALSE)
fit_path <- file.path(root,"data","processed","voto_t1_fits.rds")
raw_path <- file.path(root,"..","data","eleicoes_2022_2026","raw","section_votes_2022_T1.parquet")
input_hashes <- vapply(c(fit_path,raw_path),function(p)digest::digest(file=p,algo="sha256"),"")
fit <- readRDS(fit_path)$lula
prior <- prior_online(fit)
G <- length(fit$levels)
jcomp <- match("comparecimento",prior$names)

t1 <- as.data.table(arrow::read_parquet(raw_path))
required <- c(keys,"aptos","comparecimento","validos","c13","c22")
stopifnot(all(required%in%names(t1)),!anyNA(t1[,..required]),
  !anyDuplicated(t1[,..keys]),all(t1$aptos>=0),
  all(t1$comparecimento>=0&t1$comparecimento<=t1$aptos),
  all(t1$validos>=0&t1$validos<=t1$comparecimento),
  all(t1$c13>=0&t1$c22>=0&t1$c13+t1$c22<=t1$validos))
d <- features_voto_t1(t1)[aptos>0&comparecimento>0&validos>0]
X <- X_comparecimento(d,fit$spec)
group <- match(d$uf,fit$levels)
stopifnot(!anyNA(group),all(is.finite(X)))
fwrite(data.table(variavel=required,
  tipo=vapply(t1[,..required],function(x)paste(class(x),collapse="/"),""),
  ausencias=vapply(t1[,..required],function(x)sum(is.na(x)),0L)),file.path(out,"auditoria_entradas.csv"))

# Interpretação isolada de cada componente em p=0,5, sem ruído residual.
# Inclinações correspondem ao contraste de um DP histórico do preditor.
scales <- prior$assumptions$drift_scales
interpretation <- data.table(componente=names(scales),dp_logit=as.numeric(scales),
  limite_95_logit=qnorm(.975)*as.numeric(scales))
interpretation[,limite_95_pp_em_p50:=100*(plogis(limite_95_logit)-.5)]
interpretation[,contraste:=c("nivel nacional","nivel adicional UF",rep("1 DP do preditor",5))]
fwrite(interpretation,file.path(out,"interpretacao_componentes.csv"))
fwrite(data.table(preditor=names(fit$spec$scale),dp_historico=as.numeric(fit$spec$scale)),
  file.path(out,"padronizacao_historica.csv"))
turnout_margin <- qnorm(.975)*scales["comp_sd"]*.01/fit$spec$scale["taxa_comparecimento"]
fwrite(data.table(contraste_comparecimento_pp=1,limite_95_mudanca_log_odds=turnout_margin,
  limite_95_mudanca_resposta_pp_em_p50=100*(plogis(turnout_margin)-.5)),
  file.path(out,"interpretacao_comparecimento_1pp.csv"))

profiles <- c("restrito","central","amplo")
priors <- setNames(lapply(profiles,function(p)prior_online(fit,perfil=p)),profiles)
reference_config <- file.path(root,"escalas_online_v1.json")
priors$anterior_v1 <- prior_online(fit,arquivo_escalas=reference_config)
profiles <- names(priors)
reference_scales <- priors$anterior_v1$assumptions$drift_scales
fwrite(rbindlist(lapply(profiles,function(profile)data.table(perfil=profile,
  componente=names(priors[[profile]]$assumptions$drift_scales),
  dp=as.numeric(priors[[profile]]$assumptions$drift_scales)))),file.path(out,"perfis_comparados.csv"))
geometry <- rbindlist(lapply(profiles,function(profile) {
  p <- priors[[profile]]
  v <- numeric(nrow(X))
  for(g in seq_len(G)) {
    take <- which(group==g)
    idx <- p$map[[g]]
    v[take] <- rowSums((X[take,,drop=FALSE]%*%p$drift_covariance[idx,idx])*X[take,,drop=FALSE])
  }
  width <- 100*(plogis(qnorm(.975)*sqrt(pmax(0,v)))-.5)
  data.table(perfil=profile,quantil=c(.05,.5,.95,.99),
    margem_mudanca_95_pp_em_p50=as.numeric(quantile(width,c(.05,.5,.95,.99))),
    secao_dp_intercepto=sqrt(p$drift_covariance[1,1]),
    geometria="covariaveis reais T1 2022; referencia hipotetica p=0,5; sem resposta T2")
}))
fwrite(geometry,file.path(out,"sensibilidade_geometria.csv"))
fwrite(data.table(parametro=prior$names,prior$drift_covariance,check.names=FALSE),
  file.path(out,"Q_central.csv"))

# Ensaio de mecanismo: desenho real e erros independentes gerados pelo modelo.
# Não escolhe Q por desempenho nesse ensaio e não usa resposta eleitoral real.
set.seed(618351)
nmax <- min(20000L,nrow(d))
take <- sample.int(nrow(d),nmax)
Xd <- matrix(0,nmax,length(prior$mean))
for(g in seq_len(G)) {
  rows <- which(group[take]==g)
  if(length(rows)) Xd[rows,prior$map[[g]]] <- X[take[rows],,drop=FALSE]
}
steps <- c(0L,50L,200L,1000L,5000L,nmax)
design_stats <- lapply(steps,function(n)crossprod(Xd[seq_len(n),,drop=FALSE]))
design_metric <- crossprod(Xd)/nmax
cases <- c("sem_mudanca","inversao_comparecimento_pequena","inversao_comparecimento_moderada",
           "mudanca_nacional_1dp_v1","mudanca_nacional_2dp_v1")
replications <- 200L
rows <- list()
for(rep in seq_len(replications)) {
  noise <- rnorm(nmax,0,prior$sigma)
  noise_stats <- lapply(steps,function(n)as.numeric(crossprod(Xd[seq_len(n),,drop=FALSE],noise[seq_len(n)])))
  direction <- if(rep%%2L==0L)1 else -1
  for(case in cases) {
    truth <- prior$mean
    if(case=="inversao_comparecimento_pequena") truth[jcomp] <- -1.5*truth[jcomp]
    if(case=="inversao_comparecimento_moderada")
      truth[jcomp] <- if(prior$mean[jcomp]<=0).02 else -.02
    if(startsWith(case,"mudanca_nacional")) {
      # Magnitudes fixadas na V1: a V2 enfrenta os mesmos deslocamentos reais,
      # sem diminuir a dificuldade do ensaio junto com a variância da prior.
      multiplier <- if(case=="mudanca_nacional_1dp_v1")1 else 2
      truth[seq_len(G)] <- truth[seq_len(G)]+direction*multiplier*reference_scales["alpha_global_sd"]
      truth[G+seq_len(G)] <- truth[G+seq_len(G)]+direction*multiplier*reference_scales["voto_global_sd"]
      truth[jcomp] <- truth[jcomp]+direction*multiplier*reference_scales["comp_sd"]
    }
    for(k in seq_along(steps)) {
      s <- list(xx=design_stats[[k]],xy=as.numeric(design_stats[[k]]%*%truth)+noise_stats[[k]],
                yy=NA_real_,n=steps[k])
      for(profile in profiles) {
        post <- posterior_online(priors[[profile]],s)
        error <- post$mean-truth
        comp_sd <- sqrt(post$covariance[jcomp,jcomp])
        rows[[length(rows)+1L]] <- data.table(repeticao=rep,cenario=case,perfil=profile,n=steps[k],
          rmse_media_condicional_logit=sqrt(max(0,as.numeric(crossprod(error,design_metric%*%error)))),
          erro_coef_comparecimento=error[jcomp],dp_posterior_comparecimento=comp_sd,
          cobertura_95_comparecimento=abs(error[jcomp])<=qnorm(.975)*comp_sd,
          sinal_comparecimento_correto=sign(post$mean[jcomp])==sign(truth[jcomp]))
      }
    }
  }
}
simulations <- rbindlist(rows)
fwrite(simulations,file.path(out,"simulacoes_sinteticas.csv"))
summary <- simulations[,.(repeticoes=.N,
  rmse_media_condicional_logit_medio=mean(rmse_media_condicional_logit),
  erro_monte_carlo_rmse_medio=sd(rmse_media_condicional_logit)/sqrt(.N),
  rmse_coef_comparecimento=sqrt(mean(erro_coef_comparecimento^2)),
  dp_posterior_comparecimento_medio=mean(dp_posterior_comparecimento),
  cobertura_95_comparecimento=mean(cobertura_95_comparecimento),
  fracao_sinal_correto=mean(sinal_comparecimento_correto)),by=.(cenario,perfil,n)]
summary[,erro_monte_carlo_cobertura:=sqrt(cobertura_95_comparecimento*(1-cobertura_95_comparecimento)/repeticoes)]
summary[,erro_monte_carlo_fracao_sinal:=sqrt(fracao_sinal_correto*(1-fracao_sinal_correto)/repeticoes)]
fwrite(summary,file.path(out,"sensibilidade_sintetica.csv"))
comparison <- merge(simulations[perfil=="central"],simulations[perfil=="anterior_v1"],
  by=c("repeticao","cenario","n"),suffixes=c("_v2","_v1"))
comparison[,diferenca_rmse:=rmse_media_condicional_logit_v2-rmse_media_condicional_logit_v1]
comparison <- comparison[,.(repeticoes=.N,
  rmse_v1=mean(rmse_media_condicional_logit_v1),rmse_v2=mean(rmse_media_condicional_logit_v2),
  diferenca_rmse_v2_menos_v1=mean(diferenca_rmse),
  erro_monte_carlo_diferenca=sd(diferenca_rmse)/sqrt(.N),
  cobertura_comparecimento_v1=mean(cobertura_95_comparecimento_v1),
  cobertura_comparecimento_v2=mean(cobertura_95_comparecimento_v2)),by=.(cenario,n)]
fwrite(comparison,file.path(out,"comparacao_pareada_v1_v2.csv"))
stopifnot(identical(input_hashes,vapply(c(fit_path,raw_path),function(p)digest::digest(file=p,algo="sha256"),"")))
jsonlite::write_json(list(status="passo_1_escalas_fixadas_sem_ativacao",
  config_version=prior$assumptions$drift_config_version,
  config_sha256=prior$assumptions$drift_config_sha256,profile_default="central",
  reference_config_sha256=priors$anterior_v1$assumptions$drift_config_sha256,
  reference_config_version=priors$anterior_v1$assumptions$drift_config_version,
  basis="explicit scale assumption, interpretation and sensitivity; not a temporal variance estimate",
  historical_fit_sha256=input_hashes[1],t1_2022_sha256=input_hashes[2],historical_fit_n=fit$n,
  t1_2022_rows=nrow(t1),rows_with_valid_predictors=nrow(d),excluded_zero_denominators=nrow(t1)-nrow(d),
  duplicate_keys=0,missing_required_values=0,simulations=list(seed=618351,replications=replications,
    max_rows=nmax,design="observed 2022 T1 covariates",response="synthetic Gaussian",sigma=prior$sigma,
    selection="uniform random order; same design and errors across profiles",
    scenarios=cases,scenario_shifts="national shifts fixed at V1 magnitudes for paired comparison",
    profiles=profiles,scope="conditional on model specification; no guarantee under unmodelled selection"),
  no_t2_2026_responses_used=TRUE,no_2026_forecasts_generated=TRUE,
  input_files_preserved=TRUE,no_runtime_state_saved=TRUE,
  scripts_sha256=setNames(lapply(c("avaliar_escalas_online.R","online_conjugado.R"),
    function(p)digest::digest(file=file.path(root,p),algo="sha256")),
    c("avaliar_escalas_online.R","online_conjugado.R")),
  packages=setNames(lapply(c("data.table","arrow","jsonlite","digest"),
    function(p)as.character(packageVersion(p))),c("data.table","arrow","jsonlite","digest")),
  source=list(title="Stan User's Guide: prior predictive checks",
    url="https://mc-stan.org/docs/stan-users-guide/posterior-predictive-checks.html#prior-predictive-checks",
    accessed="2026-10-20"),R=R.version.string),file.path(out,"proveniencia.json"),
    pretty=TRUE,auto_unbox=TRUE,digits=16)
print(interpretation)
print(comparison[n%in%c(50,1000,20000)])
print(summary[cenario=="inversao_comparecimento_moderada"&perfil=="central"])
cat("PASSO_1_ESCALAS_FIXADAS; nenhuma integracao operacional ativada\n")
