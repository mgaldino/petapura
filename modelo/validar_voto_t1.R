args_all <- commandArgs(FALSE)
root <- dirname(normalizePath(sub("^--file=","",args_all[grepl("^--file=",args_all)])[1]))
source(file.path(root,"bayes.R"),encoding="UTF-8")
source(file.path(root,"voto_t1.R"),encoding="UTF-8")
source(file.path(root,"ancorar.R"),encoding="UTF-8")
checks <- list()
check <- function(name,yes) {
  checks[[length(checks)+1L]] <<- data.table(verificacao=name,passou=isTRUE(yes))
  if(!isTRUE(yes)) stop(name)
}
fails <- function(expr)inherits(tryCatch(force(expr),error=function(e)e),"error")
b <- data.table(uf=c("AC","AC","SP"),cd_mun=c(1007L,1007L,71072L),
  zona=c(1L,1L,2L),secao=c(1L,2L,1L),aptos=as.integer(c(100,201,300)),
  x_lula=c(.4,.6,.5),x_outros=.1,x_validos=qlogis(.95),
  taxa_comp_t1=c(.8,.9,.8),taxa_comparecimento=c(.8,.9,.8),
  p_base=.5,p_raw=.5,validos_base=c(76,171,228),pct_lula_t1=c(40,60,50),fallback="nenhum")
vars <- c("x_lula","taxa_comparecimento","x_outros","x_validos")
fit <- list(spec=list(vars=vars,center=setNames(rep(0,4),vars),scale=setNames(rep(1,4),vars),
  center_uf=data.table(uf=c("AC","SP"),lula_media=c(.5,.5),comp_media=c(.85,.8)),turno=1L),
  levels=c("AC","SP"),gate=list(pass=TRUE))
fit$draws <- matrix(0,40,11,dimnames=list(NULL,c(unlist(lapply(1:2,function(g)sprintf("theta[%d,%d]",g,1:5))),"sigma")))
fit$draws[,"theta[1,2]"] <- .5;fit$draws[,"theta[2,2]"] <- .7
fit$draws[,"theta[1,3]"] <- fit$draws[,"theta[2,3]"] <- -.2
fit$draws[,"sigma"] <- .15
o <- b[,c(keys,"aptos"),with=FALSE]
o[,`:=`(comparecimento=c(90,180,270),validos=c(85,170,255),votos_a=c(40,100,150),
  votos_b=c(45,70,105),brancos=c(2,4,6),nulos=c(3,6,9))]
X <- X_comparecimento(b,fit$spec)
check("Comparecimento usa taxa T1 e centralização UF do treino",max(abs(X[,3]-c(-.05,.05,0)))<1e-10)
altered <- copy(b);altered[,`:=`(comp_t2=c(0,1,2),delta_comp=99,y_comp=99)]
check("Comparecimento T2 não entra na matriz de preditores",identical(X,X_comparecimento(altered,fit$spec)))
shuffled <- X_comparecimento(b[c(3,1,2)],fit$spec)
check("Junção UF preserva a ordem das seções",identical(unname(shuffled),unname(X[c(3,1,2),])))
check("Inclinação do comparecimento tem sinal negativo no exemplo",all(efeito_comparecimento(fit)$q975_log_odds<0))
none <- voto_nowcast(fit,b,o[0],draws=40)
check("Seções pendentes usam número de válidos T1 como peso fixo",abs(none$resumo$votos_a_projetados+none$resumo$votos_b_projetados-sum(b$validos_base))<1e-10)
check("Draws respeitam limites dos votos e o peso fixo",all(none$posterior$votos_a>=0&none$posterior$votos_b>=0)&
  all(abs(none$posterior$votos_a+none$posterior$votos_b-sum(b$validos_base))<1e-10))
partial <- voto_nowcast(fit,b,o[1],draws=40)
check("BU substitui previsão e denominador da seção",partial$secoes[apurada==TRUE,a_final]==40&&
  abs(sum(partial$secoes$a_final+partial$secoes$b_final)-(85+171+228))<1e-10)
complete <- voto_nowcast(fit,b,o,draws=40)
check("Apuração completa reproduz exatamente o resultado",abs(complete$resumo$pct_a_projetado-100*290/510)<1e-10)
check("Incerteza colapsa com todos os BUs",abs(complete$resumo$pct_a_q975-complete$resumo$pct_a_q025)<1e-10)
check("BU duplicado é rejeitado",fails(voto_nowcast(fit,b,rbind(o,o[1]),draws=2)))
bad <- copy(o);bad[1,votos_a:=41]
check("Soma inconsistente no BU é rejeitada",fails(voto_nowcast(fit,b,bad,draws=2)))
bad <- copy(o);bad[1,brancos:=-1]
check("Contagem negativa no BU é rejeitada",fails(voto_nowcast(fit,b,bad,draws=2)))
inventory <- rbind(b[,..keys],data.table(uf="AC",cd_mun=1007L,zona=1L,secao=3L))
filled <- align_voto_t1(b,inventory)
check("Seção sem T1 recebe preditores e peso da zona identificados",nrow(filled)==4&&
  abs(filled[uf=="AC"&secao==3,validos_base]-mean(c(76,171)))<1e-10&&
  filled[uf=="AC"&secao==3,aptos]==150.5&&
  filled[uf=="AC"&secao==3,fallback]!="nenhum")
source <- list(chosen=list(area="BR",st=3,ts=3,votos_a=290,votos_b=220,validos=510),national_lag_sections=0)
anchored <- ancorar_oficial(partial,source)
check("Total BR substitui subtotal sem duplicação",anchored$ancora_oficial&&abs(anchored$pct_a_projetado-100*290/510)<1e-10)
source$chosen$votos_a <- 1
check("Total incompatível com BUs não é ancorado",!ancorar_oficial(partial,source)$ancora_oficial)
states <- list(chosen=list(area="SOMA_UFS",st=3,ts=3,votos_a=290,votos_b=220,validos=510),national_lag_sections=2,
  states=list(list(area="AC",st=2,ts=2,votos_a=140,votos_b=115),list(area="SP",st=1,ts=1,votos_a=150,votos_b=105)))
anchor <- ancorar_oficial(partial,states)
check("Soma estadual à frente substitui nacional congelado",anchor$ancora_oficial&&
  anchor$atraso_nacional_secoes==2&&abs(anchor$pct_a_projetado-100*290/510)<1e-10)
out <- file.path(root,"output","comparecimento_preditor_20261020")
dir.create(out,recursive=TRUE,showWarnings=FALSE)
fwrite(rbindlist(checks),file.path(out,"checks_voto_t1.csv"))
print(rbindlist(checks))
