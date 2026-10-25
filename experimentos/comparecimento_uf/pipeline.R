# Ponte para a API atual do modelo, sem alterar o módulo original.
# Entrada: Rscript --vanilla executar_pipeline.R fixture|inicializar|atualizar SETTINGS.json

preparar_fixture_site <- function(p) {
  dir.create(file.path(p$runtime, "fixture"), recursive = TRUE, showWarnings = FALSE)
  folder <- file.path(p$runtime, "fixture")
  stopifnot(!file.exists(file.path(folder, "scenario.json")))
  cfg <- jsonlite::read_json(file.path(p$model_source, "config.json"), simplifyVector = TRUE)
  original <- carregar_ponto_partida_analise(p$variant_initial)
  set.seed(p$seed)
  n <- as.integer(p$sections_per_uf)
  inventory <- data.table::rbindlist(lapply(seq_along(original$prior$levels), function(i)
    data.table::data.table(uf = original$prior$levels[i], cd_mun = 10000L + i,
                          zona = 1L, secao = seq_len(n))))
  t1 <- data.table::copy(inventory)
  t1[, aptos := sample(300:600, .N, replace = TRUE)]
  t1[, comparecimento := as.integer(round(aptos * runif(.N, .69, .88)))]
  t1[, validos := as.integer(round(comparecimento * runif(.N, .90, .98)))]
  t1[, c13 := as.integer(round(validos * runif(.N, .20, .73)))]
  t1[, c22 := as.integer(round((validos - c13) * runif(.N, .65, .93)))]
  arrow::write_parquet(t1, file.path(folder, "t1.parquet"))
  data.table::fwrite(inventory, file.path(folder, "inventory.csv"))
  pop <- preparar_populacao_analise(t1, inventory, original$prior)
  X <- .analise_componentes$X_comparecimento(pop, original$prior$spec)
  mu <- numeric(nrow(pop))
  for (g in seq_along(original$prior$levels)) {
    rows <- which(pop$uf == original$prior$levels[g])
    mu[rows] <- as.numeric(X[rows, , drop = FALSE] %*%
                            original$prior$mean[original$prior$map[[g]]])
  }
  # Verdade fixa inventada para exercitar atualização; não é uma previsão eleitoral.
  target <- .515
  shift <- qlogis(target) - qlogis(weighted.mean(plogis(mu), pop$validos_base))
  probability <- plogis(mu + shift + rnorm(length(mu), 0, original$prior$sigma))
  truth <- pop[, ..chaves_analise]
  truth[, validos := as.integer(pop$validos_base)]
  truth[, votos_a := as.integer(round(validos * probability))]
  truth[, `:=`(votos_b = validos - votos_a, brancos = as.integer(round(.02 * validos)),
                nulos = as.integer(round(.03 * validos)))]
  truth[, comparecimento := validos + brancos + nulos]
  truth[, aptos := pmax(as.integer(pop$aptos), comparecimento)]
  truth[, hash := vapply(seq_len(.N), function(i)
    digest::digest(as.list(truth[i]), algo = "sha256"), "")]
  # Perfis T1 diferentes chegam em ritmos distintos, com componente aleatória.
  arrival <- rank(mu + rnorm(length(mu), 0, .8), ties.method = "first")
  truth <- truth[order(arrival)]
  data.table::fwrite(truth, file.path(folder, "truth.csv"))
  jsonlite::write_json(cfg, file.path(folder, "config.json"), auto_unbox = TRUE, pretty = TRUE)
  scenario <- list(kind = "pet_synthetic_replay", seed = p$seed, sections = nrow(truth),
    sections_per_uf = n, fractions = c(0, .005, .01, .02, .05, seq(.10, 1, .05)),
    true_share_a = 100 * sum(truth$votos_a) / sum(truth$validos),
    historical_state_id = original$id,
    notes = "T1, BUs e ordem de chegada fictícios; ajuste histórico e prior V2 do modelo existente.",
    hashes = lapply(c("inventory.csv", "truth.csv", "t1.parquet"), function(name)
      list(file = name, sha256 = hash_arquivo_analise(file.path(folder, name)))))
  jsonlite::write_json(scenario, file.path(folder, "scenario.json"), auto_unbox = TRUE,
                       pretty = TRUE, digits = 12)
  invisible(scenario)
}

snapshot_checkpoint_site <- function(cp, p) {
  synthetic <- any(grepl("PET SYNTHETIC REPLAY", unlist(cp$snapshot_manifest$notes), fixed = TRUE))
  exigir_analise(identical(p$mode == "demo", synthetic),
                "Modo incompatível com a origem: snapshot sintético não pode ser publicado como real")
  summary <- cp$results$resumo
  stopifnot(nrow(summary) == 1L,
            all(is.finite(unlist(summary[, c("pct_a_projetado", "pct_a_q025", "pct_a_q975"), with = FALSE]))))
  version <- sprintf("%s/%s/%s", summary$modelo, substr(hash_objeto_analise(cp$code_sha256), 1, 10),
                     substr(cp$initial_state_id, 1, 10))
  notes <- c(
    sprintf("Intervalo de 95%% produzido pelo executor com sorteios conjuntos dos %d coeficientes.", length(cp$posterior$mean)),
    "Condicionado ao modelo e às configurações preservadas nesta execução. Os quantis são exportados sem conversão do nível do intervalo.",
    sprintf("Fonte de totalização usada na projeção: %s. %s", summary$fonte_oficial,
      if (isTRUE(summary$ancora_oficial)) "Âncora oficial aplicada sem somar BR e UFs."
      else "Âncora oficial não aplicada: a projeção usa BUs coletados e modelo, pois os totais escolhidos não eram compatíveis com os BUs."),
    "Probabilidade de vitória ainda não exportada por esta integração."
  )
  if (p$mode == "demo") notes <- c("Simulação local: T1, BUs e candidaturas fictícios; usa o executor estatístico real.", notes)
  forecast <- exportar_previsao_site(file.path(p$runtime, "forecast.json"),
    snapshot_id = cp$snapshot_id, versao_modelo = version,
    percentual_a = summary$pct_a_projetado, limite_inferior = summary$pct_a_q025,
    limite_superior = summary$pct_a_q975, nivel_intervalo = .95,
    probabilidade_vitoria_a = NULL, notas = notes, calculado_utc = cp$created_utc)
  snapshot <- montar_snapshot_site(file.path(p$runtime, "snapshot-site.json"),
    cp$snapshot_manifest, cp$official_details$chosen, forecast, p$name_a, p$name_b)
  fields_2022 <- c("pct_a_2022", "pct_a_2022_q025", "pct_a_2022_q975")
  if (all(fields_2022 %in% names(summary))) {
    snapshot$forecast_2022 <- exportar_previsao_site(file.path(p$runtime, "forecast-2022.json"),
      snapshot_id = cp$snapshot_id, versao_modelo = paste0(version, "/2022"),
      percentual_a = summary$pct_a_2022, limite_inferior = summary$pct_a_2022_q025,
      limite_superior = summary$pct_a_2022_q975, nivel_intervalo = .95,
      probabilidade_vitoria_a = NULL, calculado_utc = cp$created_utc,
      notas = c("Cenário 2022: incorpora os votos apurados e projeta as seções pendentes com a relação histórica entre turnos, sem aprender com os BUs.",
        "Coeficientes, choques municipais e razão de votos válidos permanecem na prior, com a incerteza da mudança entre eleições.",
        "Usa o mesmo checkpoint, os mesmos BUs e a mesma âncora oficial do cenário com aprendizado.",
        "Intervalo de 95% condicionado às hipóteses deste cenário; não é uma probabilidade do cenário."))
    snapshot$forecast_2022$generated_at <- snapshot$forecast$generated_at
    snapshot$forecast$notes <- c("Cenário com aprendizado: atualiza a relação entre turnos com os BUs apurados, com atualização gradual até 15% dos válidos T1.", snapshot$forecast$notes)
  }
  if (p$mode == "demo") {
    snapshot$mode <- "demo"
    snapshot$counting$source$name <- "Simulação local"
    snapshot$counting$source$area <- "DEMO"
  }
  snapshot$snapshot_id <- paste0("cp-", cp$id, "-",
    substr(hash_objeto_analise(snapshot[setdiff(names(snapshot), "snapshot_id")]), 1, 16))
  # O publicador Python valida e publica este objeto antes de servi-lo.
  temp <- tempfile(".site-", tmpdir = p$runtime)
  on.exit(unlink(temp), add = TRUE)
  jsonlite::write_json(snapshot, temp, auto_unbox = TRUE, null = "null", digits = 12, pretty = TRUE)
  stopifnot(file.rename(temp, file.path(p$runtime, "snapshot-site.json")))
  invisible(snapshot)
}

pipeline_site_main <- function(args) {
  stopifnot(length(args) == 2L)
  p <- jsonlite::read_json(args[2], simplifyVector = TRUE)
  stopifnot(p$mode %in% c("demo", "tse"), dir.exists(p$model_dir))
  if (args[1] == "fixture") return(preparar_fixture_site(p))
  if (args[1] == "inicializar") {
    stopifnot(p$mode == "demo")
    return(inicializar_analise(p$initial_state, p$variant_fit,
      file.path(p$runtime, "fixture/t1.parquet"), file.path(p$runtime, "fixture/config.json"), p$source))
  }
  stopifnot(args[1] == "atualizar")
  input_manifest <- jsonlite::read_json(file.path(p$source, "manifest.json"), simplifyVector = TRUE)
  synthetic <- any(grepl("PET SYNTHETIC REPLAY", unlist(input_manifest$notes), fixed = TRUE))
  exigir_analise(identical(p$mode == "demo", synthetic), "Fonte fictícia/real incompatível com o modo solicitado")
  state <- carregar_ponto_partida_analise(p$initial_state)
  com_lock_executor_analise(file.path(p$runtime, "model"), {
    cp <- carregar_checkpoint_previsao(file.path(p$runtime, "model"), state)
    step <- avancar_previsao_analise(state, p$source, file.path(p$runtime, "model"), cp,
      sorteios = as.integer(p$draws), semente = as.integer(p$seed), manter = 3L)
    cp <- step$checkpoint
    snapshot_checkpoint_site(cp, p)
    event <- list(checkpoint_id = cp$id, source_snapshot_id = cp$snapshot_id,
      processed = step$processado, sequence = cp$sequence, sections = cp$results$resumo$secoes,
      observed_sections = cp$results$resumo$secoes_apuradas_coletor,
      regression_sections = cp$results$resumo$secoes_regressao,
      share_a = cp$results$resumo$pct_a_projetado,
      lower = cp$results$resumo$pct_a_q025, upper = cp$results$resumo$pct_a_q975,
      source_area = cp$official_details$chosen$area,
      code_sha256 = cp$code_sha256, initial_state_id = cp$initial_state_id)
    if ("pct_a_2022" %in% names(cp$results$resumo)) {
      event$share_a_2022 <- cp$results$resumo$pct_a_2022
      event$lower_2022 <- cp$results$resumo$pct_a_2022_q025
      event$upper_2022 <- cp$results$resumo$pct_a_2022_q975
    }
    jsonlite::write_json(event, file.path(p$runtime, "pipeline-result.json"),
      auto_unbox = TRUE, pretty = TRUE, digits = 12)
    exportar_relatorio_local(cp, state, p)
    cat(jsonlite::toJSON(event[1:11], auto_unbox = TRUE), "\n")
  })
}

exportar_relatorio_local <- function(cp, state, p) {
  summary <- cp$results$resumo
  ufs <- cp$results$uf
  j <- grep("^comparecimento_", state$prior$names)
  scale <- state$prior$spec$scale["taxa_comparecimento"]
  slopes <- data.table(uf = state$prior$levels,
    log_odds_por_1pp = cp$posterior$mean[j] * .01 / scale,
    dp_log_odds_por_1pp = sqrt(diag(cp$posterior$covariance)[j]) * .01 / scale)
  local_pointer <- jsonlite::read_json(file.path(p$runtime, "model/latest.json"), simplifyVector = TRUE)
  sections <- data.table::fread(file.path(p$runtime, "model/pacotes", local_pointer$package, "secoes.csv"))
  places <- data.table::fread(p$country_map)
  d <- merge(sections[uf == "ZZ"], places, by = "cd_mun", all = FALSE)
  base <- state$population[, c(chaves_analise, "validos_base"), with = FALSE]
  d <- merge(d, base, by = chaves_analise, all.x = TRUE)
  loc <- cp$local
  ratio0 <- exp((loc$s0^2 + loc$sg^2 + loc$var_m + loc$var_i) / 2)
  d[, validos_2022 := fifelse(apurada, as.numeric(validos_observados), validos_base * ratio0)]
  countries <- d[, .(ordem = min(ordem), secoes = .N, apuradas = sum(apurada),
    learning = 100 * sum(votos_a_projetados) / sum(validos_projetados),
    historical = sum(pct_a_2022 * validos_2022) / sum(validos_2022)), by = pais]
  setorder(countries, ordem)
  report <- list(kind = "pet_local_turnout_uf", synthetic = p$mode == "demo",
    checked_at_utc = agora_analise(), generated_at_utc = cp$created_utc,
    checkpoint_id = cp$id, source_snapshot_id = cp$snapshot_id,
    initial_state_id = cp$initial_state_id, model = summary$modelo,
    coefficients = length(cp$posterior$mean), sections = summary$secoes,
    observed_sections = summary$secoes_apuradas_coletor,
    counting_sections = summary$secoes_totalizadas_tse, learning_weight = summary$peso_atualizacao,
    national = list(learning = list(share = summary$pct_a_projetado,
      lower = summary$pct_a_q025, upper = summary$pct_a_q975),
      historical = list(share = summary$pct_a_2022,
      lower = summary$pct_a_2022_q025, upper = summary$pct_a_2022_q975)),
    ufs = ufs[, .(uf, sections = secoes, observed = secoes_apuradas_coletor,
      learning = pct_a_projetado, lower = pct_a_q025, upper = pct_a_q975,
      historical = pct_a_2022, historical_lower = pct_a_2022_q025, historical_upper = pct_a_2022_q975)],
    countries = countries, turnout_coefficients = slopes)
  temp <- tempfile(".report-", tmpdir = p$runtime)
  jsonlite::write_json(report, temp, auto_unbox = TRUE, na = "null", null = "null", digits = 12)
  stopifnot(file.rename(temp, file.path(p$runtime, "local-report.json")))
  invisible(report)
}

if (sys.nframe() == 0L) {
  script <- sub("^--file=", "", commandArgs(FALSE)[grepl("^--file=", commandArgs(FALSE))][1])
  params <- jsonlite::read_json(commandArgs(TRUE)[2], simplifyVector = TRUE)
  source(file.path(params$repo, "integracao/exportar_previsao_site.R"), encoding = "UTF-8")
  # O módulo identifica suas próprias fontes com sys.frame(1)$ofile:
  # carregá-lo no nível superior preserva esse contrato de source().
  source(file.path(params$model_source, "previsao_execucao.R"), encoding = "UTF-8")
  tryCatch({pipeline_site_main(commandArgs(TRUE)); invisible(NULL)}, error = function(e) {
    message(conditionMessage(e)); quit(status = 1L)
  })
}
