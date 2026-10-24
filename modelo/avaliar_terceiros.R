args_all <- commandArgs(FALSE)
root <- dirname(normalizePath(sub("^--file=", "", args_all[grepl("^--file=", args_all)])[1]))
source(file.path(root, "bayes.R"), encoding = "UTF-8")
source(file.path(root, "terceiros.R"), encoding = "UTF-8")
raw <- file.path(root, "..", "data", "eleicoes_2022_2026", "raw")
read_input <- function(n) as.data.table(arrow::read_parquet(file.path(raw, n)))
t1 <- read_input("section_votes_2022_T1.parquet")
t2 <- read_input("section_votes_2022_T2.parquet")
d <- features_terceiros(t1, t2, year = 2022)[aptos > 0 & aptos_t2 > 0 & comparecimento > 0 & comp_t2 > 0 & validos > 0 & validos_t2 > 0]
m <- unique(d[, .(uf, cd_mun)])[order(uf, cd_mun)]
m[, teste := seq_len(.N) %% 5L == 0L, by = uf]
test_keys <- m[teste == TRUE, .(uf, cd_mun)]
train <- d[!test_keys, on = .(uf, cd_mun)]
test <- d[test_keys, on = .(uf, cd_mun)]
previous <- file.path(root, "output", "bayes_20261020")
out <- file.path(root, "output", "terceiros_20261020")
dir.create(out, recursive = TRUE, showWarnings = FALSE)
stan <- cmdstanr::cmdstan_model(file.path(root, "hierarquico.stan"), quiet = TRUE)
comp <- readRDS(file.path(previous, "validacao", "comp", "posterior.rds"))
test[, delta_comp := logistic_normal_mean(predict_latent(comp, test), mean_parameters(comp)$sigma) - taxa_comp_t1]
models <- list(atual = readRDS(file.path(previous, "validacao", "inclinacao", "posterior.rds")))
for (name in c("lula_terceiro", "lula_terceiro_quarto")) {
  message("Comparando: ", name)
  models[[name]] <- fit_bayes(train, name, TRUE, stan, file.path(out, "validacao", name))
  if (!isTRUE(models[[name]]$gate$pass)) stop("Diagnóstico insuficiente: ", name)
}
scores <- rbindlist(lapply(names(models), function(n) cbind(especificacao = n, bayes_score(models[[n]], test))))
fwrite(scores, file.path(out, "comparacao_2022.csv"))
fwrite(rbindlist(lapply(names(models), function(n) cbind(especificacao = n, as.data.table(models[[n]]$gate)))), file.path(out, "diagnosticos.csv"))
target <- features_terceiros(read_input("section_votes_2026_T1_bu.parquet"), year = 2026)
base <- fread(file.path(root, "data", "processed", "bayes_baseline_2026.csv"))
matched <- merge(target[, c(keys, "x_terceiro", "x_quarto", "validos"), with = FALSE], base, by = keys)
# Sensibilidade sobre o MODELO ATIVO: mudança exógena de contribuição líquida.
# Nenhuma dessas hipóteses recebe peso posterior ou vira a projeção central.
grid <- data.table(cenario = c("Relação histórica", "Só terceiro: -10 p.p.", "Só terceiro: -25 p.p.", "Só terceiro: -50 p.p.",
  "Terceiro e quarto: -10 p.p.", "Terceiro e quarto: -25 p.p.", "Terceiro e quarto: -50 p.p."),
  delta3 = c(0,-.1,-.25,-.5,-.1,-.25,-.5), delta4 = c(0,0,0,0,-.1,-.25,-.5))
zero <- list(comp = numeric(28), validos = numeric(28), lula = numeric(28))
fits <- readRDS(file.path(root, "data", "processed", "bayes_fits.rds"))
joint <- predict_joint(fits, matched, zero)
p <- joint$a / joint$validos
reference <- 100 * sum(joint$a) / sum(joint$validos)
scenarios <- rbindlist(lapply(seq_len(nrow(grid)), function(i) {
  adjusted <- ajuste_transferencia(p, matched$x_terceiro, matched$x_quarto, grid$delta3[i], grid$delta4[i])
  pct <- 100 * weighted.mean(adjusted, joint$validos)
  cbind(grid[i], data.table(pct_lula = pct, pct_flavio = 100-pct, mudanca_lula_pp = pct-reference,
    mudanca_margem_flavio_pp = -2*(pct-reference), secoes_com_t1 = nrow(matched),
    secoes_limitadas = sum(p + grid$delta3[i]*matched$x_terceiro + grid$delta4[i]*matched$x_quarto < 0 | p + grid$delta3[i]*matched$x_terceiro + grid$delta4[i]*matched$x_quarto > 1)))
}))
fwrite(scenarios, file.path(out, "cenarios_transferencia.csv"))
fwrite(data.table(peso_terceiro_validos_previstos = weighted.mean(matched$x_terceiro, joint$validos),
  peso_quarto_validos_previstos = weighted.mean(matched$x_quarto, joint$validos)), file.path(out, "pesos_cenarios.csv"))
print(scores); print(scenarios)
message("Preparando candidato com terceiro separado, sem alterar a operação")
final <- fit_bayes(d, "lula_terceiro", TRUE, stan, file.path(out, "final", "lula_terceiro"))
if (!isTRUE(final$gate$pass)) stop("Candidato final não passou os diagnósticos")
fwrite(as.data.table(final$gate),file.path(out,"diagnosticos_final.csv"))
candidate <- fits;candidate$lula <- final
# A seção sem válidos tem composição não identificada; usar as médias da zona.
zone <- target[validos>0,.(x_lula_z=sum(c13)/sum(validos),x_outros_z=sum(validos-c13-c22)/sum(validos),
  x_terceiro_z=sum(c70)/sum(validos),x_quarto_z=sum(c14)/sum(validos)),by=.(uf,zona)]
target <- merge(target,zone,by=c("uf","zona"),all.x=TRUE)
target[validos==0,`:=`(x_lula=x_lula_z,x_outros=x_outros_z,x_terceiro=x_terceiro_z,x_quarto=x_quarto_z)]
target[,`:=`(x_outros_sem3=x_outros-x_terceiro,x_outros_sem34=x_outros-x_terceiro-x_quarto)]
projected <- predict_joint(candidate,target,zero)
fwrite(data.table(especificacao=c("Ativo: demais agrupados","Candidato: terceiro separado"),
  pct_lula=c(reference,100*sum(projected$a)/sum(projected$validos)),
  secoes_com_t1=nrow(target),ajuste_transferencia="zero: relação de 2022 transportada"),file.path(out,"projecoes_sem_ajuste.csv"))
saveRDS(candidate,file.path(out,"candidato_fits.rds"))
candidate_base <- bayes_baseline(candidate,target)
candidate_base[,fallback:=fifelse(validos==0,"zero_validos_t1_composicao_zona","nenhum")]
fwrite(candidate_base,file.path(out,"candidato_baseline_2026.csv"))
message("COMPARACAO_CONCLUIDA; nenhuma alteração do modelo ativo ou da coleta")
