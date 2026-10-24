args_all <- commandArgs(FALSE)
script <- sub("^--file=", "", args_all[grepl("^--file=", args_all)])[1]
root <- dirname(normalizePath(script))
source(file.path(root, "modelo.R"), encoding = "UTF-8")
args <- commandArgs(TRUE)
state <- if (length(args)) args[1] else file.path(root, "data", "live")
dir.create(state, recursive = TRUE, showWarnings = FALSE)
base <- fread(file.path(root, "data", "processed", "baseline_2026.csv"))
inventory <- file.path(state, "inventory.csv")
if (file.exists(inventory)) base <- alinhar_inventario(base, fread(inventory))
obs_file <- file.path(state, "observed.csv")
observed <- if (file.exists(obs_file)) fread(obs_file) else observado_vazio()
if (!nrow(observed)) observed <- observado_vazio()
result <- atualizar_previsao(base, observed)
result$resumo[, atualizado_utc := format(Sys.time(), tz = "UTC", usetz = TRUE)]
status_file <- file.path(state, "status.json")
status <- if (file.exists(status_file)) jsonlite::fromJSON(status_file) else NULL
official_file <- file.path(state, "official.json")
official <- if (file.exists(official_file) && isTRUE(status$official_current))
  jsonlite::fromJSON(official_file, simplifyVector = FALSE) else NULL
result$resumo[, secoes_totalizadas_tse := if (!is.null(official)) as.numeric(official$s$st) else NA_real_]
result$resumo[, atraso_coleta_secoes := secoes_totalizadas_tse - secoes_apuradas_coletor]
out <- file.path(state, "output")
dir.create(out, recursive = TRUE, showWarnings = FALSE)
write_atomic <- function(d, path) {
  temp <- paste0(path, ".tmp")
  fwrite(d, temp)
  stopifnot(file.rename(temp, path))
}
write_atomic(result$resumo, file.path(out, "previsao_atual.csv"))
write_atomic(result$uf, file.path(out, "previsao_uf.csv"))
write_atomic(result$calibration, file.path(out, "calibracao_uf.csv"))
write_atomic(result$secoes[fallback != "nenhum", c(chave, "fallback", "p_base", "validos_base"), with = FALSE],
  file.path(out, "secoes_com_aproximacao_t1.csv"))
history <- file.path(out, "historico.csv")
if (file.exists(history)) result_history <- rbind(fread(history), result$resumo, fill = TRUE) else result_history <- result$resumo
write_atomic(result_history, history)
# HTML local com reload: resultados da coleta ficam separados do ensaio histórico.
cfg <- jsonlite::fromJSON(file.path(root, "config.json"))
s <- result$resumo[1]
fmt <- function(x, digits = 2) ifelse(is.na(x), "indisponível", format(round(x, digits), big.mark = ".", decimal.mark = ",", nsmall = digits))
rows <- paste(sprintf("<tr><td>%s</td><td>%s</td><td>%s</td><td>%s%%</td></tr>",
  result$uf$uf, result$uf$secoes_apuradas_coletor, result$uf$secoes, fmt(result$uf$pct_a_projetado)), collapse = "\n")
chart <- ""
if (nrow(result_history) > 1) {
  grDevices::svg(file.path(out, "trajetoria.svg"), width = 9, height = 4)
  plot(seq_len(nrow(result_history)), result_history$pct_a_projetado, type = "l", col = "#1d4ed8",
    xlab = "Atualização", ylab = paste(cfg$label_a, "(% dos votos válidos projetados)"),
    main = "Figura 1. Trajetória da previsão", ylim = range(c(result_history$pct_a_projetado, 50)))
  abline(h = 50, col = "gray50", lty = 2)
  dev.off()
  chart <- '<img src="trajetoria.svg" alt="Figura 1. Previsão ao longo das atualizações">'
}
html <- sprintf('<!doctype html><html lang="pt-BR"><meta charset="utf-8"><meta http-equiv="refresh" content="30"><title>Previsão eleitoral por seção</title>
<style>body{font:18px system-ui;max-width:1000px;margin:40px auto;padding:0 20px;color:#172033;background:#f8fafc}h1{font-size:30px}.number{font-size:40px;font-weight:700}table{border-collapse:collapse;width:100%%}td,th{padding:8px;text-align:right;border-bottom:1px solid #ccd}td:first-child,th:first-child{text-align:left}img{width:100%%}.note{background:#e2e8f0;padding:16px}</style>
<h1>Previsão do segundo turno por seção</h1><p class="note">%s. Previsão didática condicionada ao modelo histórico e aos boletins baixados. Atualização: %s.</p>
<p class="number">%s: %s%% · %s: %s%%</p>
<p>Apurado nos BUs coletados: %s%% para %s. Seções coletadas: %s / %s (%s%%). Seções totalizadas no TSE: %s. Diferença TSE − coletor: %s.</p>
<p>Cenário de erro de ±2 p.p. nas seções pendentes: %s%% a %s%% para %s. Esta faixa é uma análise de sensibilidade; não é intervalo de confiança nem probabilidade de vitória.</p>
<p>Seções com preditor ausente ou sem votos válidos no T1: %s. Sua composição é aproximada pela zona/UF e identificada no código.</p>%s
<h2>Tabela 1. Projeção por UF, incluindo exterior (ZZ)</h2><table><tr><th>UF</th><th>Seções coletadas</th><th>Seções previstas</th><th>%s projetado</th></tr>%s</table>
<p>Fonte: TSE; cálculos do laboratório. Denominador: votos válidos projetados no segundo turno. Os dois candidatos somam 100%%. A coleta pode estar atrasada; consulte status.json e os manifestos.</p></html>',
  if (s$secoes_apuradas_coletor == 0) "PREVISÃO ANTES DA APURAÇÃO" else "APURAÇÃO EM ACOMPANHAMENTO",
  s$atualizado_utc, cfg$label_a, fmt(s$pct_a_projetado), cfg$label_b, fmt(100 - s$pct_a_projetado),
  fmt(s$pct_a_apurado), cfg$label_a, fmt(s$secoes_apuradas_coletor, 0), fmt(s$secoes, 0), fmt(s$pct_secoes_coletor),
  fmt(s$secoes_totalizadas_tse, 0), fmt(s$atraso_coleta_secoes, 0), fmt(s$pct_a_cenario_menos2), fmt(s$pct_a_cenario_mais2), cfg$label_a,
  fmt(s$fallback_t1, 0), chart, cfg$label_a, rows)
temp <- file.path(out, "painel.html.tmp")
writeLines(html, temp, useBytes = TRUE)
stopifnot(file.rename(temp, file.path(out, "painel.html")))
print(result$resumo)
