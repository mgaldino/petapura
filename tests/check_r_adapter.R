# Teste de interoperabilidade. Dados sintéticos, sem executar o modelo.
source("integracao/exportar_previsao_site.R", encoding = "UTF-8")
args <- commandArgs(trailingOnly = TRUE)
stopifnot(length(args) == 1L)
manifesto <- list(snapshot_id = "r-fixture", published_utc = "2026-10-20T12:00:00+00:00",
  observed_sections = 0L, identity = list(year = 2026L, round = 2L, election = 6258L, pleito = 3221L),
  candidate_columns = list(votos_a = 13L, votos_b = 22L))
totais <- list(ts = 10000L, st = 0L, votos_a = 0L, votos_b = 0L, validos = 0L,
  area = "BR", generated = "2026-10-20T09:00:00")
previsao <- exportar_previsao_site(paste0(args[[1]], ".forecast.json"), "r-fixture", "teste-R",
  51.4, 47.5, 55.3, .95, NULL, notas = "Dados sintéticos de teste",
  calculado_utc = "2026-10-20T12:01:00.123456Z")
montar_snapshot_site(args[[1]], manifesto, totais, previsao)
resultado <- jsonlite::fromJSON(args[[1]], simplifyVector = FALSE)
stopifnot(resultado$forecast$interval$level == .95,
          is.null(resultado$forecast$win_probability_a),
          resultado$counting$reported_sections == 0L)
cat("Saída R com intervalo de 95%, probabilidade nula e zero BUs verificada.\n")
