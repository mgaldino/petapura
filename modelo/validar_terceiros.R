args_all <- commandArgs(FALSE)
root <- dirname(normalizePath(sub("^--file=", "", args_all[grepl("^--file=", args_all)])[1]))
source(file.path(root,"bayes.R"),encoding="UTF-8")
source(file.path(root,"terceiros.R"),encoding="UTF-8")
checks <- list()
check <- function(name, condition) {
  checks[[length(checks)+1L]] <<- data.table(verificacao=name,passou=isTRUE(condition))
  stopifnot(isTRUE(condition))
}
d <- data.table(uf="AC",cd_mun=1007L,zona=1L,secao=1:2,aptos=150L,comparecimento=110L,
  validos=100L,c13=c(10L,80L),c22=c(20L,10L),c15=c(60L,2L),c12=c(10L,3L))
f <- features_terceiros(d,year=2022)
check("Terceiro nacional é Tebet mesmo quando é primeiro na seção",identical(f$x_terceiro,c(.6,.02)))
check("Quarto nacional é Ciro em todas as seções",identical(f$x_quarto,c(.1,.03)))
check("Composição sem dupla contagem",all(abs(f$x_lula+d$c22/d$validos+f$x_terceiro+f$x_quarto+f$x_outros_sem34-1)<1e-12))
g <- copy(d);setnames(g,c("c15","c12"),c("c70","c14"))
g <- features_terceiros(g,year=2026)
check("2026 usa 70 e 14 em posições nacionais fixas",identical(g$x_terceiro,f$x_terceiro)&&identical(g$x_quarto,f$x_quarto))
check("Cenário zero preserva previsão",identical(ajuste_transferencia(c(.4,.6),c(.2,.1),c(.1,.1)),c(.4,.6)))
new <- ajuste_transferencia(.5,.2,.1,delta3=-.1)
check("Deslocamento de 10 p.p. em grupo de 20% reduz Lula em 2 p.p.",abs(new-.48)<1e-12)
check("Mudança da margem tem o dobro da mudança da votação",abs(((1-new)-new)*100-4)<1e-12)
check("Ajuste negativo respeita limites de votos",ajuste_transferencia(.02,.5,.2,-.5,-.5)==0)
fail <- tryCatch(ajuste_transferencia(.5,.2,.1,delta3=-2),error=identity)
check("Magnitude fora da escala permitida é rejeitada",inherits(fail,"error"))
out <- file.path(root,"output","terceiros_20261020")
dir.create(out,recursive=TRUE,showWarnings=FALSE)
if(file.exists(file.path(out,"candidato_fits.rds"))) {
  candidate <- readRDS(file.path(out,"candidato_fits.rds"))
  b <- fread(file.path(out,"candidato_baseline_2026.csv"))
  if(!"fallback" %in% names(b)) b[,fallback:="nenhum"]
  inventory <- fread(file.path(root,"data","live","inventory.csv"))
  aligned <- align_bayes(b,inventory)
  check("Alinhamento preserva o terceiro em todas as seções T2",all(c("x_terceiro","x_outros_sem3")%in%names(aligned))&&!anyNA(aligned$x_terceiro)&&nrow(aligned)==nrow(inventory))
  empty <- data.table(uf=character(),cd_mun=integer(),zona=integer(),secao=integer(),aptos=numeric(),
    comparecimento=numeric(),validos=numeric(),votos_a=numeric(),votos_b=numeric(),brancos=numeric(),nulos=numeric())
  r <- bayes_nowcast(candidate,aligned,empty,draws=40)$resumo
  check("Candidato produz previsão completa com inventário real T2",is.finite(r$pct_a_projetado)&&r$pct_a_projetado>0&&r$pct_a_projetado<100&&r$secoes==499248)
}
fwrite(rbindlist(checks),file.path(out,"checks.csv"));print(rbindlist(checks))
