args_all <- commandArgs(FALSE)
root <- dirname(normalizePath(sub("^--file=", "", args_all[grepl("^--file=", args_all)])[1]))
source(file.path(root, "modelo.R"), encoding = "UTF-8")
source(file.path(root, "bayes.R"), encoding = "UTF-8")
raw <- file.path(root, "..", "data", "eleicoes_2022_2026", "raw")
read_data <- function(name) as.data.table(arrow::read_parquet(file.path(raw, name)))
t1 <- read_data("section_votes_2022_T1.parquet")
t2 <- read_data("section_votes_2022_T2.parquet")
validar_secoes(t1); validar_secoes(t2)
d <- features(t1, t2)[aptos > 0 & aptos_t2 > 0 & comparecimento > 0 & comp_t2 > 0 & validos > 0 & validos_t2 > 0]
municipios <- unique(d[, .(uf, cd_mun)])[order(uf, cd_mun)]
municipios[, teste := seq_len(.N) %% 5L == 0L, by = uf]
test_keys <- municipios[teste == TRUE, .(uf, cd_mun)]
train <- d[!test_keys, on = .(uf, cd_mun)]
test <- d[test_keys, on = .(uf, cd_mun)]
out <- file.path(root, "output", "bayes_20261020")
dir.create(out, recursive = TRUE, showWarnings = FALSE)
stan <- cmdstanr::cmdstan_model(file.path(root, "hierarquico.stan"), quiet = FALSE)
models <- list()
scores <- list()
for (name in c("intercepto", "inclinacao", "sem_comparecimento", "sem_comparecimento_inclinacao")) {
  message("Ajustando validação: ", name)
  model <- fit_bayes(train, if (grepl("^sem_comparecimento", name)) "lula_sem_comp" else "lula",
    name %in% c("inclinacao", "sem_comparecimento_inclinacao"), stan, file.path(out, "validacao", name))
  if (!isTRUE(model$gate$pass)) stop("Candidato não passou os diagnósticos: ", name)
  scores[[name]] <- cbind(identificador = name, bayes_score(model, test))
  models[[name]] <- model
}
scores <- rbindlist(scores)
fwrite(scores, file.path(out, "comparacao_modelos.csv"))
# Inclinação só entra quando melhora a predição nos municípios reservados.
best <- if (scores[identificador == "inclinacao", log_score] > scores[identificador == "intercepto", log_score]) "inclinacao" else "intercepto"
# A variável de comparecimento só será recomendada após conferir o desempenho
# com comparecimento PREVISTO: a comparação acima usa delta T2 observado.
fits <- list()
for (outcome in c("comp", "validos")) {
  message("Ajustando auxiliar para validação: ", outcome)
  fits[[outcome]] <- fit_bayes(train, outcome, FALSE, stan, file.path(out, "validacao", outcome))
  scores <- rbind(scores, cbind(identificador = paste0(outcome, "_auxiliar"), bayes_score(fits[[outcome]], test)), fill = TRUE)
}
predicted_test <- copy(test)
predicted_test[, delta_comp := logistic_normal_mean(predict_latent(fits$comp, test), mean_parameters(fits$comp)$sigma) - taxa_comp_t1]
for (name in c("intercepto", "inclinacao", "sem_comparecimento", "sem_comparecimento_inclinacao")) {
  score <- bayes_score(models[[name]], predicted_test)
  scores <- rbind(scores, cbind(identificador = paste0(name, "_comparecimento_previsto"), score), fill = TRUE)
}
fwrite(scores, file.path(out, "comparacao_modelos.csv"))
best <- if (scores[identificador == "inclinacao_comparecimento_previsto", log_score] > scores[identificador == "intercepto_comparecimento_previsto", log_score]) "inclinacao" else "intercepto"
fits_final <- list()
for (outcome in c("comp", "validos", "lula")) {
  message("Ajustando versão completa: ", outcome)
  fits_final[[outcome]] <- fit_bayes(d, outcome, outcome == "lula" && best == "inclinacao", stan,
    file.path(out, "final", outcome))
}
gates <- rbindlist(lapply(names(fits_final), function(name) cbind(modelo = name, as.data.table(fits_final[[name]]$gate))))
fwrite(gates, file.path(out, "diagnosticos.csv"))
if (!all(gates$pass)) stop("Diagnóstico MCMC insuficiente; não ativar esta versão")
target <- read_data("section_votes_2026_T1_bu.parquet")
validar_secoes(target)
target_features <- features(target)
zero <- target_features[validos == 0, ..keys]
if (nrow(zero)) {
  zone_means <- target_features[validos > 0, .(lula_z = sum(c13) / sum(validos),
    outros_z = sum(validos - c13 - c22) / sum(validos)), by = .(uf, zona)]
  target_features <- merge(target_features, zone_means, by = c("uf", "zona"), all.x = TRUE)
  target_features[validos == 0, `:=`(x_lula = lula_z, x_outros = outros_z)]
}
b <- bayes_baseline(fits_final, target_features)
b[, fallback := fifelse(validos == 0, "zero_validos_t1_composicao_zona", "nenhum")]
processed <- file.path(root, "data", "processed")
saveRDS(fits_final, file.path(processed, "bayes_fits.rds"))
fwrite(b, file.path(processed, "bayes_baseline_2026.csv"))
fwrite(data.table(escolha_inclinacao = best, treino = nrow(d), treino_validacao = nrow(train),
  secoes_teste = nrow(test), municipios_teste = nrow(test_keys)), file.path(out, "escolha.csv"))
message("BAYES_READY")
print(scores)
print(gates)
