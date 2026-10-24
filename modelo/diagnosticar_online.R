args_all <- commandArgs(FALSE)
root <- dirname(normalizePath(sub('^--file=','',args_all[grepl('^--file=',args_all)])[1]))
source(file.path(root,'bayes.R'),encoding='UTF-8')
source(file.path(root,'voto_t1.R'),encoding='UTF-8')
source(file.path(root,'online_conjugado.R'),encoding='UTF-8')
raw <- file.path(root,'..','data','eleicoes_2022_2026','raw')
t1 <- as.data.table(arrow::read_parquet(file.path(raw,'section_votes_2022_T1.parquet')))
t2 <- as.data.table(arrow::read_parquet(file.path(raw,'section_votes_2022_T2.parquet')))
d <- features_voto_t1(t1,t2)[aptos>0&aptos_t2>0&comparecimento>0&comp_t2>0&validos>0&validos_t2>0]
m <- unique(d[,.(uf,cd_mun)])[order(uf,cd_mun)]
m[,teste:=seq_len(.N)%%5L==0L,by=uf]
d <- d[m[teste==TRUE,.(uf,cd_mun)],on=.(uf,cd_mun)]
fit <- readRDS(file.path(root,'output','comparecimento_preditor_20261020','T1','voto_t1','posterior.rds'))
prior <- prior_online(fit)
base <- baseline_voto_t1(fit,d)
mu <- predict_online(prior,base)
e <- d$y_lula-mu
A <- order(base$x_lula)[seq_len(floor(.1*nrow(base)))]
B <- setdiff(seq_len(nrow(base)),A)
s <- online_stats(prior,base[A],d$y_lula[A]);p <- posterior_online(prior,s)
X <- X_comparecimento(base,prior$spec)
q <- length(prior$mean);G <- length(prior$levels)
h <- numeric(q)
for(g in seq_len(G)) {
  i <- B[base$uf[B]==prior$levels[g]]
  if(length(i)) h[prior$map[[g]]] <- h[prior$map[[g]]]+colSums(X[i,,drop=FALSE]*base$validos_base[i])
}
h <- h/sum(base$validos_base[B])
change <- as.numeric(sum(h*(p$mean-prior$mean)))
se_null <- sqrt(as.numeric(t(h)%*%p$covariance%*%s$xx%*%p$covariance%*%h)/prior$sigma^2)
set.seed(618350)
null_changes <- rnorm(20000,0,se_null)
metrics <- data.table(n_total=nrow(d),n_observado=length(A),ufs_observadas=uniqueN(base$uf[A]),
  ufs_total=uniqueN(base$uf),max_x_observado=max(base$x_lula[A]),
  media_residuo_observado=mean(e[A]),media_residuo_pendente=mean(e[B]),
  mudanca_media_logit_pendentes=change,dp_mudanca_sob_modelo_correto=se_null,
  quantil_025_sob_modelo_correto=qnorm(.025)*se_null,quantil_975_sob_modelo_correto=qnorm(.975)*se_null,
  z_desvio_do_controle=change/se_null)
print(metrics)
# Decomposição linear da mudança média, sem converter em prognóstico eleitoral.
labels <- c(rep('interceptos_UF',G),rep('inclinacoes_preditor_T1_UF',G),'comparecimento_T1','outros_T1','validos_T1')
decomposition <- data.table(componente=labels,mudanca_logit=h*(p$mean-prior$mean))[,.(mudanca_logit=sum(mudanca_logit)),by=componente]
print(decomposition)
# Resíduo por faixa de preditor; discrepância na média condicional em escala logit.
res <- data.table(x=base$x_lula,uf=base$uf,residuo=e)
res[,decile:=pmin(10L,ceiling(frank(x,ties.method='average')/.N*10))]
bins <- res[,.(n=.N,min_x=min(x),max_x=max(x),media_residuo=mean(residuo),dp_residuo=sd(residuo)),by=decile]
setorder(bins,decile)
print(bins)
# Uma projeção linear descritiva em TODO o conjunto reservado testa a família,
# sem atribuir falta de ajuste somente à precisão dos coeficientes históricos.
Z <- matrix(0,nrow(d),q)
for(g in seq_len(G)) {
  i <- which(base$uf==prior$levels[g])
  if(length(i)) Z[i,prior$map[[g]]] <- X[i,,drop=FALSE]
}
oracle <- lm.fit(Z,d$y_lula,tol=1e-10)
res[,residuo_ajuste_linear_completo:=oracle$residuals]
oracle_bins <- res[,.(media_residuo_linear=mean(residuo_ajuste_linear_completo)),by=decile]
setorder(oracle_bins,decile)
print(oracle_bins)
# Sensibilidade: sem compartilhar os desvios novos de intercepto/inclinação entre UFs.
local <- prior_online(fit,alpha_global_sd=0,voto_global_sd=0)
pl <- posterior_online(local,s)
sensitivity <- data.table(prior=c('desvios_globais_e_UF','somente_desvios_UF'),
  mudanca_media_logit_pendentes=c(change,sum(h*(pl$mean-local$mean))))
print(sensitivity)

# Efeito da restrição de suporte na identificação de nível e inclinação.
h_obs <- numeric(q)
for(g in seq_len(G)) {
  i <- A[base$uf[A]==prior$levels[g]]
  if(length(i)) h_obs[prior$map[[g]]] <- h_obs[prior$map[[g]]]+colSums(X[i,,drop=FALSE]*base$validos_base[i])
}
h_obs <- h_obs/sum(base$validos_base[A])
observed_decomp <- data.table(componente=labels,mudanca_logit=h_obs*(p$mean-prior$mean))[,.(mudanca_logit=sum(mudanca_logit)),by=componente]
# Controle sem erro e sem mudança: seleção em X sozinha não gera correção.
exact <- posterior_online(prior,online_stats(prior,base[A],mu[A]))
stopifnot(max(abs(exact$mean-prior$mean))<1e-8)
# A distribuição nula acima é a resposta analítica a erros iid normais no mesmo X;
# não é teste calibrado para dependência espacial, heteroscedasticidade ou erro de treino.
out <- file.path(root,'output','online_conjugado_20261020','diagnostico_especificacao')
dir.create(out,recursive=TRUE,showWarnings=FALSE)
fwrite(metrics,file.path(out,'diagnostico.csv'))
fwrite(decomposition,file.path(out,'decomposicao_pendentes.csv'))
fwrite(observed_decomp,file.path(out,'decomposicao_observados.csv'))
fwrite(merge(bins,oracle_bins,by='decile'),file.path(out,'residuos_faixas.csv'))
fwrite(sensitivity,file.path(out,'sensibilidade_pooling.csv'))
jsonlite::write_json(list(
  interpretation='Covariate-based arrival is conditionally ignorable under a correct identified model; this diagnostic points to conditional-mean misspecification and support/regularization interaction',
  not_identified='This test does not establish which added term resolves the conditional-mean misspecification',
  control='Noise-free response generated from the same model yields no coefficient update under the same selected X',
  null_assumptions='Historical posterior mean treated as truth, fixed residual sigma, iid normal errors; not an empirical p value',
  operation='No model fit, active configuration, collector or scheduled task changed'),
  file.path(out,'interpretacao.json'),pretty=TRUE,auto_unbox=TRUE)
print(observed_decomp)
