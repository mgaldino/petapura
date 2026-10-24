# Funções sem efeitos colaterais: treino histórico e atualização por seção.
# Compartilhadas pela operação e pelo ensaio retrospectivo.
suppressPackageStartupMessages(library(data.table))
options(scipen = 999)
setDTthreads(2)
chave <- c("uf", "cd_mun", "zona", "secao")
limitar <- function(x, a = 0, b = 1) pmax(a, pmin(b, x))

validar_secoes <- function(d) {
  stopifnot(!anyNA(d[, ..chave]), !anyDuplicated(d[, ..chave]))
  for (v in intersect(c("aptos", "validos", "comparecimento", "c13", "c22", "brancos", "nulos"), names(d)))
    stopifnot(!anyNA(d[[v]]), all(is.finite(d[[v]])), all(d[[v]] >= 0), all(d[[v]] == floor(d[[v]])))
  stopifnot(all(d$validos <= d$comparecimento), all(d$comparecimento <= d$aptos),
    all(d$validos + d$brancos + d$nulos == d$comparecimento), all(d$c13 + d$c22 <= d$validos))
  invisible(TRUE)
}

ajustar_modelo <- function(t1, t2) {
  validar_secoes(t1)
  validar_secoes(t2)
  stopifnot(all(t2$c13 + t2$c22 == t2$validos))
  d <- merge(t1[, c(chave, "c13", "validos"), with = FALSE],
    t2[, c(chave, "c13", "validos"), with = FALSE], by = chave, suffixes = c("_t1", "_t2"))
  excluidas <- nrow(d[validos_t1 == 0 | validos_t2 == 0])
  d <- d[validos_t1 > 0 & validos_t2 > 0]
  d[, `:=`(pct_lula_t1 = 100 * c13_t1 / validos_t1,
           pct_lula_t2 = 100 * c13_t2 / validos_t2, uf = factor(uf))]
  # Mesmo modelo do laboratório por zonas. Cada seção recebe peso 1 no ajuste.
  modelo <- lm(pct_lula_t2 ~ pct_lula_t1 + uf, data = d)
  turnout <- d[, .(razao_validos = sum(validos_t2) / sum(validos_t1)), by = uf]
  list(modelo = modelo, turnout = turnout,
    diagnostico = data.table(secoes_t1 = nrow(t1), secoes_t2 = nrow(t2),
      chaves_comuns = nrow(d) + excluidas, excluidas_zero_validos = excluidas,
      treino = nrow(d), rmse_ajuste_pp = sqrt(mean(resid(modelo)^2))), treino = d)
}

prever_base <- function(fit, t1) {
  validar_secoes(t1)
  b <- copy(t1)
  # Se não houve voto válido, usa a composição da zona (fallback explícito).
  zona <- b[, .(pct_zona = 100 * sum(c13) / max(1, sum(validos))), by = .(uf, zona)]
  b <- merge(b, zona, by = c("uf", "zona"), all.x = TRUE)
  b[, pct_lula_t1 := fifelse(validos > 0, 100 * c13 / pmax(1, validos), pct_zona)]
  b[, fallback := fifelse(validos > 0, "nenhum", "zero_validos_t1")]
  x <- data.frame(pct_lula_t1 = b$pct_lula_t1,
    uf = factor(b$uf, levels = fit$modelo$xlevels$uf))
  stopifnot(!anyNA(x))
  b[, p_raw := as.numeric(predict(fit$modelo, newdata = x)) / 100]
  b[, p_base := limitar(p_raw)]
  b <- merge(b, fit$turnout, by = "uf", all.x = TRUE)
  # Ao contrário da antiga agregação por zona, estima também o total de válidos.
  # Limite físico usa aptos do T1, substituído pelos aptos observados quando houver BU.
  b[, validos_base := pmin(aptos, validos * razao_validos)]
  b[, .SD, .SDcols = c(chave, "aptos", "pct_lula_t1", "p_raw", "p_base", "validos_base", "fallback")]
}

alinhar_inventario <- function(base, inventory) {
  # Configuração T2 completa define a população; as ausências de X ficam explícitas.
  stopifnot(!anyDuplicated(inventory[, ..chave]), !anyNA(inventory[, ..chave]))
  b <- merge(inventory[, ..chave], base, by = chave, all.x = TRUE)
  b[, aptos := as.numeric(aptos)]
  if (anyNA(b$p_base)) {
    zone <- base[, .(p_z = weighted.mean(p_base, pmax(1, validos_base)),
       v_z = mean(validos_base), a_z = mean(aptos), x_z = mean(pct_lula_t1)), by = .(uf, zona)]
    states <- base[, .(p_u = weighted.mean(p_base, pmax(1, validos_base)),
       v_u = mean(validos_base), a_u = mean(aptos), x_u = mean(pct_lula_t1)), by = uf]
    b <- merge(merge(b, zone, by = c("uf", "zona"), all.x = TRUE), states, by = "uf", all.x = TRUE)
    missing <- which(is.na(b$p_base))
    b[missing, fallback := fifelse(!is.na(p_z), "secao_sem_t1_media_zona", "secao_sem_t1_media_uf")]
    b[missing, `:=`(p_base = fcoalesce(p_z, p_u), p_raw = fcoalesce(p_z, p_u),
      validos_base = fcoalesce(v_z, v_u), aptos = fcoalesce(a_z, a_u),
      pct_lula_t1 = fcoalesce(x_z, x_u))]
    b[, c("p_z", "v_z", "a_z", "x_z", "p_u", "v_u", "a_u", "x_u") := NULL]
  }
  stopifnot(!anyNA(b))
  b[]
}

observado_vazio <- function() data.table(uf = character(), cd_mun = integer(),
  zona = integer(), secao = integer(), validos = numeric(), votos_a = numeric(),
  votos_b = numeric(), aptos = numeric())

atualizar_previsao <- function(base, observed = observado_vazio(), k_votos = 20000) {
  stopifnot(k_votos > 0, !anyDuplicated(base[, ..chave]), !anyNA(base$p_base),
    !anyDuplicated(observed[, ..chave]), !anyNA(observed))
  for (col in c("validos", "votos_a", "votos_b", "aptos")) {
    stopifnot(all(is.finite(observed[[col]])), all(observed[[col]] >= 0),
      all(observed[[col]] == floor(observed[[col]])))
  }
  stopifnot(all(observed$votos_a + observed$votos_b == observed$validos),
    all(observed$validos <= observed$aptos))
  # Novas seções observadas entram mesmo quando não constavam do inventário anterior.
  extra <- observed[!base, on = chave]
  b <- if (nrow(extra)) alinhar_inventario(base, unique(rbind(base[, ..chave], extra[, ..chave]))) else copy(base)
  obs <- observed[, c(chave, "validos", "votos_a", "votos_b", "aptos"), with = FALSE]
  setnames(obs, c("validos", "votos_a", "votos_b", "aptos"), c("v_obs", "a_obs", "b_obs", "aptos_obs"))
  b <- merge(b, obs, by = chave, all.x = TRUE)
  b[, apurada := !is.na(v_obs)]
  # Atualização por UF: residual médio dos BUs frente à previsão de cada seção.
  # k equivale a 20 mil votos de regularização para o modelo histórico.
  # A ordem de chegada não é aleatória: esta correção é hipótese, não garantia.
  calibration <- b[apurada == TRUE, .(delta = sum(a_obs - p_base * v_obs) / (sum(v_obs) + k_votos),
    fator_validos = (sum(v_obs) + k_votos) / (sum(validos_base) + k_votos)), by = uf]
  b <- merge(b, calibration, by = "uf", all.x = TRUE)
  b[is.na(delta), `:=`(delta = 0, fator_validos = 1)]
  b[, `:=`(p_atual = limitar(p_base + delta),
    v_atual = limitar(validos_base * fator_validos, 0, aptos))]
  b[, `:=`(a_final = fifelse(apurada, a_obs, v_atual * p_atual),
    b_final = fifelse(apurada, b_obs, v_atual * (1 - p_atual)),
    # Cenário de erro comum nas seções ainda não apuradas: não é IC.
    a_menos2 = fifelse(apurada, a_obs, v_atual * limitar(p_atual - .02)),
    a_mais2 = fifelse(apurada, a_obs, v_atual * limitar(p_atual + .02)))]
  uf <- b[, .(secoes = .N, secoes_apuradas_coletor = sum(apurada),
    fallback_t1 = sum(fallback != "nenhum"), votos_a_observados = sum(a_obs, na.rm = TRUE),
    votos_b_observados = sum(b_obs, na.rm = TRUE), votos_a_projetados = sum(a_final),
    votos_b_projetados = sum(b_final), validos_pendentes_previstos = sum(v_atual[!apurada])), by = uf]
  uf[, `:=`(pct_a_projetado = 100 * votos_a_projetados / (votos_a_projetados + votos_b_projetados),
    pct_a_apurado = 100 * votos_a_observados / pmax(1, votos_a_observados + votos_b_observados))]
  total <- sum(b$a_final + b$b_final)
  valid_observed <- sum(b$v_obs, na.rm = TRUE)
  summary <- data.table(secoes = nrow(b), secoes_apuradas_coletor = sum(b$apurada),
    pct_secoes_coletor = 100 * mean(b$apurada), fallback_t1 = sum(b$fallback != "nenhum"),
    votos_a_observados = sum(b$a_obs, na.rm = TRUE), votos_b_observados = sum(b$b_obs, na.rm = TRUE),
    pct_a_apurado = if (valid_observed > 0) 100 * sum(b$a_obs, na.rm = TRUE) / valid_observed else NA_real_,
    votos_a_projetados = sum(b$a_final), votos_b_projetados = sum(b$b_final),
    pct_a_projetado = 100 * sum(b$a_final) / total,
    pct_a_cenario_menos2 = 100 * sum(b$a_menos2) / total,
    pct_a_cenario_mais2 = 100 * sum(b$a_mais2) / total)
  list(resumo = summary, uf = uf, calibration = calibration, secoes = b)
}
