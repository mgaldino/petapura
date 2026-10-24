# Protótipo candidato: atualização normal conjugada, sem MCMC de 2026.
# Não é carregado pela operação ativa. Q é uma hipótese de mudança entre anos.
# Posterior histórica aproximada pelos momentos conjuntos; sigma é fixado.
.online_scales_path <- file.path(dirname(normalizePath(sys.frame(1)$ofile)),
                                "escalas_online_v2.json")

nomes_escalas_online <- c("alpha_global_sd","alpha_uf_sd","voto_global_sd",
                         "voto_uf_sd","comp_sd","outros_sd","validos_sd")

validar_escalas_online <- function(scales) {
  if(!is.numeric(scales)||length(scales)!=length(nomes_escalas_online)||
     !setequal(names(scales),nomes_escalas_online)||anyDuplicated(names(scales))||
     any(!is.finite(scales))||any(scales<0))
    stop("Escalas devem ser sete desvios padrao nomeados, finitos e nao negativos")
  scales[nomes_escalas_online]
}

ler_escalas_online <- function(arquivo=.online_scales_path,perfil="central") {
  config <- jsonlite::read_json(arquivo,simplifyVector=TRUE)
  multiplier <- config$perfis[[perfil]]
  if(is.null(multiplier)||!is.numeric(multiplier)||length(multiplier)!=1L||
     !is.finite(multiplier)||multiplier<=0) stop("Perfil de escalas invalido: ",perfil)
  if(!identical(config$media_dos_desvios,0L)&&!identical(config$media_dos_desvios,0))
    stop("A configuracao deve ter media zero para os desvios")
  list(scales=validar_escalas_online(unlist(config$desvios_padrao))*multiplier,
       version=config$versao,profile=perfil,multiplier=multiplier,
       sha256=digest::digest(file=arquivo,algo="sha256"))
}

covariancia_mudanca_online <- function(G,scales) {
  if(length(G)!=1L||!is.finite(G)||G<1||G!=as.integer(G)) stop("Numero de UFs invalido")
  scales <- validar_escalas_online(scales)
  Q <- matrix(0,2L*G+3L,2L*G+3L)
  Q[seq_len(G),seq_len(G)] <- scales["alpha_global_sd"]^2+diag(scales["alpha_uf_sd"]^2,G)
  j <- G+seq_len(G)
  Q[j,j] <- scales["voto_global_sd"]^2+diag(scales["voto_uf_sd"]^2,G)
  diag(Q)[2L*G+1:3] <- scales[c("comp_sd","outros_sd","validos_sd")]^2
  Q
}

prior_online <- function(fit,alpha_global_sd=NULL,alpha_uf_sd=NULL,
                         voto_global_sd=NULL,voto_uf_sd=NULL,
                         comp_sd=NULL,outros_sd=NULL,validos_sd=NULL,
                         perfil="central",arquivo_escalas=.online_scales_path) {
  stopifnot(identical(fit$structure,"voto_t1"),isTRUE(fit$gate$pass),
    identical(fit$spec$vars,c("x_lula","taxa_comparecimento","x_outros","x_validos")))
  config <- ler_escalas_online(arquivo_escalas,perfil)
  overrides <- list(alpha_global_sd=alpha_global_sd,alpha_uf_sd=alpha_uf_sd,
    voto_global_sd=voto_global_sd,voto_uf_sd=voto_uf_sd,comp_sd=comp_sd,
    outros_sd=outros_sd,validos_sd=validos_sd)
  overrides <- overrides[!vapply(overrides,is.null,logical(1))]
  if(any(!vapply(overrides,function(x)is.numeric(x)&&length(x)==1L,logical(1))))
    stop("Cada desvio padrao sobrescrito deve ser um numero")
  scales <- config$scales
  scales[names(overrides)] <- unlist(overrides)
  scales <- validar_escalas_online(scales)
  G <- length(fit$levels);q <- 2L*G+3L
  map <- lapply(seq_len(G),function(g)c(g,G+g,2L*G+1:3))
  # Parâmetros efetivos da regressão: alpha_UF, beta_voto_UF e três comuns.
  names <- c(paste0("alpha_",fit$levels),paste0("voto_",fit$levels),
    "comparecimento","outros","validos")
  historical <- cbind(fit$draws[,sprintf("theta[%d,1]",seq_len(G)),drop=FALSE],
    fit$draws[,sprintf("theta[%d,2]",seq_len(G)),drop=FALSE],
    fit$draws[,sprintf("theta[1,%d]",3:5),drop=FALSE])
  colnames(historical) <- names
  m <- colMeans(historical);S <- cov(historical)
  Q <- covariancia_mudanca_online(G,scales)
  dimnames(Q) <- list(names,names)
  V <- S+Q
  precision <- chol2inv(chol(V))
  list(mean=m,covariance=V,historical_covariance=S,drift_covariance=Q,
    precision=precision,sigma=mean(fit$draws[,"sigma"]),spec=fit$spec,
    levels=fit$levels,map=map,names=names,
    assumptions=list(historical_posterior="joint normal moment approximation",
      residual_variance="fixed at historical posterior mean sigma squared",
      drift_scales=scales,drift_config_version=config$version,
      drift_profile=config$profile,drift_config_sha256=config$sha256,
      drift_overrides=names(overrides),
      drift_application="once before the new election; never per batch"))
}

empty_online_stats <- function(prior) {
  q <- length(prior$mean)
  list(xx=matrix(0,q,q),xy=numeric(q),yy=0,n=0L)
}

online_stats <- function(prior,d,y) {
  stopifnot(nrow(d)==length(y),all(is.finite(y)))
  X <- X_comparecimento(d,prior$spec)
  group <- match(d$uf,prior$levels)
  stopifnot(!anyNA(group))
  s <- empty_online_stats(prior)
  for(g in seq_along(prior$levels)) {
    take <- which(group==g)
    if(!length(take)) next
    j <- prior$map[[g]]
    s$xx[j,j] <- s$xx[j,j]+crossprod(X[take,,drop=FALSE])
    s$xy[j] <- s$xy[j]+as.numeric(crossprod(X[take,,drop=FALSE],y[take]))
  }
  s$yy <- sum(y^2);s$n <- length(y)
  s
}

add_online_stats <- function(a,b) {
  list(xx=a$xx+b$xx,xy=a$xy+b$xy,yy=a$yy+b$yy,n=a$n+b$n)
}

posterior_online <- function(prior,stats) {
  # Exata para esta prior gaussiana e sigma fixo. Nenhuma otimização ou MCMC.
  information <- stats$xx/prior$sigma^2
  covariance <- chol2inv(chol(prior$precision+information))
  # Forma em desvios reduz cancelamento numérico na contribuição da prior.
  mean <- prior$mean+as.numeric(covariance%*%
    ((stats$xy-stats$xx%*%prior$mean)/prior$sigma^2))
  names(mean) <- prior$names
  list(mean=mean,covariance=covariance,n=stats$n,sigma=prior$sigma)
}

snapshot_online <- function(prior,base,observed) {
  # Recalcula o snapshot contra a PRIOR ORIGINAL: BUs já vistos não se repetem.
  # Correções, remoções e mudanças de hash são refletidas no snapshot completo.
  validar_observados_voto(observed)
  z <- merge(observed,base[,c(keys,prior$spec$vars),with=FALSE],by=keys,all.x=TRUE)
  z <- z[validos>0]
  posterior_online(prior,online_stats(prior,z,safe_logit(z$votos_a,z$validos)))
}

predict_online <- function(prior,d,coefficients=prior$mean) {
  X <- X_comparecimento(d,prior$spec)
  group <- match(d$uf,prior$levels)
  stopifnot(!anyNA(group))
  mu <- numeric(nrow(d))
  for(g in seq_along(prior$levels)) {
    take <- which(group==g)
    if(length(take)) mu[take] <- as.numeric(X[take,,drop=FALSE]%*%coefficients[prior$map[[g]]])
  }
  mu
}

sample_online <- function(posterior,n=400L,seed=618340) {
  set.seed(seed)
  q <- length(posterior$mean)
  # Coeficientes são sorteados conjuntamente: mantém covariâncias posteriores.
  sweep(matrix(rnorm(n*q),n,q)%*%chol(posterior$covariance),2,posterior$mean,"+")
}

coefficient_online <- function(prior,posterior) {
  j <- match("comparecimento",prior$names)
  scale <- prior$spec$scale["taxa_comparecimento"]
  mean <- posterior$mean[j]*.01/scale
  sd <- sqrt(posterior$covariance[j,j])*.01/scale
  data.table(n=posterior$n,media_log_odds_por_1pp=mean,
    q025_log_odds=mean-qnorm(.975)*sd,q975_log_odds=mean+qnorm(.975)*sd,
    prob_positivo=pnorm(mean/sd),dp_log_odds=sd)
}
