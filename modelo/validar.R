args_all <- commandArgs(FALSE)
root <- dirname(normalizePath(sub("^--file=", "", args_all[grepl("^--file=", args_all)])[1]))
source(file.path(root, "modelo.R"), encoding = "UTF-8")
out <- file.path(root, "output", "validacao")
dir.create(out, recursive = TRUE, showWarnings = FALSE)
checks <- list()
check <- function(name, condition) {
  checks[[length(checks) + 1L]] <<- data.table(verificacao = name, passou = isTRUE(condition))
  if (!isTRUE(condition)) stop(name)
}
fails <- function(expr) inherits(tryCatch(force(expr), error = identity), "error")
b <- data.table(uf = c("AC", "AC", "SP"), cd_mun = c(1007L, 1007L, 71072L),
  zona = c(1L, 1L, 2L), secao = c(1L, 2L, 1L), aptos = c(100, 200, 300),
  pct_lula_t1 = c(40, 60, 50), p_raw = c(.4, .6, .5), p_base = c(.4, .6, .5),
  validos_base = c(100, 200, 300), fallback = "nenhum")
o <- b[, c(chave, "aptos"), with = FALSE]
o[, `:=`(validos = c(100, 200, 250), votos_a = c(50, 160, 120), votos_b = c(50, 40, 130))]
none <- atualizar_previsao(b)$resumo
check("Sem BUs reproduz a agregação ponderada", abs(none$pct_a_projetado - 100 * 310 / 600) < 1e-10)
all <- atualizar_previsao(b, o)$resumo
check("Com 100% coincide com os votos observados", abs(all$pct_a_projetado - 100 * 330 / 550) < 1e-10)
check("Com 100% o cenário de sensibilidade colapsa", all$pct_a_cenario_mais2 == all$pct_a_cenario_menos2)
check("Candidatos somam o total válido", all$votos_a_projetados + all$votos_b_projetados == 550)
check("Duplicata é rejeitada", fails(atualizar_previsao(b, rbind(o, o[1]))))
bad <- copy(o); bad[1, votos_a := -1]
check("Voto negativo é rejeitado", fails(atualizar_previsao(b, bad)))
bad <- copy(o); bad[1, validos := 99]
check("Denominador inconsistente é rejeitado", fails(atualizar_previsao(b, bad)))
zero <- copy(o); zero[1, `:=`(validos = 0, votos_a = 0, votos_b = 0)]
check("BU com zero válidos conta como apurado", atualizar_previsao(b, zero)$resumo$secoes_apuradas_coletor == 3)
correction <- copy(o); correction[1, `:=`(votos_a = 40, votos_b = 60)]
check("Versão corrigida substitui o resultado", atualizar_previsao(b, correction)$resumo$votos_a_observados == 320)
partial <- atualizar_previsao(b, o[1])
check("Votos observados não são alterados pela calibração", partial$secoes[apurada == TRUE, a_final] == 50)
check("UF sem BU mantém previsão histórica", all(partial$secoes[uf == "SP", p_atual == p_base]))
inventory <- rbind(b[, ..chave], data.table(uf = "AC", cd_mun = 1007L, zona = 1L, secao = 3L))
aligned <- alinhar_inventario(b, inventory)
check("Seção sem T1 recebe fallback explícito", nrow(aligned) == 4 && sum(aligned$fallback != "nenhum") == 1)

# Ensaio fora do ajuste por MUNICÍPIOS. A eleição continua sendo a de 2022.
# A ordem de chegada abaixo é simulada e identificada como tal.
raw <- file.path(root, "..", "data", "eleicoes_2022_2026", "raw")
t1 <- as.data.table(arrow::read_parquet(file.path(raw, "section_votes_2022_T1.parquet")))
t2 <- as.data.table(arrow::read_parquet(file.path(raw, "section_votes_2022_T2.parquet")))
municipios <- unique(t1[, .(uf, cd_mun)])[order(uf, cd_mun)]
municipios[, teste := seq_len(.N) %% 5L == 0L, by = uf]
test_keys <- municipios[teste == TRUE, .(uf, cd_mun)]
fit <- ajustar_modelo(t1[!test_keys, on = .(uf, cd_mun)], t2[!test_keys, on = .(uf, cd_mun)])
test <- merge(t1[test_keys, on = .(uf, cd_mun)], t2[, c(chave, "validos", "c13", "c22", "aptos"), with = FALSE],
  by = chave, suffixes = c("", "_t2"))
base <- prever_base(fit, test)
truth <- test[, c(chave, "aptos_t2", "validos_t2", "c13_t2", "c22_t2"), with = FALSE]
setnames(truth, c("aptos_t2", "validos_t2", "c13_t2", "c22_t2"), c("aptos", "validos", "votos_a", "votos_b"))
truth <- merge(base[, c(chave, "p_base"), with = FALSE], truth, by = chave)
target <- 100 * sum(truth$votos_a) / sum(truth$validos)
set.seed(618320)
orders <- list(aleatoria = sample.int(nrow(truth)),
  secoes_menor_lula_t1_primeiro = order(truth$p_base),
  secoes_maior_lula_t1_primeiro = order(-truth$p_base))
results <- list()
for (scenario in names(orders)) {
  for (fraction in c(0, .01, .05, .1, .25, .5, .75, .9, .99, 1)) {
    n <- floor(nrow(truth) * fraction)
    observed <- truth[orders[[scenario]][seq_len(n)]][, p_base := NULL]
    forecast <- atualizar_previsao(base, observed)$resumo
    frozen <- atualizar_previsao(base, observed, k_votos = 1e15)$resumo
    results[[length(results) + 1L]] <- data.table(ordem_simulada = scenario, fracao_secoes = fraction,
      secoes = nrow(truth), municipios_teste = nrow(test_keys), pct_real = target,
      pct_apurado = forecast$pct_a_apurado, pct_previsao = forecast$pct_a_projetado,
      pct_modelo_sem_recalibrar = frozen$pct_a_projetado,
      erro_previsao_pp = forecast$pct_a_projetado - target,
      erro_apurado_pp = forecast$pct_a_apurado - target,
      cenario_menos2 = forecast$pct_a_cenario_menos2, cenario_mais2 = forecast$pct_a_cenario_mais2)
  }
}
replay <- rbindlist(results)
check("Ensaio termina no resultado observado em todas as ordens", all(abs(replay[fracao_secoes == 1, erro_previsao_pp]) < 1e-10))
fwrite(replay, file.path(out, "ensaio_2022.csv"))
fwrite(rbindlist(checks), file.path(out, "checks_R.csv"))
grDevices::pdf(file.path(out, "figura_1_ensaio_2022.pdf"), width = 10, height = 7)
par(mfrow = c(3, 1), mar = c(3, 4, 2, 1))
for (scenario in names(orders)) {
  d <- replay[ordem_simulada == scenario]
  plot(100 * d$fracao_secoes, d$pct_previsao, type = "l", col = "#1d4ed8", lwd = 2,
    ylim = range(c(d$pct_previsao, d$pct_apurado, target), na.rm = TRUE),
    xlab = "Seções recebidas (%; ordem simulada)", ylab = "Lula (% dos válidos)", main = scenario)
  lines(100 * d$fracao_secoes, d$pct_apurado, col = "#b45309", lty = 2)
  abline(h = target, col = "#047857", lty = 3)
  if (scenario == "aleatoria") legend("topright", c("Previsão atualizada", "Apurado", "Resultado final"),
    col = c("#1d4ed8", "#b45309", "#047857"), lty = c(1, 2, 3), bty = "n", cex = .8)
}
dev.off()
print(rbindlist(checks))
print(replay[fracao_secoes %in% c(0, .1, .5, 1)])
