# Operação com uma resposta: Lula/válidos T2. Todos os preditores vêm de T1.
# Válidos T1 são pesos fixos das seções pendentes, não uma previsão de comparecimento.
source(file.path(root, "comparecimento_preditor.R"), encoding="UTF-8")

features_voto_t1 <- function(t1,t2=NULL) {
  d <- features(t1,t2)
  d[,taxa_comparecimento:=taxa_comp_t1]
  d[]
}

baseline_voto_t1 <- function(fit,d) {
  stopifnot(all(d$validos>0),all(d$aptos>0))
  p <- logistic_normal_mean(predict_comparecimento(fit,d),mean_parameters(fit)$sigma)
  b <- d[,c(keys,"aptos","x_lula","x_outros","x_validos","taxa_comp_t1","taxa_comparecimento"),with=FALSE]
  b[,aptos:=as.numeric(aptos)]
  b[,`:=`(p_base=p,p_raw=p,validos_base=as.numeric(d$validos),
    pct_lula_t1=100*x_lula,fallback="nenhum")]
  b[]
}

align_voto_t1 <- function(base,inventory) {
  stopifnot(!anyDuplicated(base[,..keys]),!anyDuplicated(inventory[,..keys]))
  cols <- c(keys,"aptos","x_lula","x_outros","x_validos","taxa_comp_t1","taxa_comparecimento",
    "p_base","p_raw","validos_base","pct_lula_t1","fallback")
  base <- copy(base[,..cols])
  base[,aptos:=as.numeric(aptos)]
  b <- merge(inventory[,..keys],base,by=keys,all.x=TRUE)
  missing <- which(is.na(b$p_base))
  if(length(missing)) for(column in setdiff(cols,c(keys,"fallback"))) {
    zones <- base[,.(value_z=mean(get(column))),by=.(uf,zona)]
    states <- base[,.(value_u=mean(get(column))),by=uf]
    fill <- merge(merge(b[missing,..keys],zones,by=c("uf","zona"),all.x=TRUE),states,by="uf",all.x=TRUE)
    fill[,value:=fcoalesce(value_z,value_u)]
    fill <- fill[b[missing,..keys],on=keys]
    set(b,i=missing,j=column,value=as.numeric(fill$value))
  }
  b[missing,fallback:="preditores_e_peso_t1_medias_zona_ou_uf"]
  stopifnot(!anyNA(b),all(b$validos_base>=0),all(b$validos_base<=b$aptos+1e-8))
  b[]
}

validar_observados_voto <- function(observed) {
  stopifnot(!anyDuplicated(observed[,..keys]),!anyNA(observed),
    all(observed$votos_a+observed$votos_b==observed$validos),
    all(observed$validos+observed$brancos+observed$nulos==observed$comparecimento),
    all(observed$comparecimento<=observed$aptos))
  for(col in c("aptos","comparecimento","validos","votos_a","votos_b","brancos","nulos"))
    stopifnot(all(is.finite(observed[[col]])),all(observed[[col]]>=0),
      all(observed[[col]]==floor(observed[[col]])))
  invisible(TRUE)
}

voto_nowcast <- function(fit,base,observed,draws=400L,seed=618335,
                        global_sd=.15,state_sd=.10) {
  stopifnot(draws>=2L,isTRUE(fit$gate$pass),global_sd>=0,state_sd>=0)
  validar_observados_voto(observed)
  extra <- observed[!base,on=keys]
  if(nrow(extra)) base <- align_voto_t1(base,unique(rbind(base[,..keys],extra[,..keys])))
  b <- merge(base,observed[,c(keys,"validos","votos_a","votos_b"),with=FALSE],by=keys,all.x=TRUE)
  b[,apurada:=!is.na(validos)]
  pending <- b[apurada==FALSE]
  X <- X_comparecimento(pending,fit$spec)
  group <- match(pending$uf,fit$levels)
  stopifnot(!anyNA(group))
  params <- mean_parameters(fit)
  mu <- rowSums(X*params$theta[group,,drop=FALSE])
  b[apurada==FALSE,`:=`(a_final=validos_base*logistic_normal_mean(mu,params$sigma),
    b_final=validos_base*(1-logistic_normal_mean(mu,params$sigma)))]
  b[apurada==TRUE,`:=`(a_final=as.numeric(votos_a),b_final=as.numeric(votos_b))]
  obs_uf <- b[,.(a=sum(votos_a,na.rm=TRUE),b=sum(votos_b,na.rm=TRUE)),by=uf]
  # Simulação em TODAS as seções pendentes. Sem amostra de aproximação dos totais.
  # Resíduo por seção + parâmetros históricos + desvios novos de eleição/UF.
  index <- lapply(fit$levels,function(u)which(pending$uf==u))
  blocks <- lapply(index,function(i)X[i,,drop=FALSE])
  weights <- lapply(index,function(i)pending$validos_base[i])
  selected <- unique(round(seq(1,nrow(fit$draws),length.out=min(draws,nrow(fit$draws)))))
  set.seed(seed)
  simulated <- vector("list",draws)
  for(draw in seq_len(draws)) {
    row <- selected[1L+(draw-1L)%%length(selected)]
    delta <- rnorm(1,0,global_sd)+rnorm(length(fit$levels),0,state_sd)
    sigma <- fit$draws[row,"sigma"]
    ud <- copy(obs_uf)
    for(g in seq_along(fit$levels)) {
      i <- index[[g]]
      if(!length(i)) next
      theta <- fit$draws[row,sprintf("theta[%d,%d]",g,seq_len(ncol(X)))]
      rate <- plogis(as.numeric(blocks[[g]]%*%theta)+delta[g]+rnorm(length(i),0,sigma))
      aa <- sum(weights[[g]]*rate)
      bb <- sum(weights[[g]])-aa
      ud[uf==fit$levels[g],`:=`(a=a+aa,b=b+bb)]
    }
    simulated[[draw]] <- ud[,.(draw=draw,uf,votos_a=a,votos_b=b)]
  }
  posterior_uf <- rbindlist(simulated)
  posterior <- posterior_uf[,.(votos_a=sum(votos_a),votos_b=sum(votos_b)),by=draw]
  posterior[,pct_a:=100*votos_a/(votos_a+votos_b)]
  uf <- b[,.(secoes=.N,secoes_apuradas_coletor=sum(apurada),fallback_t1=sum(fallback!="nenhum"),
    votos_a_observados=sum(votos_a,na.rm=TRUE),votos_b_observados=sum(votos_b,na.rm=TRUE),
    votos_a_projetados=sum(a_final),votos_b_projetados=sum(b_final)),by=uf]
  uf[,pct_a_projetado:=100*votos_a_projetados/(votos_a_projetados+votos_b_projetados)]
  a <- sum(b$a_final);bb <- sum(b$b_final)
  total_obs <- sum(b$validos,na.rm=TRUE)
  summary <- data.table(secoes=nrow(b),secoes_apuradas_coletor=sum(b$apurada),
    pct_secoes_coletor=100*mean(b$apurada),fallback_t1=sum(b$fallback!="nenhum"),
    votos_a_observados=sum(b$votos_a,na.rm=TRUE),votos_b_observados=sum(b$votos_b,na.rm=TRUE),
    pct_a_apurado=if(total_obs)100*sum(b$votos_a,na.rm=TRUE)/total_obs else NA_real_,
    votos_a_projetados=a,votos_b_projetados=bb,pct_a_projetado=100*a/(a+bb),
    pct_a_q025=quantile(posterior$pct_a,.025),pct_a_q975=quantile(posterior$pct_a,.975))
  prior <- list(mean=rep(0,length(fit$levels)),
    covariance=matrix(global_sd^2,length(fit$levels),length(fit$levels))+diag(state_sd^2,length(fit$levels)),
    levels=fit$levels,n=rep(0,length(fit$levels)))
  list(resumo=summary,uf=uf,posterior=posterior,posterior_uf=posterior_uf,secoes=b,shifts=list(lula=prior))
}
