# Ranking NACIONAL fixo por eleição; não recalcular o terceiro em cada seção.
# Ranks conferidos contra extratos TSE e JSON nacional de 2026 preservados.
features_terceiros <- function(t1, t2 = NULL, year) {
  map <- switch(as.character(year),
    `2022` = c(terceiro = "c15", quarto = "c12"),
    `2026` = c(terceiro = "c70", quarto = "c14"), stop("Ano não configurado"))
  stopifnot(all(map %in% names(t1)))
  d <- features(t1, t2)
  d[, `:=`(x_terceiro = get(map[["terceiro"]]) / pmax(1, validos),
    x_quarto = get(map[["quarto"]]) / pmax(1, validos))]
  d[, `:=`(x_outros_sem3 = x_outros - x_terceiro,
    x_outros_sem34 = x_outros - x_terceiro - x_quarto)]
  stopifnot(all(d$x_outros_sem34 >= -1e-12),
    all(abs(d$x_terceiro + d$x_outros_sem3 - d$x_outros) < 1e-12),
    all(abs(d$x_terceiro + d$x_quarto + d$x_outros_sem34 - d$x_outros) < 1e-12))
  d
}

ajuste_transferencia <- function(p, x3, x4, delta3 = 0, delta4 = 0) {
  # delta=-0.10: menos 0,10 p.p. de Lula por 1 p.p. de voto do grupo T1,
  # RELATIVAMENTE à previsão histórica. Não estima fluxo de eleitores.
  stopifnot(all(is.finite(p)), all(p >= 0 & p <= 1), all(x3 >= 0 & x4 >= 0),
    all(x3 + x4 <= 1 + 1e-10), length(delta3) == 1L, length(delta4) == 1L,
    is.finite(delta3), is.finite(delta4), abs(delta3) <= 1, abs(delta4) <= 1)
  pmax(0, pmin(1, p + delta3 * x3 + delta4 * x4))
}
