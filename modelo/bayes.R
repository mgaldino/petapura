# Modelo hierárquico bayesiano e atualização normal conjugada dos desvios 2026.
# A atualização online é modular: histórico congelado, desvio de eleição novo.
# As incertezas históricas e os desvios 2026 são simulados; nenhuma faixa é
# uma garantia de cobertura sob seleção da ordem de chegada ou erro estrutural.
suppressPackageStartupMessages({library(data.table); library(posterior)})
options(scipen = 999)
setDTthreads(2)
keys <- c("uf", "cd_mun", "zona", "secao")
safe_logit <- function(a, n) qlogis((a + .5) / (n + 1))

features <- function(t1, t2 = NULL) {
  d <- copy(t1)
  d[, `:=`(x_lula = c13 / pmax(1, validos),
    x_outros = (validos - c13 - c22) / pmax(1, validos),
    x_comp = safe_logit(comparecimento, aptos),
    x_validos = safe_logit(validos, comparecimento),
    taxa_comp_t1 = comparecimento / pmax(1, aptos))]
  if (!is.null(t2)) {
    z <- t2[, c(keys, "aptos", "comparecimento", "validos", "c13"), with = FALSE]
    setnames(z, c("aptos", "comparecimento", "validos", "c13"), c("aptos_t2", "comp_t2", "validos_t2", "lula_t2"))
    d <- merge(d, z, by = keys)
    d[, `:=`(y_comp = safe_logit(comp_t2, aptos_t2),
      y_validos = safe_logit(validos_t2, comp_t2),
      y_lula = safe_logit(lula_t2, validos_t2),
      delta_comp = comp_t2 / pmax(1, aptos_t2) - taxa_comp_t1)]
  }
  d[]
}

design_spec <- function(d, outcome) {
  vars <- switch(outcome,
    comp = c("x_comp", "x_lula", "x_outros", "x_validos"),
    validos = c("x_validos", "x_lula", "x_outros", "x_comp"),
    lula = c("x_lula", "x_outros", "x_comp", "x_validos", "delta_comp"),
    lula_terceiro = c("x_lula", "x_terceiro", "x_outros_sem3", "x_comp", "x_validos", "delta_comp"),
    lula_terceiro_quarto = c("x_lula", "x_terceiro", "x_quarto", "x_outros_sem34", "x_comp", "x_validos", "delta_comp"),
    lula_sem_comp = c("x_lula", "x_outros"))
  list(vars = vars, center = vapply(vars, function(v) mean(d[[v]]), 0.0),
    scale = vapply(vars, function(v) sd(d[[v]]), 0.0))
}

design_matrix <- function(d, spec) {
  m <- as.matrix(d[, spec$vars, with = FALSE])
  cbind(intercept = rep(1, nrow(m)), sweep(sweep(m, 2, spec$center, "-"), 2, spec$scale, "/"))
}

sufficient <- function(X, y, group, levels) {
  p <- ncol(X); g <- length(levels)
  xx <- array(0, c(g, p, p)); xy <- matrix(0, g, p)
  yy <- numeric(g); n <- integer(g)
  for (j in seq_len(g)) {
    take <- which(group == levels[j])
    n[j] <- length(take)
    xx[j,,] <- crossprod(X[take,,drop = FALSE])
    xy[j,] <- as.numeric(crossprod(X[take,,drop = FALSE], y[take]))
    yy[j] <- sum(y[take]^2)
  }
  list(n = n, xx = xx, xy = xy, yy = yy)
}

fit_bayes <- function(d, outcome, varying_slope, stan, out, seed = 618320) {
  spec <- design_spec(d, outcome)
  X <- design_matrix(d, spec)
  y <- d[[if (startsWith(outcome, "lula")) "y_lula" else paste0("y_", outcome)]]
  levels <- sort(unique(d$uf))
  stats <- sufficient(X, y, d$uf, levels)
  p <- ncol(X); k <- if (varying_slope) 2L else 1L
  args <- c(list(G = length(levels), P = p, K = k), stats,
    list(prior_mean = c(mean(y), rep(0, p - 1)),
         prior_sd = c(1.5, rep(.7, p - 1)), prior_tau = rep(.5, k)))
  signature <- digest::digest(list(args, outcome, varying_slope, readLines(stan$stan_file())))
  cached <- file.path(out, "posterior.rds")
  if (file.exists(cached)) {
    previous <- readRDS(cached)
    if (identical(previous$signature, signature)) return(previous)
    stop("Posterior existente de outra especificação; use nova pasta: ", out)
  }
  dir.create(out, recursive = TRUE, showWarnings = FALSE)
  fit <- stan$sample(data = args, chains = 4, parallel_chains = 2, threads_per_chain = 1,
    iter_warmup = 1000, iter_sampling = 1000, seed = seed,
    adapt_delta = .95, max_treedepth = 12, refresh = 0, output_dir = out)
  summary <- as.data.table(fit$summary())
  sampler <- as.data.table(fit$diagnostic_summary())
  fwrite(summary, file.path(out, "summary.csv"))
  fwrite(sampler, file.path(out, "sampler.csv"))
  gate <- list(max_rhat = max(summary$rhat, na.rm = TRUE),
    min_ess_bulk = min(summary$ess_bulk, na.rm = TRUE),
    divergences = sum(sampler$num_divergent), treedepth = sum(sampler$num_max_treedepth))
  gate$pass <- gate$max_rhat <= 1.01 && gate$min_ess_bulk >= 400 && gate$divergences == 0 && gate$treedepth == 0
  draws <- posterior::as_draws_matrix(fit$draws(variables = c("theta", "sigma", "tau", "beta")))
  # 200 draws uniformemente espaçados para previsão; os 4 mil ficam nos CSVs Stan.
  selected <- unique(round(seq(1, nrow(draws), length.out = 200)))
  result <- list(outcome = outcome, varying_slope = varying_slope, spec = spec, levels = levels,
    draws = unclass(draws[selected,,drop = FALSE]), gate = gate, stats = stats,
    n = nrow(d), prior = args[c("prior_mean", "prior_sd", "prior_tau")], signature = signature)
  saveRDS(result, file.path(out, "posterior.rds"))
  result
}

mean_parameters <- function(fit) {
  p <- length(fit$spec$vars) + 1L
  theta <- matrix(0, length(fit$levels), p)
  for (g in seq_along(fit$levels)) for (k in seq_len(p))
    theta[g,k] <- mean(fit$draws[, sprintf("theta[%d,%d]", g, k)])
  list(theta = theta, sigma = mean(fit$draws[,"sigma"]))
}

predict_latent <- function(fit, d, parameters = mean_parameters(fit)) {
  group <- match(d$uf, fit$levels)
  stopifnot(!anyNA(group))
  X <- design_matrix(d, fit$spec)
  rowSums(X * parameters$theta[group,,drop = FALSE])
}

logistic_normal_mean <- function(mu, sigma) {
  # Quadratura normal de Gauss-Hermite com cinco pontos (soma dos pesos = 1).
  nodes <- c(-2.8569700139, -1.3556261800, 0, 1.3556261800, 2.8569700139)
  weights <- c(.0112574113, .2220759220, .5333333333, .2220759220, .0112574113)
  answer <- numeric(length(mu))
  for (i in seq_along(nodes)) answer <- answer + weights[i] * plogis(mu + nodes[i] * sigma)
  answer
}

online_shift <- function(residual, uf, sigma, levels, global_sd = .15, state_sd = .10) {
  # Modelo novo: residual_i = delta_UF + erro_i; delta_UF = delta_BR + u_UF.
  # delta_BR ~ N(0,.15²), u_UF ~ N(0,.10²). Escalas em log-odds.
  # Prior do erro comum entre eleições é explícito e editável; 2022 sozinho não o identifica.
  g <- length(levels)
  prior_cov <- matrix(global_sd^2, g, g) + diag(state_sd^2, g)
  precision <- solve(prior_cov)
  sums <- numeric(g); counts <- numeric(g)
  for (j in seq_len(g)) {
    r <- residual[uf == levels[j]]
    counts[j] <- length(r)
    sums[j] <- sum(r)
  }
  covariance <- solve(precision + diag(counts / sigma^2, g))
  mean <- as.numeric(covariance %*% (sums / sigma^2))
  list(mean = mean, covariance = covariance, levels = levels, n = counts,
    global_sd = global_sd, state_sd = state_sd)
}

bayes_baseline <- function(fits, d) {
  comp <- logistic_normal_mean(predict_latent(fits$comp, d), mean_parameters(fits$comp)$sigma)
  valid <- logistic_normal_mean(predict_latent(fits$validos, d), mean_parameters(fits$validos)$sigma)
  d <- copy(d)
  d[, delta_comp := comp - taxa_comp_t1]
  p <- logistic_normal_mean(predict_latent(fits$lula, d), mean_parameters(fits$lula)$sigma)
  d[, `:=`(p_base = p, p_raw = p, validos_base = aptos * comp * valid,
    pct_lula_t1 = 100 * x_lula)]
  d[]
}

bayes_score <- function(fit, d) {
  y <- d[[if (startsWith(fit$outcome, "lula")) "y_lula" else paste0("y_", fit$outcome)]]
  mu <- predict_latent(fit, d)
  sigma <- mean_parameters(fit)$sigma
  data.table(modelo = fit$outcome, inclinacao_variavel = fit$varying_slope, n = nrow(d),
    log_score = mean(dnorm(y, mu, sigma, log = TRUE)),
    rmse_logit = sqrt(mean((y - mu)^2)),
    rmse_proporcao_pp = 100 * sqrt(mean((plogis(y) - logistic_normal_mean(mu, sigma))^2)))
}

align_bayes <- function(base, inventory) {
  cols <- c(keys, "aptos", "x_lula", "x_outros", "x_comp", "x_validos", "taxa_comp_t1",
    "delta_comp", "p_base", "p_raw", "validos_base", "pct_lula_t1", "fallback")
  cols <- c(cols, intersect(c("x_terceiro", "x_quarto", "x_outros_sem3", "x_outros_sem34"), names(base)))
  base <- base[, ..cols]
  base[, aptos := as.numeric(aptos)]
  b <- merge(inventory[, ..keys], base, by = keys, all.x = TRUE)
  missing <- which(is.na(b$p_base))
  if (length(missing)) {
    numeric_cols <- setdiff(cols, c(keys, "fallback"))
    for (column in numeric_cols) {
      zones <- base[, .(value_z = mean(get(column))), by = .(uf, zona)]
      states <- base[, .(value_u = mean(get(column))), by = uf]
      fill <- merge(merge(b[missing, ..keys], zones, by = c("uf", "zona"), all.x = TRUE), states, by = "uf", all.x = TRUE)
      fill[, value := fcoalesce(value_z, value_u)]
      # Reordena pela chave para preservar a correspondência entre valores.
      fill <- fill[b[missing, ..keys], on = keys]
      set(b, i = missing, j = column, value = as.numeric(fill$value))
    }
    b[missing, fallback := "preditores_t1_medias_zona_ou_uf"]
  }
  stopifnot(!anyNA(b), !anyDuplicated(b[, ..keys]))
  b[]
}

predict_joint <- function(fits, d, shifts, params = lapply(fits, mean_parameters)) {
  g <- match(d$uf, fits$comp$levels)
  mu_c <- predict_latent(fits$comp, d, params$comp) + shifts$comp[g]
  mu_v <- predict_latent(fits$validos, d, params$validos) + shifts$validos[g]
  rate_v <- logistic_normal_mean(mu_v, params$validos$sigma)
  d <- copy(d); d[, delta_comp := 0]
  mu_l0 <- predict_latent(fits$lula, d, params$lula) + shifts$lula[g]
  delta_col <- match("delta_comp", fits$lula$spec$vars)
  slope_delta <- params$lula$theta[g, delta_col + 1L] / fits$lula$spec$scale[delta_col]
  nodes <- c(-2.8569700139, -1.3556261800, 0, 1.3556261800, 2.8569700139)
  weights <- c(.0112574113, .2220759220, .5333333333, .2220759220, .0112574113)
  a <- valid <- comp <- numeric(nrow(d))
  for (j in seq_along(nodes)) {
    c_rate <- plogis(mu_c + nodes[j] * params$comp$sigma)
    mu_l <- mu_l0 + slope_delta * (c_rate - d$taxa_comp_t1)
    p <- logistic_normal_mean(mu_l, params$lula$sigma)
    comp <- comp + weights[j] * d$aptos * c_rate
    valid <- valid + weights[j] * d$aptos * c_rate * rate_v
    a <- a + weights[j] * d$aptos * c_rate * rate_v * p
  }
  data.table(a = a, b = valid - a, validos = valid, comparecimento = comp)
}

bayes_nowcast <- function(fits, base, observed, draws = 400L, seed = 618325, calibrar = FALSE) {
  stopifnot(!anyDuplicated(observed[, ..keys]), !anyNA(observed),
    all(observed$votos_a + observed$votos_b == observed$validos),
    all(observed$validos + observed$brancos + observed$nulos == observed$comparecimento),
    all(observed$comparecimento <= observed$aptos))
  for (col in c("aptos", "comparecimento", "validos", "votos_a", "votos_b", "brancos", "nulos"))
    stopifnot(all(is.finite(observed[[col]])), all(observed[[col]] >= 0), all(observed[[col]] == floor(observed[[col]])))
  extra <- observed[!base, on = keys]
  if (nrow(extra)) base <- align_bayes(base, unique(rbind(base[, ..keys], extra[, ..keys])))
  b <- merge(base, observed[, c(keys, "aptos", "comparecimento", "validos", "votos_a", "votos_b"), with = FALSE],
    by = keys, all.x = TRUE, suffixes = c("", "_obs"))
  b[, apurada := !is.na(validos)]
  obs <- b[apurada == TRUE]
  obs[, delta_comp := comparecimento / pmax(1, aptos_obs) - taxa_comp_t1]
  outcomes <- list(comp = safe_logit(obs$comparecimento, obs$aptos_obs),
    validos = safe_logit(obs$validos, obs$comparecimento), lula = safe_logit(obs$votos_a, obs$validos))
  valid <- list(comp = obs$aptos_obs > 0, validos = obs$comparecimento > 0, lula = obs$validos > 0)
  # Estatísticas por UF para recalibrar os desvios sem reler cada seção por draw.
  online <- shifts <- list()
  params <- lapply(fits, mean_parameters)
  for (name in names(fits)) {
    # Produção conserva a relação histórica nas seções pendentes. A calibração
    # de desvios via primeiras seções é experimental: falhou no teste de ordem.
    take <- if (calibrar) valid[[name]] else rep(FALSE, nrow(obs))
    X <- design_matrix(obs[take], fits[[name]]$spec)
    g <- fits[[name]]$levels
    sums_x <- matrix(0, length(g), ncol(X)); sums_y <- counts <- numeric(length(g))
    for (j in seq_along(g)) {
      rows <- which(obs$uf[take] == g[j]); counts[j] <- length(rows)
      sums_x[j,] <- colSums(X[rows,,drop = FALSE]); sums_y[j] <- sum(outcomes[[name]][take][rows])
    }
    online[[name]] <- list(x = sums_x, y = sums_y, n = counts)
    residual <- outcomes[[name]][take] - predict_latent(fits[[name]], obs[take], params[[name]])
    shifts[[name]] <- online_shift(residual, obs$uf[take], params[[name]]$sigma, g)
  }
  pending <- b[apurada == FALSE]
  point <- predict_joint(fits, pending, lapply(shifts, `[[`, "mean"), params)
  b[apurada == FALSE, `:=`(a_final = point$a, b_final = point$b, comp_previsto = point$comparecimento)]
  b[apurada == TRUE, `:=`(a_final = votos_a, b_final = votos_b, comp_previsto = comparecimento)]
  point_uf <- b[, .(a = sum(a_final), b = sum(b_final), comp = sum(comp_previsto)), by = uf]
  # Controle de variância: previsão exata em todas as seções; draws usam diferenças
  # para uma amostra fixa de até 400 seções pendentes/UF. Não reamostra eleitores.
  set.seed(seed)
  sample <- pending[, .SD[sample.int(.N, min(.N, 400L))], by = uf]
  sample_point <- predict_joint(fits, sample, lapply(shifts, `[[`, "mean"), params)
  population <- pending[, .(N = .N), by = uf]
  sample_sizes <- sample[, .(n = .N), by = uf]
  scale <- merge(population, sample_sizes, by = "uf")
  draws_out <- uf_draws <- vector("list", draws)
  for (draw in seq_len(draws)) {
    par_draw <- delta <- list()
    for (name in names(fits)) {
      fit <- fits[[name]]; row <- 1L + (draw - 1L) %% nrow(fit$draws)
      p <- length(fit$spec$vars) + 1L
      theta <- matrix(0, length(fit$levels), p)
      for (g in seq_along(fit$levels)) for (k in seq_len(p)) theta[g,k] <- fit$draws[row, sprintf("theta[%d,%d]",g,k)]
      sigma <- fit$draws[row,"sigma"]
      par_draw[[name]] <- list(theta = theta, sigma = sigma)
      s <- online[[name]]
      prior_cov <- matrix(.15^2, length(fit$levels), length(fit$levels)) + diag(.10^2, length(fit$levels))
      covariance <- solve(solve(prior_cov) + diag(s$n / sigma^2, length(fit$levels)))
      m <- as.numeric(covariance %*% ((s$y - rowSums(s$x * theta)) / sigma^2))
      delta[[name]] <- m + as.numeric(t(chol(covariance)) %*% rnorm(length(m)))
    }
    pred <- predict_joint(fits, sample, delta, par_draw)
    diff <- data.table(uf = sample$uf, da = pred$a - sample_point$a, db = pred$b - sample_point$b)
    adjustment <- merge(diff[, .(da = sum(da), db = sum(db)), by = uf], scale, by = "uf")
    adjustment[, `:=`(da = da * N / n, db = db * N / n)]
    ud <- merge(point_uf, adjustment[, .(uf, da, db)], by = "uf", all.x = TRUE)
    ud[is.na(da), `:=`(da = 0, db = 0)]
    ud[, `:=`(draw = draw, votos_a = a + da, votos_b = b + db)]
    uf_draws[[draw]] <- ud[, .(draw, uf, votos_a, votos_b)]
    a <- sum(ud$votos_a)
    bb <- sum(ud$votos_b)
    draws_out[[draw]] <- data.table(draw = draw, pct_a = 100 * a / (a + bb), votos_a = a, votos_b = bb)
  }
  posterior <- rbindlist(draws_out)
  uf <- b[, .(secoes = .N, secoes_apuradas_coletor = sum(apurada), fallback_t1 = sum(fallback != "nenhum"),
    votos_a_observados = sum(votos_a, na.rm = TRUE), votos_b_observados = sum(votos_b, na.rm = TRUE),
    votos_a_projetados = sum(a_final), votos_b_projetados = sum(b_final)), by = uf]
  uf[, pct_a_projetado := 100 * votos_a_projetados / (votos_a_projetados + votos_b_projetados)]
  summary <- data.table(secoes = nrow(b), secoes_apuradas_coletor = nrow(obs), pct_secoes_coletor = 100 * nrow(obs) / nrow(b),
    fallback_t1 = sum(b$fallback != "nenhum"), votos_a_observados = sum(obs$votos_a), votos_b_observados = sum(obs$votos_b),
    pct_a_apurado = if (sum(obs$validos)) 100 * sum(obs$votos_a) / sum(obs$validos) else NA_real_,
    votos_a_projetados = sum(b$a_final), votos_b_projetados = sum(b$b_final),
    pct_a_projetado = 100 * sum(b$a_final) / sum(b$a_final + b$b_final),
    pct_a_q025 = quantile(posterior$pct_a, .025), pct_a_q975 = quantile(posterior$pct_a, .975))
  list(resumo = summary, uf = uf, posterior = posterior, posterior_uf = rbindlist(uf_draws), secoes = b, shifts = shifts)
}
