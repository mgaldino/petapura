# Uma só resposta, voto de Lula T2. Não estima regressão de comparecimento.
# As inclinações de comparecimento e voto T1 são associações dentro de UF.
spec_comparecimento <- function(d) {
  vars <- c("x_lula", "taxa_comparecimento", "x_outros", "x_validos")
  center_uf <- d[, .(lula_media = mean(x_lula), comp_media = mean(taxa_comparecimento)), by=uf]
  centered <- merge(d,center_uf,by="uf",all.x=TRUE)
  centered[, `:=`(x_lula=x_lula-lula_media,taxa_comparecimento=taxa_comparecimento-comp_media)]
  center <- c(x_lula=0,taxa_comparecimento=0,
    x_outros=mean(d$x_outros),x_validos=mean(d$x_validos))
  scale <- vapply(vars,function(v)sd(centered[[v]]),0.0)
  stopifnot(all(is.finite(scale)),all(scale>0))
  list(vars=vars,center=center,scale=scale,center_uf=center_uf,turno=1L)
}

X_comparecimento <- function(d,spec) {
  z <- merge(data.table(row=seq_len(nrow(d)),d),spec$center_uf,by="uf",all.x=TRUE,sort=FALSE)
  setorder(z,row)
  z[,`:=`(x_lula=x_lula-lula_media,taxa_comparecimento=taxa_comparecimento-comp_media)]
  stopifnot(!anyNA(z[,spec$vars,with=FALSE]))
  m <- as.matrix(z[,spec$vars,with=FALSE])
  answer <- cbind(intercept=rep(1,nrow(m)),sweep(sweep(m,2,spec$center,"-"),2,spec$scale,"/"))
  colnames(answer) <- c("intercept",spec$vars)
  answer
}

fit_comparecimento <- function(d,structure,stan,out) {
  spec <- spec_comparecimento(d)
  X <- X_comparecimento(d,spec)
  levels <- sort(unique(d$uf))
  varying <- switch(structure,intercepto=1L,voto_t1=c(1L,2L),comparecimento=c(1L,3L),ambos=c(1L,2L,3L))
  stopifnot(length(varying)>0)
  stats <- sufficient(X,d$y_lula,d$uf,levels)
  p <- ncol(X);k <- length(varying)
  args <- c(list(G=length(levels),P=p,K=k,varying=varying),stats,
    list(prior_mean=rep(0,p),prior_sd=c(1.5,rep(.7,p-1)),prior_tau=rep(.5,k)))
  signature <- digest::digest(list(args,spec,structure,readLines(stan$stan_file())))
  cached <- file.path(out,"posterior.rds")
  if(file.exists(cached)) {
    old <- readRDS(cached)
    if(identical(old$signature,signature)) return(old)
    stop("Ajuste de outra versão: usar nova pasta de saída")
  }
  dir.create(out,recursive=TRUE,showWarnings=FALSE)
  fit <- stan$sample(data=args,chains=4,parallel_chains=2,iter_warmup=1000,iter_sampling=1000,
    seed=618331,adapt_delta=.97,max_treedepth=12,refresh=0,output_dir=out)
  summary <- as.data.table(fit$summary())
  sampler <- as.data.table(fit$diagnostic_summary())
  fwrite(summary,file.path(out,"summary.csv"));fwrite(sampler,file.path(out,"sampler.csv"))
  gate <- list(max_rhat=max(summary$rhat,na.rm=TRUE),min_ess_bulk=min(summary$ess_bulk,na.rm=TRUE),
    divergences=sum(sampler$num_divergent),treedepth=sum(sampler$num_max_treedepth))
  gate$pass <- gate$max_rhat<=1.01&&gate$min_ess_bulk>=400&&gate$divergences==0&&gate$treedepth==0
  result <- list(spec=spec,levels=levels,structure=structure,varying=varying,
    draws=unclass(posterior::as_draws_matrix(fit$draws(c("theta","beta","tau","sigma")))),
    gate=gate,signature=signature,n=nrow(d),
    parametros_livres=p+length(levels)*k+k+k*(k-1)/2+1)
  saveRDS(result,cached)
  result
}

predict_comparecimento <- function(fit,d,parameters=mean_parameters(fit)) {
  X <- X_comparecimento(d,fit$spec)
  group <- match(d$uf,fit$levels)
  rowSums(X*parameters$theta[group,,drop=FALSE])
}

score_comparecimento <- function(fit,d) {
  p <- mean_parameters(fit)
  mu <- predict_comparecimento(fit,d,p)
  actual <- 100*d$lula_t2/d$validos_t2
  predicted <- 100*logistic_normal_mean(mu,p$sigma)
  data.table(estrutura=fit$structure,turno_comparecimento=fit$spec$turno,
      n=nrow(d),municipios_teste=uniqueN(paste(d$uf,d$cd_mun)),log_score=mean(dnorm(d$y_lula,mu,p$sigma,log=TRUE)),
      rmse_pp=sqrt(mean((actual-predicted)^2)),vies_pp=mean(predicted-actual),
      parametros_livres=fit$parametros_livres)
}

efeito_comparecimento <- function(fit) {
  column <- match("taxa_comparecimento",fit$spec$vars)+1L
  # Inclinação por um ponto percentual adicional de comparecimento, em log-odds.
  by_uf <- rbindlist(lapply(seq_along(fit$levels),function(g) {
    beta <- fit$draws[,sprintf("theta[%d,%d]",g,column)]/fit$spec$scale[column-1L]
    # Padronização interpretativa em p=0,5, integrando o resíduo logística-normal.
    shift <- 100*(logistic_normal_mean(beta*.01,fit$draws[,"sigma"])-.5)
    data.table(uf=fit$levels[g],mediana_log_odds_por_1pp=median(beta*.01),
      q025_log_odds=quantile(beta*.01,.025),q975_log_odds=quantile(beta*.01,.975),
      prob_positivo=mean(beta>0),mediana_mudanca_voto_pp_em_p50=median(shift),
      q025_mudanca_pp=quantile(shift,.025),q975_mudanca_pp=quantile(shift,.975))
  }))
  by_uf[]
}
