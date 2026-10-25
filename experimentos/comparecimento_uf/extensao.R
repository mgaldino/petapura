# Variante local do ajuste histórico 'ambos'. Carregada após previsao_execucao.R.
# Usa 3 coeficientes por UF (intercepto, Lula T1, comparecimento) e 2 comuns.
# Preserva as escalas V2: comp_sd é um choque nacional compartilhado, sem criar
# uma nova dispersão de mudança de comparecimento específica de UF.
evalq({
  .prior_original <- prior_online
  prior_online <- function(fit, ...) {
    if (identical(fit$structure, "voto_t1")) return(.prior_original(fit, ...))
    stopifnot(identical(fit$structure, "ambos"), isTRUE(fit$gate$pass),
              identical(as.integer(fit$varying), c(1L, 2L, 3L)),
              identical(fit$spec$vars, c("x_lula", "taxa_comparecimento", "x_outros", "x_validos")))
    args <- list(...)
    allowed <- c(nomes_escalas_online, "perfil", "arquivo_escalas")
    stopifnot(all(names(args) %in% allowed))
    path <- if (is.null(args$arquivo_escalas)) .online_scales_path else args$arquivo_escalas
    profile <- if (is.null(args$perfil)) "central" else args$perfil
    cfg <- ler_escalas_online(path, profile)
    scales <- cfg$scales
    overrides <- args[intersect(names(args), nomes_escalas_online)]
    for (key in names(overrides)) {
      stopifnot(is.numeric(overrides[[key]]), length(overrides[[key]]) == 1L)
      scales[key] <- overrides[[key]]
    }
    scales <- validar_escalas_online(scales)
    G <- length(fit$levels); q <- 3L * G + 2L
    labels <- c(paste0("alpha_", fit$levels), paste0("voto_", fit$levels),
                paste0("comparecimento_", fit$levels), "outros", "validos")
    map <- lapply(seq_len(G), function(g) c(g, G + g, 2L * G + g, 3L * G + 1:2))
    draws <- cbind(fit$draws[, sprintf("theta[%d,1]", seq_len(G)), drop = FALSE],
                   fit$draws[, sprintf("theta[%d,2]", seq_len(G)), drop = FALSE],
                   fit$draws[, sprintf("theta[%d,3]", seq_len(G)), drop = FALSE],
                   fit$draws[, sprintf("theta[1,%d]", 4:5), drop = FALSE])
    colnames(draws) <- labels
    S <- cov(draws); Q <- matrix(0, q, q)
    a <- seq_len(G); b <- G + a; c <- 2L * G + a
    Q[a,a] <- scales["alpha_global_sd"]^2 + diag(scales["alpha_uf_sd"]^2, G)
    Q[b,b] <- scales["voto_global_sd"]^2 + diag(scales["voto_uf_sd"]^2, G)
    Q[c,c] <- scales["comp_sd"]^2
    diag(Q)[3L * G + 1:2] <- scales[c("outros_sd", "validos_sd")]^2
    dimnames(Q) <- list(labels, labels)
    V <- S + Q
    list(mean = colMeans(draws), covariance = V, historical_covariance = S,
      drift_covariance = Q, precision = chol2inv(chol(V)),
      sigma = mean(fit$draws[, "sigma"]), spec = fit$spec, levels = fit$levels,
      map = map, names = labels, structure = "ambos",
      assumptions = list(historical_posterior = "joint normal moment approximation",
        residual_variance = "fixed at historical posterior mean sigma squared",
        drift_scales = scales, drift_config_version = cfg$version,
        drift_profile = cfg$profile, drift_config_sha256 = cfg$sha256,
        drift_overrides = names(overrides), drift_application = "once before the new election; never per batch",
        turnout_drift = "one shared national shock added to all UF turnout slopes; no additional UF drift"))
  }
  .coefficient_original <- coefficient_online
  coefficient_online <- function(prior, posterior) {
    if ("comparecimento" %in% prior$names) return(.coefficient_original(prior, posterior))
    # Uma inclinação nacional única não existe nesta especificação. As inclinações
    # de cada UF são exportadas pelo relatório local, sem inventar uma média comum.
    data.table(n = posterior$n, media_log_odds_por_1pp = NA_real_,
      q025_log_odds = NA_real_, q975_log_odds = NA_real_, prob_positivo = NA_real_, dp_log_odds = NA_real_)
  }
}, envir = .analise_componentes)

.validar_original_uf <- validar_ponto_partida_analise
validar_ponto_partida_analise <- function(state) {
  if (!identical(state$prior$structure, "ambos")) return(.validar_original_uf(state))
  exigir_analise(identical(state$schema_version, 1L) && identical(state$kind, "initial_analysis"), "Formato de estado inicial incompatível")
  p <- state$prior; G <- length(p$levels); q <- length(p$mean)
  expected <- c(paste0("alpha_", p$levels), paste0("voto_", p$levels),
                paste0("comparecimento_", p$levels), "outros", "validos")
  exigir_analise(q == 3L * G + 2L && identical(p$names, expected) &&
    identical(names(p$mean), expected) && all(is.finite(p$mean)) && is.finite(p$sigma) && p$sigma > 0,
    "Parâmetros da variante por UF inválidos")
  for (g in seq_len(G)) exigir_analise(identical(as.integer(p$map[[g]]),
    as.integer(c(g, G + g, 2L * G + g, 3L * G + 1:2))), "Mapa de coeficientes por UF inválido")
  for (k in c("covariance", "historical_covariance", "drift_covariance", "precision"))
    exigir_analise(identical(dim(p[[k]]), c(q,q)) && all(is.finite(p[[k]])) &&
      max(abs(p[[k]] - t(p[[k]]))) < 1e-8, paste("Matriz inicial inválida:", k))
  chol(p$covariance)
  exigir_analise(max(abs(p$covariance - p$historical_covariance - p$drift_covariance)) < 1e-9 &&
    max(abs(p$covariance %*% p$precision - diag(q))) < 1e-6, "Covariância ou precisão inicial inconsistente")
  b <- normalizar_chaves_analise(state$population)
  exigir_analise(nrow(b) > 0 && identical(hash_inventario_analise(b), state$inventory_sha256), "Inventário inicial inconsistente")
  exigir_analise(identical(hash_objeto_analise(as.list(b)), state$population_sha256), "Preditores iniciais alterados")
  exigir_analise(all(b$uf %in% p$levels) && all(c(p$spec$vars, "aptos", "validos_base", "fallback") %in% names(b)), "Preditores iniciais incompletos")
  exigir_analise(all(is.finite(.analise_componentes$X_comparecimento(b, p$spec))), "Transformações iniciais inválidas")
  exigir_analise(identical(p$assumptions$drift_config_sha256, state$provenance$scales_sha256), "Versão de Q inconsistente")
  identity <- identidade_analise(state$identity$identity, state$identity$candidate_columns)
  exigir_analise(identical(identity, state$identity), "Identidade inicial inconsistente")
  invisible(TRUE)
}
.hashes_analise_original_uf <- hashes_codigo_analise
hashes_codigo_analise <- function() c(.hashes_analise_original_uf(),
  list(comparecimento_uf.R = hash_arquivo_analise(file.path(.previsao_dir, "comparecimento_uf.R"))))
.resultados_original_uf <- resultados_previsao_analise
resultados_previsao_analise <- function(state, ...) {
  result <- .resultados_original_uf(state, ...)
  if (identical(state$prior$structure, "ambos"))
    result$resumo[, modelo := sprintf("voto_t1_comparecimento_uf_%d_coeficientes_local", length(state$prior$mean))]
  result
}
