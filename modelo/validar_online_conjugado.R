args_all <- commandArgs(FALSE)
root <- dirname(normalizePath(sub("^--file=","",args_all[grepl("^--file=",args_all)])[1]))
source(file.path(root,"bayes.R"),encoding="UTF-8")
source(file.path(root,"voto_t1.R"),encoding="UTF-8")
source(file.path(root,"online_conjugado.R"),encoding="UTF-8")
out <- file.path(root,"output","escalas_online_v2_20261020","atualizador")
dir.create(out,recursive=TRUE,showWarnings=FALSE)
prior <- prior_online(readRDS(file.path(root,"data","processed","voto_t1_fits.rds"))$lula)
base <- fread(file.path(root,"data","processed","voto_t1_baseline_2026.csv"))[uf%in%c("AC","SP")][1:30]
o <- base[,c(keys,"aptos"),with=FALSE]
o[,`:=`(aptos=1000L,comparecimento=800L,validos=760L,votos_a=380L,votos_b=380L,brancos=20L,nulos=20L)]
y <- safe_logit(o$votos_a,o$validos)
checks <- list()
check <- function(name,yes) {
  checks[[length(checks)+1L]] <<- data.table(verificacao=name,passou=isTRUE(yes))
  if(!isTRUE(yes)) stop(name)
}
close <- function(a,b,tol=1e-8)max(abs(a-b))<tol
fails <- function(expr)inherits(tryCatch(force(expr),error=function(e)e),"error")
s <- online_stats(prior,base,y)
zero <- posterior_online(prior,empty_online_stats(prior))
check("Sem observações, média e covariância da prior são preservadas",close(zero$mean,prior$mean)&&close(zero$covariance,prior$covariance))
Xsmall <- X_comparecimento(base,prior$spec)
Xdense <- matrix(0,nrow(base),length(prior$mean))
for(i in seq_len(nrow(base))) Xdense[i,prior$map[[match(base$uf[i],prior$levels)]]] <- Xsmall[i,]
check("Estatísticas em blocos equivalem à matriz completa",close(s$xx,crossprod(Xdense))&&close(s$xy,as.numeric(crossprod(Xdense,y))))
expected_cov <- solve(solve(prior$covariance)+crossprod(Xdense)/prior$sigma^2)
expected_mean <- as.numeric(expected_cov%*%(solve(prior$covariance,prior$mean)+crossprod(Xdense,y)/prior$sigma^2))
post <- posterior_online(prior,s)
check("Posterior coincide com a fórmula normal conjugada",close(post$mean,expected_mean)&&close(post$covariance,expected_cov))
a <- online_stats(prior,base[1:12],y[1:12])
b <- online_stats(prior,base[13:30],y[13:30])
batch <- posterior_online(prior,add_online_stats(a,b))
check("Lotes disjuntos e ajuste único são equivalentes",close(batch$mean,post$mean)&&close(batch$covariance,post$covariance))
check("Covariância posterior é simétrica definida positiva",close(post$covariance,t(post$covariance))&&min(eigen(post$covariance,symmetric=TRUE,only.values=TRUE)$values)>0)
check("Informação nova reduz variância nas direções observadas",min(eigen(prior$covariance-post$covariance,symmetric=TRUE,only.values=TRUE)$values)>-1e-8)
snap1 <- snapshot_online(prior,base,o)
snap2 <- snapshot_online(prior,base,o)
check("Repetir snapshot não conta os mesmos BUs duas vezes",snap1$n==30&&close(snap1$mean,snap2$mean)&&close(snap1$covariance,snap2$covariance))
check("Duplicação de chave no snapshot é rejeitada",fails(snapshot_online(prior,base,rbind(o,o[1]))))
revision <- copy(o);revision[1,`:=`(votos_a=400L,votos_b=360L)]
revised <- snapshot_online(prior,base,revision)
check("BU corrigido substitui contagem anterior sem aumentar N",revised$n==30&&!close(revised$mean,snap1$mean,1e-10))
reduced <- snapshot_online(prior,base,o[-1])
check("Remover BU reduz N e recompõe a posterior desde a prior",reduced$n==29&&!close(reduced$mean,snap1$mean,1e-10))
# Verifica preservação de correlações ao simular, contra uma normal conhecida.
known <- list(mean=c(1,-2),covariance=matrix(c(.4,.25,.25,.7),2,2))
samples <- sample_online(known,n=30000L)
check("Draws conjuntos preservam média e covariância",close(colMeans(samples),known$mean,.02)&&close(cov(samples),known$covariance,.025))
saved <- readRDS(file.path(root,"data","processed","voto_t1_fits.rds"))$lula
check("Protótipo mantém intacta a especificação ativa",identical(saved$structure,"voto_t1")&&
  !grepl("online_conjugado",paste(readLines(file.path(root,"atualizar_bayes.R")),collapse="\n")))
fwrite(rbindlist(checks),file.path(out,"checks.csv"))
print(rbindlist(checks))
