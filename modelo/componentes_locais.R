# Correção 2 dos testes integrados: estrutura local que o protótipo tratava como ausente.
# (a) Voto: logit = x'theta + u_municipio + e, com u ~ N(0, tau2) e e ~ N(0, sigma2 - tau2).
#     A variância residual total continua a histórica; parte dela passa a ser comum ao município.
# (b) Válidos T2 das pendentes: válidos T1 * exp(lambda_UF + nu_municipio + eta_secao).
# Ambos são aprendidos com os BUs por fórmulas normais fechadas, sem MCMC.
# (c) Atualização gradual: com fração f dos válidos T1 apurada, a previsão das pendentes é a
#     mistura (1 - w) * modelo inicial + w * modelo atualizado, w = min(1, f / f_plena)^expoente.
.componentes_locais_path <- file.path(.previsao_dir,"componentes_locais_v2.json")

ler_componentes_locais <- function(arquivo=.componentes_locais_path) {
  cfg <- jsonlite::read_json(arquivo,simplifyVector=TRUE)
  p <- c(tau2=cfg$voto$tau2_municipio,s0=cfg$validos$dp_nacional,sg=cfg$validos$dp_uf,
    var_m=cfg$validos$var_municipio,var_i=cfg$validos$var_secao)
  exigir_analise(length(p)==5L&&all(is.finite(p))&&all(p>=0),"Componentes locais inválidos")
  # Sem bloco de atualização gradual (v1), a atualização tem peso pleno desde o primeiro BU.
  fp <- if(is.null(cfg$atualizacao))0 else cfg$atualizacao$fracao_plena
  ex <- if(is.null(cfg$atualizacao))1 else cfg$atualizacao$expoente
  exigir_analise(length(fp)==1L&&is.finite(fp)&&fp>=0&&fp<=1&&length(ex)==1L&&is.finite(ex)&&ex>0,
    "Parâmetros de atualização gradual inválidos")
  list(versao=cfg$versao,tau2=p[["tau2"]],s0=p[["s0"]],sg=p[["sg"]],var_m=p[["var_m"]],var_i=p[["var_i"]],
    fracao_plena=fp,expoente=ex,sha256=hash_arquivo_analise(arquivo),conteudo=cfg)
}

# Componentes locais iguais a zero reproduzem o protótipo: resíduos independentes e pesos T1 fixos.
componentes_locais_zero <- function()list(versao="sem_componentes_locais",tau2=0,s0=0,sg=0,var_m=0,var_i=0,
  fracao_plena=0,expoente=1,sha256="zero",conteudo=NULL)

peso_atualizacao <- function(fracao,local) {
  fp <- if(is.null(local$fracao_plena))0 else local$fracao_plena
  if(fp<=0)return(1)
  min(1,max(0,fracao)/fp)^local$expoente
}

# Quantis da proporção de uma seção pendente sob a mistura de dois componentes normais no logit.
# s é a proporção de votos; o logit modela (s*W + 0,5)/(W + 1), com W os válidos esperados.
quantis_mistura <- function(prob,peso,mu0,sd0,w0,mu1,sd1,w1,iter=50L) {
  cdf <- function(s,mu,sd,w)pnorm((qlogis((s*w+.5)/(w+1))-mu)/sd)
  lo <- numeric(length(mu0));hi <- rep(1,length(mu0))
  for(k in seq_len(iter)) {
    mid <- (lo+hi)/2
    up <- (1-peso)*cdf(mid,mu0,sd0,w0)+peso*cdf(mid,mu1,sd1,w1)<prob
    lo[up] <- mid[up];hi[!up] <- mid[!up]
  }
  (lo+hi)/2
}

municipios_populacao <- function(population)population[,.(uf,cd_mun)][,mun:=.GRP,by=.(uf,cd_mun)]$mun

# Estatísticas e posterior desde a prior ORIGINAL, com o conjunto completo de BUs ativos.
estado_local_previsao <- function(state,observed,local) {
  prior <- state$prior;pop <- state$population
  sigma2 <- prior$sigma^2
  exigir_analise(local$tau2<sigma2,"Variância municipal deve ser menor que a residual total")
  s2w <- sigma2-local$tau2
  row <- pop[observed,on=chaves_analise,which=TRUE]
  exigir_analise(!anyNA(row),"BU fora da população congelada")
  mun <- municipios_populacao(pop)
  q <- length(prior$mean);G <- length(prior$levels)
  # --- Voto: mínimos quadrados generalizados com bloco municipal de correlação.
  take <- which(observed$validos>0)
  r <- row[take]
  X <- .analise_componentes$X_comparecimento(pop[r],prior$spec)
  y <- .analise_componentes$safe_logit(observed$votos_a[take],observed$validos[take])
  g <- match(pop$uf[r],prior$levels);m <- mun[r]
  agg <- data.table(m=m,g=g,y=y,X)[,c(list(n=.N,Y=sum(y)),lapply(.SD,sum)),by=.(m,g),.SDcols=colnames(X)]
  data.table::setorder(agg,m)
  S <- as.matrix(agg[,colnames(X),with=FALSE])
  agg[,cm:=local$tau2/(s2w+n*local$tau2)]
  A <- matrix(0,q,q);b <- numeric(q)
  for(k in seq_len(G)) {
    i <- which(g==k);a <- which(agg$g==k);j <- prior$map[[k]]
    if(!length(i))next
    Si <- S[a,,drop=FALSE]
    # Inversa de sigma2w*I + tau2*11' por município (Sherman-Morrison). Os três
    # coeficientes nacionais aparecem em todos os blocos de UF: acumular.
    A[j,j] <- A[j,j]+crossprod(X[i,,drop=FALSE])-crossprod(Si*sqrt(agg$cm[a]))
    b[j] <- b[j]+as.numeric(crossprod(X[i,,drop=FALSE],y[i]))-as.numeric(crossprod(Si,agg$cm[a]*agg$Y[a]))
  }
  A <- A/s2w;b <- b/s2w
  covariance <- chol2inv(chol(prior$precision+A))
  mean <- prior$mean+as.numeric(covariance%*%(b-A%*%prior$mean))
  names(mean) <- prior$names
  dimnames(covariance) <- dimnames(prior$covariance)
  posterior <- list(mean=mean,covariance=covariance,n=length(y),sigma=prior$sigma)
  # u_m | theta, y ~ N(c_m (Y_m - s_m'theta), tau2 s2w / (s2w + n_m tau2)).
  agg[,var_u:=local$tau2*s2w/(s2w+n*local$tau2)]
  voto <- list(mun=agg$m,g=agg$g,n=agg$n,Y=agg$Y,S=unname(S),c=agg$cm,var_u=agg$var_u)
  # --- Válidos: log(V_T2 / V_T1) dos BUs com peso T1 observado (sem aproximação de preditores).
  ok <- which(observed$validos>0&pop$fallback[row]=="nenhum")
  wl <- data.table(m=mun[row[ok]],g=match(pop$uf[row[ok]],prior$levels),
    l=log(observed$validos[ok]/pop$validos_base[row[ok]]))[,.(n=.N,lbar=mean(l)),by=.(m,g)]
  data.table::setorder(wl,m)
  L0 <- matrix(local$s0^2,G,G)+diag(local$sg^2,G)
  if(!nrow(wl)) {
    # Sem BUs com peso T1 observado, vale a prior da razão.
    cov_l <- L0;mu_l <- numeric(G)
    wl[,`:=`(k=numeric(),var_nu=numeric())]
  } else if(local$var_m+local$var_i>0) {
    wl[,d:=local$var_m+local$var_i/n]
    D <- numeric(G);h <- numeric(G)
    info <- wl[,.(D=sum(1/d),h=sum(lbar/d)),by=g]
    D[info$g] <- info$D;h[info$g] <- info$h
    # Posterior de lambda sem inverter L0: (L0^-1 + D)^-1 = (I + L0 D)^-1 L0.
    cov_l <- solve(diag(G)+L0%*%diag(D,G),L0);cov_l <- (cov_l+t(cov_l))/2
    mu_l <- as.numeric(cov_l%*%h)
    wl[,`:=`(k=if(local$var_m==0)0 else if(local$var_i==0)1 else (n/local$var_i)/(1/local$var_m+n/local$var_i),
      var_nu=if(local$var_m==0)0 else if(local$var_i==0)0 else 1/(1/local$var_m+n/local$var_i))]
  } else {
    # Sem variância municipal nem por seção, a razão é a da UF: pesos T1 fixos quando s0 = sg = 0.
    exigir_analise(local$s0==0&&local$sg==0,"Razão de válidos sem variância local exige dp nacional e de UF iguais a zero")
    cov_l <- L0;mu_l <- numeric(G)
    wl[,`:=`(k=rep(0,.N),var_nu=rep(0,.N))]
  }
  validos <- list(mun=wl$m,g=wl$g,n=wl$n,lbar=wl$lbar,k=wl$k,var_nu=wl$var_nu,mu=mu_l,cov=cov_l)
  list(posterior=posterior,A=A,b=b,voto=voto,validos=validos,
    local=local[intersect(c("versao","tau2","s0","sg","var_m","var_i","fracao_plena","expoente","sha256"),names(local))],
    s2w=s2w,municipios=max(mun))
}

# Média e variância preditivas de x'theta + u_m e do log da razão de válidos, por seção.
preditiva_local <- function(state,est,X,group,mun_rows) {
  prior <- state$prior;post <- est$posterior;v <- est$voto;w <- est$validos;loc <- est$local
  n <- nrow(X);mu <- var_t <- cross <- numeric(n)
  for(k in seq_along(prior$levels)) {
    i <- which(group==k);if(!length(i))next
    j <- prior$map[[k]];Xi <- X[i,,drop=FALSE]
    mu[i] <- as.numeric(Xi%*%post$mean[j])
    var_t[i] <- rowSums((Xi%*%post$covariance[j,j,drop=FALSE])*Xi)
  }
  Eu <- numeric(n);var_u <- rep(loc$tau2,n)
  hit <- match(mun_rows,v$mun)
  seen <- which(!is.na(hit))
  if(length(seen)) {
    h <- hit[seen];k <- v$g[h];
    smt <- numeric(length(seen));sVs <- numeric(length(seen));xVs <- numeric(length(seen))
    for(gg in unique(k)) {
      a <- which(k==gg);j <- prior$map[[gg]];Vg <- post$covariance[j,j,drop=FALSE]
      Sm <- v$S[h[a],,drop=FALSE];Vs <- Sm%*%Vg
      smt[a] <- as.numeric(Sm%*%post$mean[j]);sVs[a] <- rowSums(Vs*Sm)
      xVs[a] <- rowSums(X[seen[a],,drop=FALSE]*Vs)
    }
    cc <- v$c[h]
    Eu[seen] <- cc*(v$Y[h]-smt)
    # Var(x'theta+u) = x'Vx + c^2 s'Vs - 2c x'Vs + Var(u|theta,y).
    var_u[seen] <- cc^2*sVs-2*cc*xVs+v$var_u[h]
  }
  sd_z <- sqrt(pmax(var_t+var_u,0)+est$s2w)
  hw <- match(mun_rows,w$mun);El <- w$mu[group];Vl <- diag(w$cov)[group]+loc$var_m
  sw <- which(!is.na(hw))
  if(length(sw)) {
    kk <- w$k[hw[sw]]
    El[sw] <- (1-kk)*w$mu[group[sw]]+kk*w$lbar[hw[sw]]
    Vl[sw] <- (1-kk)^2*diag(w$cov)[group[sw]]+w$var_nu[hw[sw]]
  }
  list(mu_z=mu+Eu,sd_z=sd_z,log_ratio_mean=El,log_ratio_var=Vl+loc$var_i)
}

# Item 3: (votos + 0,5) / (válidos + 1) é a proporção que o logit modela; inverter para votos.
votos_da_proporcao <- function(p,validos)pmin(validos,pmax(0,p*(validos+1)-.5))

sortear_lambda <- function(w,n) {
  e <- eigen(w$cov,symmetric=TRUE)
  root <- e$vectors%*%diag(sqrt(pmax(e$values,0)),length(e$values))
  sweep(matrix(rnorm(n*length(w$mu)),n)%*%t(root),2,w$mu,"+")
}

# Estimador de momentos de um efeito aleatório de grupo (ANOVA de um fator).
componente_grupo_local <- function(d,v,groups) {
  a <- d[,.(n=.N,m=mean(get(v)),ss=sum((get(v)-mean(get(v)))^2)),by=groups]
  N <- sum(a$n);k <- nrow(a);within <- sum(a$ss)/(N-k)
  grand <- weighted.mean(a$m,a$n);between <- sum(a$n*(a$m-grand)^2)/(k-1)
  n0 <- (N-sum(a$n^2)/N)/(k-1)
  c(total=var(d[[v]]),entre=max(0,(between-within)/n0),dentro=within,grupos=k)
}

# Componentes de 2022: resíduo do ajuste completo por município e razão de válidos T2/T1.
estimar_componentes_2022 <- function(root) {
  raw <- file.path(root,"..","data","eleicoes_2022_2026","raw")
  read <- function(f)data.table::as.data.table(arrow::read_parquet(file.path(raw,f)))
  t1 <- read("section_votes_2022_T1.parquet");t2 <- read("section_votes_2022_T2.parquet")
  d <- .analise_componentes$features_voto_t1(t1,t2)[aptos>0&aptos_t2>0&comparecimento>0&comp_t2>0&validos>0&validos_t2>0]
  fit <- readRDS(file.path(root,"data","processed","voto_t1_fits.rds"))$lula
  d[,residuo:=y_lula-.analise_componentes$predict_comparecimento(fit,d)]
  r <- componente_grupo_local(d,"residuo",c("uf","cd_mun"))
  rho <- d[,.(rho=sum(validos_t2)/sum(validos)),keyby=uf]
  d <- merge(d,rho,by="uf");d[,log_razao:=log(validos_t2/validos)-log(rho)]
  w <- componente_grupo_local(d,"log_razao",c("uf","cd_mun"))
  list(sigma2_modelo=mean(fit$draws[,"sigma"])^2,residuo=r,razao=w,rho_uf=rho,secoes=nrow(d),
    razao_nacional=sum(d$validos_t2)/sum(d$validos),dp_log_rho_uf=sd(log(rho$rho)))
}
