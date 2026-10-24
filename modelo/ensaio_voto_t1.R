args_all <- commandArgs(FALSE)
root <- dirname(normalizePath(sub("^--file=","",args_all[grepl("^--file=",args_all)])[1]))
source(file.path(root,"bayes.R"),encoding="UTF-8")
source(file.path(root,"voto_t1.R"),encoding="UTF-8")
raw <- file.path(root,"..","data","eleicoes_2022_2026","raw")
t1 <- as.data.table(arrow::read_parquet(file.path(raw,"section_votes_2022_T1.parquet")))
t2 <- as.data.table(arrow::read_parquet(file.path(raw,"section_votes_2022_T2.parquet")))
d <- features_voto_t1(t1,t2)[aptos>0&aptos_t2>0&comparecimento>0&comp_t2>0&validos>0&validos_t2>0]
m <- unique(d[,.(uf,cd_mun)])[order(uf,cd_mun)]
m[,teste:=seq_len(.N)%%5L==0L,by=uf]
test <- d[m[teste==TRUE,.(uf,cd_mun)],on=.(uf,cd_mun)]
train <- d[!m[teste==TRUE,.(uf,cd_mun)],on=.(uf,cd_mun)]
out <- file.path(root,"output","comparecimento_preditor_20261020")
fit <- readRDS(file.path(out,"T1","voto_t1","posterior.rds"))
base <- baseline_voto_t1(fit,test)
obs <- merge(base[,..keys],t2[,c(keys,"aptos","comparecimento","validos","c13","c22","brancos","nulos"),with=FALSE],by=keys)
setnames(obs,c("c13","c22"),c("votos_a","votos_b"))
obs <- merge(obs,base[,c(keys,"p_base"),with=FALSE],by=keys)
set.seed(618337)
orders <- list(aleatoria=sample.int(nrow(obs)),menor_lula_primeiro=order(obs$p_base),maior_lula_primeiro=order(-obs$p_base))
truth <- 100*sum(obs$votos_a)/sum(obs$validos)
replay <- list()
for(name in names(orders)) for(f in c(0,.1,.5,.9,1)) {
  o <- copy(obs[orders[[name]][seq_len(floor(nrow(obs)*f))]]);o[,p_base:=NULL]
  r <- voto_nowcast(fit,base,o,draws=40)$resumo
  replay[[length(replay)+1L]] <- data.table(ordem_simulada=name,fracao=f,pct_real=truth,
    pct_apurado=r$pct_a_apurado,pct_previsao=r$pct_a_projetado,erro_pp=r$pct_a_projetado-truth)
}
replay <- rbindlist(replay)
stopifnot(all(abs(replay[fracao==1,erro_pp])<1e-10))
fwrite(replay,file.path(out,"ensaio_sequencial_2022.csv"))
# Separa erro de previsão da taxa e aproximação dos pesos T1.
mu <- predict_comparecimento(fit,test)
sigma <- mean_parameters(fit)$sigma
p <- logistic_normal_mean(mu,sigma)
actual <- test$lula_t2/test$validos_t2
weights <- data.table(procedimento=c("Modelo e pesos T1","Modelo e pesos T2 observados (diagnóstico)",
  "Taxas T2 observadas e pesos T1 (diagnóstico)","Resultado T2 observado"),
  pct_lula=c(100*weighted.mean(p,test$validos),100*weighted.mean(p,test$validos_t2),
    100*weighted.mean(actual,test$validos),100*weighted.mean(actual,test$validos_t2)))
weights[,erro_pp:=pct_lula-truth]
fwrite(weights,file.path(out,"diagnostico_pesos_2022.csv"))
ols <- lm(I(100*lula_t2/validos_t2)~I(100*x_lula)+factor(uf),data=train)
pred_ols <- as.numeric(predict(ols,newdata=test))
comparison <- data.table(modelo=c("MQO por seção com UF","Bayes com comparecimento T1"),
  rmse_pp=c(sqrt(mean((pred_ols-100*actual)^2)),sqrt(mean((100*p-100*actual)^2))),
  vies_pp=c(mean(pred_ols-100*actual),mean(100*p-100*actual)))
fwrite(comparison,file.path(out,"comparacao_mqo.csv"))
check <- data.table(uf=test$uf,erro_pp=100*(p-actual),
  coberto_95=test$y_lula>=mu-1.96*sigma&test$y_lula<=mu+1.96*sigma)
fwrite(check[,.(secoes=.N,rmse_pp=sqrt(mean(erro_pp^2)),vies_pp=mean(erro_pp),
  cobertura_preditiva_95=mean(coberto_95)),by=uf],file.path(out,"checagem_preditiva_uf.csv"))
print(comparison);print(replay);print(weights)
