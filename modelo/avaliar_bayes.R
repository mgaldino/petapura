args_all <- commandArgs(FALSE)
root <- dirname(normalizePath(sub("^--file=", "", args_all[grepl("^--file=", args_all)])[1]))
source(file.path(root, "bayes.R"), encoding = "UTF-8")
experimental <- "--experimental" %in% commandArgs(TRUE)
out <- file.path(root, "output", "bayes_20261020")
fits <- lapply(setNames(c("comp", "validos", "lula"), c("comp", "validos", "lula")), function(n)
  readRDS(file.path(out, "validacao", if (n == "lula") "inclinacao" else n, "posterior.rds")))
raw <- file.path(root, "..", "data", "eleicoes_2022_2026", "raw")
t1 <- as.data.table(arrow::read_parquet(file.path(raw, "section_votes_2022_T1.parquet")))
t2 <- as.data.table(arrow::read_parquet(file.path(raw, "section_votes_2022_T2.parquet")))
d <- features(t1, t2)[aptos > 0 & aptos_t2 > 0 & comparecimento > 0 & comp_t2 > 0 & validos > 0 & validos_t2 > 0]
m <- unique(d[, .(uf, cd_mun)])[order(uf,cd_mun)]
m[, teste := seq_len(.N) %% 5L == 0L, by = uf]
test_keys <- m[teste == TRUE, .(uf,cd_mun)]
train <- d[!test_keys, on = .(uf,cd_mun)]
test <- d[test_keys, on = .(uf,cd_mun)]
ols <- lm(I(100*lula_t2/validos_t2) ~ I(100*x_lula) + factor(uf), data = train)
p_ols <- as.numeric(predict(ols,newdata=test))
zero <- lapply(fits, function(f) rep(0,length(f$levels)))
joint <- predict_joint(fits,test,zero)
p_bayes <- 100*joint$a/joint$validos
actual <- 100*test$lula_t2/test$validos_t2
comparison <- data.table(modelo=c("MQO por seção com UF", "Bayes: intercepto e inclinação por UF"),
  rmse_pp=c(sqrt(mean((p_ols-actual)^2)),sqrt(mean((p_bayes-actual)^2))),
  vies_pp=c(mean(p_ols-actual),mean(p_bayes-actual)),secoes_teste=nrow(test),municipios_teste=nrow(test_keys))
fwrite(comparison,file.path(out,"comparacao_mqo_bayes.csv"))
# Checagem preditiva: cobertura por seção no mesmo ano, com C2 previsto.
pred <- copy(test)
pred[,delta_comp:=logistic_normal_mean(predict_latent(fits$comp,test),mean_parameters(fits$comp)$sigma)-taxa_comp_t1]
mu <- predict_latent(fits$lula,pred); sig <- mean_parameters(fits$lula)$sigma
check <- data.table(uf=test$uf,erro_pp=p_bayes-actual,
  coberto_95 = test$y_lula >= mu-1.96*sig & test$y_lula <= mu+1.96*sig)
fwrite(check[,.(secoes=.N,rmse_pp=sqrt(mean(erro_pp^2)),vies_pp=mean(erro_pp),cobertura_preditiva_95=mean(coberto_95)),by=uf],file.path(out,"checagem_preditiva_uf.csv"))
base <- bayes_baseline(fits,test); base[,fallback:="nenhum"]
base <- align_bayes(base,base[,..keys])
obs <- merge(base[,..keys],t2[,c(keys,"aptos","comparecimento","validos","c13","c22","brancos","nulos"),with=FALSE],by=keys)
setnames(obs,c("c13","c22"),c("votos_a","votos_b"))
obs <- merge(obs,base[,c(keys,"p_base"),with=FALSE],by=keys)
set.seed(618327)
orders <- list(aleatoria=sample.int(nrow(obs)),menor_lula_primeiro=order(obs$p_base),maior_lula_primeiro=order(-obs$p_base))
truth <- 100*sum(obs$votos_a)/sum(obs$validos)
replay <- list()
for(name in names(orders)) for(f in c(0,.1,.5,.9,1)) {
  o <- copy(obs[orders[[name]][seq_len(floor(nrow(obs)*f))]]); o[,p_base:=NULL]
  r <- bayes_nowcast(fits,base,o,draws=40L,calibrar=experimental)$resumo
  replay[[length(replay)+1L]] <- data.table(ordem_simulada=name,fracao=f,pct_real=truth,
    pct_apurado=r$pct_a_apurado,pct_previsao=r$pct_a_projetado,erro_pp=r$pct_a_projetado-truth)
}
replay <- rbindlist(replay)
stopifnot(all(abs(replay[fracao==1,erro_pp])<1e-10))
fwrite(replay,file.path(out,if(experimental)"ensaio_experimental_recalibracao_2022.csv" else "ensaio_sequencial_bayes_2022.csv"))
grDevices::pdf(file.path(out,if(experimental)"figura_experimental_recalibracao.pdf" else "figura_1_ensaio_bayes.pdf"),width=9,height=7)
par(mfrow=c(3,1),mar=c(3,4,2,1))
for(name in names(orders)) {
  r<-replay[ordem_simulada==name]
  plot(100*r$fracao,r$pct_previsao,type="l",col="#1d4ed8",lwd=2,
    ylim=range(c(r$pct_previsao,r$pct_apurado,truth),na.rm=TRUE),
    xlab="Seções recebidas (%; ordem simulada)",ylab="Lula (% dos válidos)",
    main=c(aleatoria="Ordem aleatória",menor_lula_primeiro="Menor votação prevista de Lula primeiro",maior_lula_primeiro="Maior votação prevista de Lula primeiro")[[name]])
  lines(100*r$fracao,r$pct_apurado,col="#b45309",lty=2);abline(h=truth,col="#047857",lty=3)
  if(name=="aleatoria")legend("topright",c("Previsão bayesiana","Apurado","Final"),col=c("#1d4ed8","#b45309","#047857"),lty=c(1,2,3),bty="n",cex=.8)
}
dev.off()
final <- readRDS(file.path(root,"data","processed","bayes_fits.rds"))$lula
j <- match("delta_comp",final$spec$vars)+1L
coefficient <- final$draws[,sprintf("beta[%d]",j)]/final$spec$scale[j-1L]
effect <- 100*(plogis(coefficient*.01)-.5)
fwrite(data.table(mediana_log_odds_por_unidade_taxa=median(coefficient),q025=quantile(coefficient,.025),q975=quantile(coefficient,.975),
  associacao_pp_por_1pp_comparecimento_em_p50=median(effect),efeito_q025=quantile(effect,.025),efeito_q975=quantile(effect,.975)),file.path(out,"associacao_comparecimento.csv"))
print(comparison);print(replay)
