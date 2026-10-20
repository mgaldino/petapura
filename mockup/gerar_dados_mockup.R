# Dados inteiramente sintéticos para estudo de interface. Não é um modelo eleitoral.
# Sem dados de pessoas, pesquisas ou apuração real. Apenas R base e jsonlite.
set.seed(20261020)
args <- commandArgs(trailingOnly = TRUE)
output <- if (length(args)) args[[1]] else "dados_mockup.json"
n <- 30000L
stages <- list(
  list(time = "18h45", counted = 21.8, mu = 50.8, sd = 3.4, actual = c(47.6,52.4)),
  list(time = "20h30", counted = 65.2, mu = 51.4, sd = 1.9, actual = c(49.6,50.4)),
  list(time = "22h10", counted = 93.4, mu = 51.1, sd = .72, actual = c(50.8,49.2))
)
summarize <- function(draws,actual,metric,threshold,events,labels) {
  point <- colMeans(draws)
  bounds <- t(apply(draws,2,quantile,probs=c(.05,.25,.75,.95),names=FALSE))
  curve <- density(metric,from=min(metric),to=max(metric),n=128)
  list(point=round(point,2),bounds=round(bounds,2),actual=actual,
       curve=list(x=round(curve$x,3),y=round(curve$y,5)),
       threshold=threshold,events=round(events,5),eventLabels=labels,
       interval=round(quantile(metric,c(.05,.95),names=FALSE),2),
       metricMean=round(mean(metric),3))
}
result <- list(note="Dados fictícios; estudo de interface, sem conexão com resultados ou pesquisas reais.",seed=20261020,n=n,stages=list())
for (i in seq_along(stages)) {
  s <- stages[[i]]
  a <- pmin(pmax(rnorm(n,s$mu,s$sd),.01),99.99)
  two <- cbind(a,100-a)
  # Preserva a sequência aleatória da versão anterior e os valores já exibidos.
  invisible(rnorm(n*3))
  result$stages[[i]] <- list(time=s$time,counted=s$counted,
    two=summarize(two,s$actual,two[,1]-two[,2],0,c(mean(a>50),mean(a<50)),c("Candidata A","Candidato B")))
}
# Trajetória parcial inteiramente fictícia; B é o complemento de A.
result$history <- list(counted=c(1,2,5,10,15,21.8,30,40,50,60,65.2,75,85,93.4),
                       a=c(43.3,44.7,46.2,46.6,47.1,47.6,47.9,48.3,48.8,49.25,49.6,50.0,50.45,50.8))
jsonlite::write_json(result,output,auto_unbox=TRUE,digits=6,pretty=FALSE)
for (s in result$stages) {
  stopifnot(abs(sum(s$two$point)-100)<.03,abs(sum(s$two$events)-1)<.001)
}
cat("Dados sintéticos gravados e consistência verificada:",output,"\n")
