# Executar uma vez; caminhos independentes do diretório de trabalho.
args_all <- commandArgs(FALSE)
script <- sub("^--file=", "", args_all[grepl("^--file=", args_all)])[1]
root <- dirname(normalizePath(script))
source(file.path(root, "modelo.R"), encoding = "UTF-8")
raw <- file.path(root, "..", "data", "eleicoes_2022_2026", "raw")
read_section <- function(name) as.data.table(arrow::read_parquet(file.path(raw, name)))
t1 <- read_section("section_votes_2022_T1.parquet")
t2 <- read_section("section_votes_2022_T2.parquet")
target <- read_section("section_votes_2026_T1_bu.parquet")
fit <- ajustar_modelo(t1, t2)
base <- prever_base(fit, target)
out <- file.path(root, "data", "processed")
dir.create(out, recursive = TRUE, showWarnings = FALSE)
saveRDS(fit[c("modelo", "turnout", "diagnostico")], file.path(out, "modelo_2022.rds"))
fwrite(base, file.path(out, "baseline_2026.csv"))
fwrite(fit$diagnostico, file.path(out, "diagnostico_treino.csv"))
fwrite(data.table(termo = names(coef(fit$modelo)), estimativa = unname(coef(fit$modelo))),
  file.path(out, "coeficientes.csv"))
fwrite(data.table(uf = base$uf, fora_0_100 = base$p_raw < 0 | base$p_raw > 1)[,
  .(secoes = .N, previsoes_limitadas = sum(fora_0_100)), by = uf], file.path(out, "limites_previsoes.csv"))
# Cada fonte liga o artefato ao snapshot já preservado no curso.
files <- c(file.path(raw, c("section_votes_2022_T1.parquet", "section_votes_2022_T2.parquet",
  "section_votes_2026_T1_bu.parquet")), file.path(root, c("modelo.R", "preparar.R", "spec/bu.asn1")))
fwrite(data.table(arquivo = normalizePath(files), md5 = unname(tools::md5sum(files)),
  acesso_utc = format(Sys.time(), tz = "UTC", usetz = TRUE)), file.path(out, "manifesto_entradas.csv"))
print(fit$diagnostico)
print(atualizar_previsao(base)$resumo)
