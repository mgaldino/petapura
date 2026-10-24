args_all <- commandArgs(FALSE)
root <- dirname(normalizePath(sub("^--file=", "", args_all[grepl("^--file=", args_all)])[1]))
source(file.path(root, "bayes.R"), encoding = "UTF-8")
source(file.path(root, "ancorar.R"), encoding = "UTF-8")
checks <- list()
check <- function(name, yes) {
  checks[[length(checks) + 1L]] <<- data.table(verificacao = name, passou = isTRUE(yes))
  if (!isTRUE(yes)) stop(name)
}
set.seed(618326)
X <- cbind(1, matrix(rnorm(40), 20, 2)); y <- rnorm(20); beta <- c(.2, -.5, .1); sigma <- .7
s <- sufficient(X, y, rep("AC", 20), "AC")
direct <- sum(dnorm(y, as.vector(X %*% beta), sigma, log = TRUE))
aggregate <- -20 * log(sigma) - (s$yy - 2 * sum(beta * s$xy) + as.numeric(t(beta) %*% s$xx[1,,] %*% beta)) / (2*sigma^2) - 10*log(2*pi)
check("Estatísticas suficientes reproduzem a densidade por seção", abs(direct - aggregate) < 1e-10)
shift0 <- online_shift(numeric(), character(), .2, c("AC", "SP"))
shift <- online_shift(rep(.2, 100), rep("AC", 100), .2, c("AC", "SP"))
check("Sem BUs o desvio de eleição tem média zero", all(shift0$mean == 0))
check("BUs deslocam e tornam mais preciso o desvio", shift$mean[1] > .19 && shift$covariance[1,1] < shift0$covariance[1,1])
check("Pooling transmite informação para UF sem BU", shift$mean[2] > 0 && shift$mean[2] < shift$mean[1])
fake_fit <- function(outcome) {
  vars <- switch(outcome, comp = c("x_comp", "x_lula", "x_outros", "x_validos"),
    validos = c("x_validos", "x_lula", "x_outros", "x_comp"),
    lula = c("x_lula", "x_outros", "x_comp", "x_validos", "delta_comp"))
  p <- length(vars) + 1L
  theta <- matrix(0, 2, p)
  theta[,1] <- switch(outcome, comp = qlogis(.8), validos = qlogis(.95), lula = 0)
  if (outcome == "lula") theta[,p] <- .5
  draw <- matrix(0, 50, 2*p+1)
  colnames(draw) <- c(unlist(lapply(1:2, function(g) sprintf("theta[%d,%d]",g,1:p))), "sigma")
  for (g in 1:2) for(k in 1:p) draw[,sprintf("theta[%d,%d]",g,k)] <- theta[g,k]
  draw[,"sigma"] <- .15
  list(spec = list(vars = vars, center = rep(0,length(vars)), scale = rep(1,length(vars))),
    levels = c("AC", "SP"), draws = draw)
}
fits <- lapply(setNames(c("comp", "validos", "lula"), c("comp", "validos", "lula")), fake_fit)
b <- data.table(uf = c("AC", "AC", "SP"), cd_mun = c(1007L,1007L,71072L), zona = c(1L,1L,2L), secao = c(1L,2L,1L),
  aptos = c(100,200,300), x_lula = c(.4,.6,.5), x_outros = .1, x_comp = qlogis(.8), x_validos = qlogis(.95),
  taxa_comp_t1 = .8, delta_comp = 0, p_base = .5, p_raw = .5, validos_base = c(76,152,228), pct_lula_t1 = c(40,60,50), fallback = "nenhum")
o <- b[, c(keys, "aptos"), with = FALSE]
o[, `:=`(comparecimento = c(90,180,270), validos = c(85,170,255), votos_a = c(40,100,150), votos_b = c(45,70,105), brancos = c(2,4,6), nulos = c(3,6,9))]
empty <- o[0]
none <- bayes_nowcast(fits, b, empty, draws = 40)
check("Previsão antes da apuração respeita votos e aptos", none$resumo$votos_a_projetados >= 0 && none$resumo$votos_a_projetados + none$resumo$votos_b_projetados <= sum(b$aptos))
complete <- bayes_nowcast(fits, b, o, draws = 40)
check("Apuração completa reproduz exatamente o total observado", abs(complete$resumo$pct_a_projetado - 100 * 290/510) < 1e-10)
check("Faixa posterior colapsa com todos os BUs", abs(complete$resumo$pct_a_q975 - complete$resumo$pct_a_q025) < 1e-10)
partial <- bayes_nowcast(fits, b, o[1], draws = 40)
check("Voto observado permanece intacto", partial$secoes[apurada == TRUE, a_final] == 40)
source <- list(chosen = list(area="BR", st=3, ts=3, votos_a=290, votos_b=220, validos=510), national_lag_sections=0)
anchored <- ancorar_oficial(partial, source)
check("Âncora oficial completa substitui subtotal BU sem duplicação", anchored$ancora_oficial && abs(anchored$pct_a_projetado - 100*290/510) < 1e-10)
check("Âncora completa encerra incerteza da votação totalizada", abs(anchored$pct_a_q975 - anchored$pct_a_q025) < 1e-10)
inconsistent <- source; inconsistent$chosen$votos_a <- 1
check("Total oficial incompatível não substitui BUs", !ancorar_oficial(partial, inconsistent)$ancora_oficial)
state_sources <- list(chosen=list(area="SOMA_UFS",st=3,ts=3,votos_a=290,votos_b=220,validos=510), national_lag_sections=2,
  states=list(list(area="AC",st=2,ts=2,votos_a=140,votos_b=115),list(area="SP",st=1,ts=1,votos_a=150,votos_b=105)))
state_anchor <- ancorar_oficial(partial, state_sources)
check("Soma estadual substitui nacional congelado sem duplicação", state_anchor$ancora_oficial && state_anchor$atraso_nacional_secoes == 2 && abs(state_anchor$pct_a_projetado - 100*290/510) < 1e-10)
inventory <- rbind(b[, ..keys], data.table(uf="AC",cd_mun=1007L,zona=1L,secao=3L))
check("Fallback de preditores preserva todas as seções do inventário", nrow(align_bayes(b, inventory)) == 4)
out <- file.path(root, "output", "validacao")
dir.create(out, recursive = TRUE, showWarnings = FALSE)
fwrite(rbindlist(checks), file.path(out,"checks_bayes.csv"))
print(rbindlist(checks))
