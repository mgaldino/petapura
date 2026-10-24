# Funções comuns aos testes integrados: verdades SINTÉTICAS e ordens de chegada.
# Não produzem previsões; usam a população congelada e a prior do estado inicial.

# Componentes de 2022 usados no cenário realista: os mesmos de componentes_locais_v1.json.
componentes_2022_teste <- function(root)estimar_componentes_2022(root)

preditor_linear_teste <- function(prior,X,group,theta) {
  mu <- numeric(nrow(X))
  for(g in seq_along(prior$levels)) {
    i <- which(group==g)
    if(length(i))mu[i] <- as.numeric(X[i,,drop=FALSE]%*%theta[prior$map[[g]]])
  }
  mu
}

# cenario "correto": coeficientes da prior, resíduo iid com o sigma do modelo e
# válidos T2 iguais aos pesos T1. "realista": mesma variância residual total,
# parte comum ao município, e razão de válidos T2/T1 com componentes de 2022.
gerar_verdade_teste <- function(state,comp,cenario=c("correto","realista"),seed,zero_validos=0L) {
  cenario <- match.arg(cenario)
  prior <- state$prior;pop <- state$population
  X <- .analise_componentes$X_comparecimento(pop,prior$spec)
  group <- match(pop$uf,prior$levels)
  theta <- .analise_componentes$sample_online(list(mean=prior$mean,covariance=prior$covariance),n=1L,seed=seed)[1,]
  mun <- pop[,.(uf,cd_mun)][,id:=.GRP,by=.(uf,cd_mun)]$id
  set.seed(seed+1L)
  mu <- preditor_linear_teste(prior,X,group,theta)
  if(cenario=="correto") {
    shock <- rep(0,nrow(pop));noise <- rnorm(nrow(pop),0,prior$sigma)
    validos <- pmax(1,round(pop$validos_base))
  } else {
    tau2 <- comp$residuo[["entre"]]
    shock <- rnorm(max(mun),0,sqrt(tau2))[mun]
    noise <- rnorm(nrow(pop),0,sqrt(prior$sigma^2-tau2))
    rho <- comp$rho_uf[pop,on="uf"]$rho
    ratio <- exp(log(rho)+rnorm(max(mun),0,sqrt(comp$razao[["entre"]]))[mun]+
      rnorm(nrow(pop),0,sqrt(comp$razao[["dentro"]])))
    validos <- pmax(1,round(pop$validos_base*ratio))
  }
  share <- plogis(mu+shock+noise)
  truth <- pop[,..chaves_analise]
  truth[,`:=`(validos=validos,votos_a=round(validos*share))]
  if(zero_validos>0) {
    # Seções com todos os votos brancos ou nulos: apuradas, sem informação para o logit.
    z <- sample.int(nrow(truth),zero_validos)
    truth[z,`:=`(validos=0,votos_a=0)]
  }
  truth[,`:=`(votos_b=validos-votos_a,brancos=round(.02*validos)+fifelse(validos==0,30,0),
    nulos=round(.03*validos)+fifelse(validos==0,20,0))]
  truth[,comparecimento:=validos+brancos+nulos]
  truth[,aptos:=pmax(round(pop$aptos),comparecimento)]
  truth[,`:=`(residuo=shock+noise,municipio=mun,fallback=pop$fallback,x_lula=pop$x_lula)]
  attr(truth,"theta") <- theta
  attr(truth,"cenario") <- cenario
  truth
}

# Permutação das seções segundo a ordem de chegada.
ordem_chegada_teste <- function(truth,ordem,seed) {
  set.seed(seed)
  n <- nrow(truth)
  switch(ordem,
    aleatoria=sample.int(n),
    ufs_velocidades={
      speed <- setNames(runif(uniqueN(truth$uf),.5,2),sort(unique(truth$uf)))
      order(runif(n)/speed[truth$uf])
    },
    municipios_blocos={
      m <- sample.int(max(truth$municipio))
      order(m[truth$municipio],runif(n))
    },
    voto_t1_crescente=order(truth$x_lula+runif(n,0,1e-6)),
    adversa_residuo=order(truth$residuo),
    stop("Ordem desconhecida: ",ordem))
}

pct_verdade_teste <- function(truth,rows=seq_len(nrow(truth)))100*sum(truth$votos_a[rows])/sum(truth$validos[rows])
