args_all <- commandArgs(FALSE)
root <- dirname(normalizePath(sub("^--file=","",args_all[grepl("^--file=",args_all)])[1]))
source(file.path(root,"bayes.R"),encoding="UTF-8")
source(file.path(root,"online_conjugado.R"),encoding="UTF-8")
out <- file.path(root,"output","escalas_online_v2_20261020")
dir.create(out,recursive=TRUE,showWarnings=FALSE)
checks <- list()
check <- function(name,yes) {
  checks[[length(checks)+1L]] <<- data.table(verificacao=name,passou=isTRUE(yes))
  if(!isTRUE(yes))stop(name)
}
close <- function(a,b,tol=1e-9)isTRUE(all.equal(unname(a),unname(b),tolerance=tol))
fails <- function(expr)inherits(tryCatch(force(expr),error=function(e)e),"error")
config <- ler_escalas_online()
expected <- c(alpha_global_sd=.10,alpha_uf_sd=.05,voto_global_sd=.03,voto_uf_sd=.02,
              comp_sd=.02,outros_sd=.03,validos_sd=.03)
check("Configuracao central coincide com valores versionados",close(config$scales,expected))
check("Perfil restrito reduz DP a metade",close(ler_escalas_online(perfil="restrito")$scales,expected/2))
check("Perfil amplo dobra DP",close(ler_escalas_online(perfil="amplo")$scales,expected*2))
check("Perfil desconhecido e rejeitado",fails(ler_escalas_online(perfil="inexistente")))
check("Escala negativa e rejeitada",fails(validar_escalas_online(replace(expected,1,-.1))))
check("Escala nao finita e rejeitada",fails(validar_escalas_online(replace(expected,1,NA_real_))))
check("Nome ausente e rejeitado",fails(validar_escalas_online(expected[-1])))
check("Nome duplicado e rejeitado",fails(validar_escalas_online(setNames(expected,rep("x",7)))))
check("Numero de grupos invalido e rejeitado",fails(covariancia_mudanca_online(0,expected)))
Q <- covariancia_mudanca_online(28L,expected)
check("Q tem 59 por 59 dimensoes e e simetrica",identical(dim(Q),c(59L,59L))&&close(Q,t(Q)))
check("Q central e definida positiva",min(eigen(Q,symmetric=TRUE,only.values=TRUE)$values)>0)
check("Variancia de intercepto soma nacional e UF",close(Q[1,1],.10^2+.05^2))
check("Covariancia entre interceptos e nacional",close(Q[1,2],.10^2))
check("Correlacao de mudanca de intercepto e 0,8",close(cov2cor(Q)[1,2],.8))
check("Correlacao de mudanca de inclinacao e 9/13",close(cov2cor(Q)[29,30],9/13))
check("Inclinação de comparecimento e comum com DP 0,02",close(Q[57,57],.02^2))
check("Sem correlacao adicional entre tipos de coeficiente",all(Q[1:28,29:59]==0)&&all(Q[29:56,57:59]==0))
check("Dobrar DP quadruplica Q",close(covariancia_mudanca_online(28L,2*expected),4*Q))
check("Q zero e permitido para sensibilidade",all(covariancia_mudanca_online(28L,0*expected)==0))
fit <- readRDS(file.path(root,"data","processed","voto_t1_fits.rds"))$lula
p <- prior_online(fit)
check("Default usa perfil central versionado",identical(p$assumptions$drift_profile,"central")&&
  identical(p$assumptions$drift_config_sha256,config$sha256)&&close(p$drift_covariance,Q)&&
  identical(config$version,"mudanca_entre_eleicoes_v2_2026-10-20"))
old <- prior_online(fit,arquivo_escalas=file.path(root,"escalas_online_v1.json"))
check("Configuracao V1 permanece identica e legivel",identical(old$assumptions$drift_config_sha256,
  "5f4a15e5477950ba7f7171a6a80296f5bb3d479187477c6f0dd1e174f3fd0f9e"))
check("V2 reduz Q em todas as direcoes relativamente a V1",
  min(eigen(old$drift_covariance-Q,symmetric=TRUE,only.values=TRUE)$values)>0)
check("Covariancia historica e preservada integralmente",close(p$covariance-p$drift_covariance,p$historical_covariance))
zero <- prior_online(fit,alpha_global_sd=0,alpha_uf_sd=0,voto_global_sd=0,
  voto_uf_sd=0,comp_sd=0,outros_sd=0,validos_sd=0)
check("API anterior de sobrescrita explicita permanece valida",all(zero$drift_covariance==0)&&
  length(zero$assumptions$drift_overrides)==7L)
check("Sobrescrita vetorial e rejeitada",fails(prior_online(fit,comp_sd=c(.05,.1))))
broad <- prior_online(fit,perfil="amplo")
narrow <- prior_online(fit,perfil="restrito")
check("Perfis mantem a mesma media historica",identical(p$mean,broad$mean)&&identical(p$mean,narrow$mean))
post0 <- posterior_online(p,empty_online_stats(p))
check("Zero observacoes preserva a prior com Q",close(post0$mean,p$mean)&&close(post0$covariance,p$covariance))
s <- empty_online_stats(p)
j <- match("comparecimento",p$names)
s$xx[j,j] <- 100
s$xy[j] <- 100*(p$mean[j]+.05)
s$n <- 100L
a <- posterior_online(narrow,s)
b <- posterior_online(p,s)
c <- posterior_online(broad,s)
check("Margem maior aumenta resposta ao mesmo sinal informativo",a$mean[j]<b$mean[j]&&b$mean[j]<c$mean[j])
p1 <- p
p1$mean <- b$mean
p1$covariance <- b$covariance
p1$precision <- chol2inv(chol(b$covariance))
seq_post <- posterior_online(p1,s)
one_post <- posterior_online(p,add_online_stats(s,s))
check("Atualizar dois lotes nao reaplica Q",close(seq_post$mean,one_post$mean)&&close(seq_post$covariance,one_post$covariance))
fwrite(rbindlist(checks),file.path(out,"checks.csv"))
jsonlite::write_json(list(status="passou",tests_passed=length(checks),
  config_version=config$version,config_sha256=config$sha256,
  scope="covariance construction, source-relative config, sensitivity and conjugate algebra",
  no_live_collector_changed=TRUE),file.path(out,"verificacao.json"),pretty=TRUE,auto_unbox=TRUE)
print(rbindlist(checks))
