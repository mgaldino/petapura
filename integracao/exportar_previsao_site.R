# Adaptador de saída. Não estima parâmetros nem altera o modelo.
# Requer jsonlite, já usado pelo módulo de previsão existente.
exportar_previsao_site <- function(caminho, snapshot_id, versao_modelo,
                                  percentual_a, limite_inferior, limite_superior,
                                  nivel_intervalo, probabilidade_vitoria_a = NULL,
                                  notas = character(), calculado_utc = NULL) {
  stopifnot(is.character(snapshot_id), length(snapshot_id) == 1L,
            nzchar(snapshot_id), is.character(versao_modelo), nzchar(versao_modelo),
            all(is.finite(c(percentual_a, limite_inferior, limite_superior, nivel_intervalo))),
            percentual_a >= 0, percentual_a <= 100,
            limite_inferior >= 0, limite_superior <= 100,
            limite_inferior <= limite_superior,
            nivel_intervalo >= .01, nivel_intervalo <= .999,
            is.null(probabilidade_vitoria_a) ||
              (length(probabilidade_vitoria_a) == 1L && is.finite(probabilidade_vitoria_a) &&
               probabilidade_vitoria_a >= 0 && probabilidade_vitoria_a <= 1))
  if (is.null(calculado_utc)) calculado_utc <- format(Sys.time(), "%Y-%m-%dT%H:%M:%OS3Z", tz = "UTC")
  saida <- list(model_version = versao_modelo, source_snapshot_id = snapshot_id,
                generated_at = calculado_utc, share_a = percentual_a,
                interval = list(level = nivel_intervalo, lower = limite_inferior,
                                upper = limite_superior),
                win_probability_a = probabilidade_vitoria_a, notes = as.list(notas))
  dir.create(dirname(caminho), recursive = TRUE, showWarnings = FALSE)
  temporario <- tempfile(pattern = ".previsao-site-", tmpdir = dirname(caminho))
  on.exit(unlink(temporario), add = TRUE)
  jsonlite::write_json(saida, temporario, auto_unbox = TRUE, null = "null", digits = 12,
                      pretty = TRUE)
  if (!file.rename(temporario, caminho)) stop("Não foi possível publicar a previsão do site")
  invisible(saida)
}

# Usa os objetos do snapshot já lido pelo executor, sem reler o ponteiro vivo.
# O JSON completo deve passar por scripts/publish_snapshot.py antes de servir.
# `apurado` (secoes, votos_a, votos_b) são os BUs incorporados pelo modelo, com status
# Recebido ou Totalizado. Quando informado, substitui a totalização oficial no parcial.
# `apurado$pct_a_sem_aprendizado`, opcional, é a previsão da priori para essas seções.
montar_snapshot_site <- function(caminho, manifesto, totalizacao_escolhida,
                                previsao = NULL, nome_a = "Candidata A", nome_b = "Candidato B",
                                apurado = NULL) {
  utc <- function(x) {
    if (!grepl("(Z|\\+00:00)$", x)) stop("Horário precisa estar explicitamente em UTC")
    valor <- as.POSIXct(sub("(Z|\\+00:00)$", "", x), format = "%Y-%m-%dT%H:%M:%OS", tz = "UTC")
    if (is.na(valor)) stop("Horário inválido")
    format(valor, "%Y-%m-%dT%H:%M:%OS6Z", tz = "UTC")
  }
  observado_utc <- utc(manifesto$published_utc)
  gerado_utc <- observado_utc
  if (!is.null(previsao)) {
    stopifnot(identical(previsao$source_snapshot_id, manifesto$snapshot_id))
    previsao$generated_at <- utc(previsao$generated_at)
    gerado_utc <- max(observado_utc, previsao$generated_at)
  }
  c <- totalizacao_escolhida
  if (!is.null(apurado)) {
    c$st <- as.integer(apurado$secoes)
    c$votos_a <- as.integer(apurado$votos_a)
    c$votos_b <- as.integer(apurado$votos_b)
    c$validos <- c$votos_a + c$votos_b
  }
  contagem <- if (c$ts > 0) list(total_sections = c$ts, reported_sections = c$st,
    collected_sections = manifesto$observed_sections, votes_a = c$votos_a,
    votes_b = c$votos_b, valid_votes = c$validos, generated_at = observado_utc,
    source = list(name = "TSE", area = c$area, generated_raw = c$generated)) else NULL
  if (!is.null(contagem) && !is.null(apurado$pct_a_sem_aprendizado))
    contagem$prior_share_a <- apurado$pct_a_sem_aprendizado
  temporario <- tempfile(pattern = "site-assinatura-")
  on.exit(unlink(temporario), add = TRUE)
  jsonlite::write_json(previsao, temporario, auto_unbox = TRUE, null = "null", digits = 12)
  assinatura <- unname(tools::md5sum(temporario))
  saida <- list(version = 1L, snapshot_id = paste0(manifesto$snapshot_id, "-", assinatura),
    source_snapshot_id = manifesto$snapshot_id, generated_at = gerado_utc, mode = "live",
    election = list(year = manifesto$identity$year, round = manifesto$identity$round,
      office = "president", election_id = as.character(manifesto$identity$election),
      pleito_id = as.character(manifesto$identity$pleito)),
    candidates = list(a = list(id = as.character(manifesto$candidate_columns$votos_a), name = nome_a),
                      b = list(id = as.character(manifesto$candidate_columns$votos_b), name = nome_b)),
    counting = contagem, forecast = previsao, history = list())
  dir.create(dirname(caminho), recursive = TRUE, showWarnings = FALSE)
  arquivo <- tempfile(pattern = ".snapshot-site-", tmpdir = dirname(caminho))
  on.exit(unlink(arquivo), add = TRUE)
  jsonlite::write_json(saida, arquivo, auto_unbox = TRUE, null = "null", digits = 12, pretty = TRUE)
  if (!file.rename(arquivo, caminho)) stop("Não foi possível salvar o snapshot completo")
  invisible(saida)
}
