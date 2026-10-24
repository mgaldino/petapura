args_all <- commandArgs(FALSE)
root <- dirname(normalizePath(sub("^--file=", "", args_all[grepl("^--file=", args_all)])[1]))
source(file.path(root, "bayes.R"), encoding = "UTF-8")
source(file.path(root, "voto_t1.R"), encoding = "UTF-8")
args <- commandArgs(TRUE)
state <- if (length(args)) args[1] else file.path(root, "data", "live")
dir.create(state, recursive = TRUE, showWarnings = FALSE)
fits <- readRDS(file.path(root, "data", "processed", "voto_t1_fits.rds"))
stopifnot(all(vapply(fits, function(f) isTRUE(f$gate$pass), TRUE)))
base <- fread(file.path(root, "data", "processed", "voto_t1_baseline_2026.csv"))
inventory <- file.path(state, "inventory.csv")
if (file.exists(inventory)) base <- align_voto_t1(base, fread(inventory))
obs_file <- file.path(state, "observed.csv")
observed <- if (file.exists(obs_file)) fread(obs_file) else data.table()
if (!nrow(observed)) observed <- data.table(uf = character(), cd_mun = integer(), zona = integer(), secao = integer(),
  aptos = numeric(), comparecimento = numeric(), validos = numeric(), votos_a = numeric(), votos_b = numeric(), brancos = numeric(), nulos = numeric())
result <- voto_nowcast(fits$lula, base, observed)
source(file.path(root, "ancorar.R"), encoding = "UTF-8")
selected_file <- file.path(state, "official_selected.json")
official <- if (file.exists(selected_file)) jsonlite::fromJSON(selected_file, simplifyVector = FALSE) else NULL
s <- ancorar_oficial(result, official)
s[, atualizado_utc := format(Sys.time(), tz = "UTC", usetz = TRUE)]
s[, `:=`(modelo_ativo="voto_t1_inclinacao_por_uf",preditor_comparecimento="primeiro_turno",
  peso_secoes_pendentes="validos_primeiro_turno")]
out <- file.path(state, "bayes_output")
dir.create(out, recursive = TRUE, showWarnings = FALSE)
atomic_csv <- function(d, name) {
  path <- file.path(out, name); fwrite(d, paste0(path, ".tmp")); stopifnot(file.rename(paste0(path, ".tmp"), path))
}
atomic_csv(s, "previsao_atual.csv")
atomic_csv(result$uf, "previsao_uf_somente_bu.csv")
atomic_csv(result$posterior, "posterior_somente_bu.csv")
atomic_csv(result$secoes[fallback != "nenhum", c(keys, "fallback"), with = FALSE], "secoes_com_aproximacao_t1.csv")
atomic_csv(rbindlist(lapply(names(result$shifts), function(name) data.table(componente = name,
  uf = result$shifts[[name]]$levels, media_shift_logit = result$shifts[[name]]$mean,
  dp_shift_logit = sqrt(diag(result$shifts[[name]]$covariance)), n = result$shifts[[name]]$n))), "calibracao_uf.csv")
history <- file.path(out, "historico.csv")
atomic_csv(if (file.exists(history)) rbind(fread(history), s, fill = TRUE) else s, "historico.csv")
cfg <- jsonlite::fromJSON(file.path(root, "config.json"))
fmt <- function(x, d = 2) ifelse(is.na(x), "indisponível", format(round(x, d), big.mark = ".", decimal.mark = ",", nsmall = d))
rows <- paste(sprintf("<tr><td>%s</td><td>%s</td><td>%s</td><td>%s%%</td></tr>", result$uf$uf,
  result$uf$secoes_apuradas_coletor, result$uf$secoes, fmt(result$uf$pct_a_projetado)), collapse = "\n")
html <- sprintf('<!doctype html><html lang="pt-BR"><meta charset="utf-8"><meta http-equiv="refresh" content="30"><title>Previsão bayesiana por seção</title>
<style>body{font:18px system-ui;max-width:1050px;margin:36px auto;padding:0 20px;color:#172033;background:#f8fafc}.number{font-size:36px;font-weight:700}table{border-collapse:collapse;width:100%%}td,th{padding:8px;text-align:right;border-bottom:1px solid #ccd}td:first-child,th:first-child{text-align:left}.note{background:#e2e8f0;padding:16px}</style>
<h1>Previsão hierárquica bayesiana por seção</h1><p class="note">%s. Atualização: %s. Treino histórico: 2022. Aplicação: segundo turno de 2026.</p>
<p class="number">%s: %s%% · %s: %s%%</p>
<p>Faixa de 95%% do procedimento modular: %s%% a %s%% para %s. Condicionada ao modelo, às priors de mudança entre eleições e à aproximação da âncora oficial. Não certifica cobertura sob erro estrutural ou seleção da apuração.</p>
<p>Fonte oficial escolhida: <strong>%s</strong>. Apurado oficial: %s%% para %s. TSE: %s seções totalizadas; coletor: %s de %s. Atraso do coletor: %s. Avanço da soma estadual sobre o nacional: %s seções.</p>
<p>Previsão usando apenas os BUs coletados: %s%%. Âncora de totais oficiais aplicada: %s. Os totais observados entram uma única vez; a composição das seções oficialmente apuradas mas ainda não baixadas exige aproximação.</p>
<p>Seções sem preditor T1 utilizável: %s, com médias da zona/UF. Resposta: votação no segundo turno. O comparecimento do primeiro turno é preditor, com coeficiente comum; intercepto e inclinação do voto T1 variam por UF. Nas seções pendentes, os votos válidos T1 são pesos fixos. O BU substitui previsão e peso pelos votos efetivos. Não há regressão para prever comparecimento.</p>
<h2>Tabela 1. Projeção por UF usando BUs coletados</h2><table><tr><th>UF</th><th>BUs coletados</th><th>Seções previstas</th><th>%s projetado</th></tr>%s</table>
<p>Fonte: TSE. Denominador: votos válidos projetados no segundo turno. Consulte as fontes brutas, os horários de geração e os diagnósticos em disco. ZZ indica exterior.</p></html>',
  if (s$secoes_apuradas_coletor == 0) "ANTES DA APURAÇÃO" else "APURAÇÃO EM ACOMPANHAMENTO", s$atualizado_utc,
  cfg$label_a, fmt(s$pct_a_projetado), cfg$label_b, fmt(100 - s$pct_a_projetado), fmt(s$pct_a_q025), fmt(s$pct_a_q975), cfg$label_a,
  s$fonte_oficial, fmt(s$pct_a_apurado_oficial), cfg$label_a, fmt(s$secoes_totalizadas_tse, 0),
  fmt(s$secoes_apuradas_coletor, 0), fmt(s$secoes, 0), fmt(s$atraso_coleta_secoes, 0), fmt(s$atraso_nacional_secoes, 0),
  fmt(s$pct_a_somente_bu), ifelse(s$ancora_oficial, "sim", "não"), fmt(s$fallback_t1, 0), cfg$label_a, rows)
writeLines(html, file.path(out, "painel.html.tmp"), useBytes = TRUE)
stopifnot(file.rename(file.path(out, "painel.html.tmp"), file.path(out, "painel.html")))
print(s)
