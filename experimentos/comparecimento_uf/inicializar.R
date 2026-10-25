options(scipen = 999)
library(data.table)
setDTthreads(1)
args <- commandArgs(TRUE)
stopifnot(length(args) == 1L)
p <- jsonlite::read_json(args[1], simplifyVector = TRUE)
source(file.path(p$model_source, "previsao_execucao.R"), encoding = "UTF-8")
fit <- readRDS(p$historical_fit)
stopifnot(identical(fit$structure, "ambos"), isTRUE(fit$gate$pass),
          identical(as.integer(fit$varying), c(1L,2L,3L)))
if (!file.exists(p$variant_fit)) saveRDS(list(lula = fit), p$variant_fit, version = 3)
stopifnot(identical(readRDS(p$variant_fit)$lula$signature, fit$signature))
inicializar_analise(p$variant_initial, p$variant_fit, p$t1_file,
  file.path(p$model_source, "config.json"), p$source,
  scales_path = file.path(p$model_source, "escalas_online_v2.json"))
state <- carregar_ponto_partida_analise(p$variant_initial)
stopifnot(length(state$prior$mean) == 86L, identical(state$prior$structure, "ambos"))
jsonlite::write_json(list(initial_state_id = state$id, coefficients = length(state$prior$mean),
  groups = state$prior$levels, historical_gate = fit$gate, historical_signature = fit$signature,
  historical_fit_sha256 = hash_arquivo_analise(p$historical_fit),
  wrapped_fit_sha256 = hash_arquivo_analise(p$variant_fit),
  population = nrow(state$population), approximations = sum(state$population$fallback != "nenhum"),
  turnout_drift = state$prior$assumptions$turnout_drift),
  file.path(p$base, "initial-validation.json"), auto_unbox = TRUE, pretty = TRUE, digits = 12)
cat("Variante preparada:", state$id, "; coeficientes:", length(state$prior$mean), "\n")
