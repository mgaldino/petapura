# Âncora contábil de totais oficiais, sem duplicar BUs.
# A composição dos BUs ainda não baixados é aproximada dentro de UF; o
# intervalo resulta da transformação dos draws, condicionado a essa hipótese.
ancorar_oficial <- function(result, official) {
  s <- copy(result$resumo)
  s[, `:=`(pct_a_somente_bu = pct_a_projetado, fonte_oficial = "indisponivel",
    secoes_totalizadas_tse = NA_real_, atraso_coleta_secoes = NA_real_,
    atraso_nacional_secoes = NA_real_, pct_a_apurado_oficial = NA_real_, ancora_oficial = FALSE,
    fonte_gerada_em = NA_character_, fonte_consulta_atual = NA)]
  if (is.null(official)) return(s)
  latest <- official$chosen
  s[, `:=`(fonte_oficial = latest$area, secoes_totalizadas_tse = latest$st,
    fonte_gerada_em = if (is.null(latest$generated)) NA_character_ else latest$generated,
    fonte_consulta_atual = if (is.null(latest$current)) NA else latest$current,
    atraso_coleta_secoes = latest$st - secoes_apuradas_coletor,
    atraso_nacional_secoes = if (is.null(official$national_lag_sections)) NA_real_ else official$national_lag_sections,
    pct_a_apurado_oficial = if (latest$validos > 0) 100 * latest$votos_a / latest$validos else NA_real_)]
  compatible <- function(u, r) nrow(r) == 1L && u$ts == r$secoes && u$st >= r$secoes_apuradas_coletor &&
    u$st <= u$ts && u$votos_a >= r$votos_a_observados && u$votos_b >= r$votos_b_observados &&
    (u$st != r$secoes_apuradas_coletor || (u$votos_a == r$votos_a_observados && u$votos_b == r$votos_b_observados))
  anchors <- list()
  if (latest$area == "SOMA_UFS") {
    if (length(official$states) != nrow(result$uf)) return(s)
    for (u in official$states) {
      r <- result$uf[uf == u$area]
      if (!compatible(u, r)) return(s)
      anchors[[u$area]] <- data.table(uf = u$area, oa = u$votos_a, ob = u$votos_b,
        ba = r$votos_a_observados, bb = r$votos_b_observados,
        f = if (u$ts > r$secoes_apuradas_coletor) (u$ts - u$st) / (u$ts - r$secoes_apuradas_coletor) else 0)
    }
    anchors <- rbindlist(anchors)
    point <- merge(result$uf, anchors, by = "uf")
    aa <- sum(point$oa + (point$votos_a_projetados - point$ba) * point$f)
    bb <- sum(point$ob + (point$votos_b_projetados - point$bb) * point$f)
    draws <- merge(result$posterior_uf, anchors, by = "uf")
    draws <- draws[, .(a = sum(oa + (votos_a - ba) * f), b = sum(ob + (votos_b - bb) * f)), by = draw]
  } else {
    if (!compatible(latest, s)) return(s)
    f <- if (latest$ts > s$secoes_apuradas_coletor) (latest$ts - latest$st) / (latest$ts - s$secoes_apuradas_coletor) else 0
    aa <- latest$votos_a + (s$votos_a_projetados - s$votos_a_observados) * f
    bb <- latest$votos_b + (s$votos_b_projetados - s$votos_b_observados) * f
    draws <- result$posterior[, .(a = latest$votos_a + (votos_a - s$votos_a_observados) * f,
      b = latest$votos_b + (votos_b - s$votos_b_observados) * f)]
  }
  draws[, pct := 100 * a / (a + b)]
  stopifnot(all(is.finite(draws$pct)), all(draws$pct >= 0 & draws$pct <= 100))
  s[, `:=`(pct_a_projetado = 100 * aa / (aa + bb), votos_a_projetados = aa, votos_b_projetados = bb,
    pct_a_q025 = quantile(draws$pct, .025), pct_a_q975 = quantile(draws$pct, .975), ancora_oficial = TRUE)]
  s
}
