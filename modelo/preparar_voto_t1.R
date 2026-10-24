args_all <- commandArgs(FALSE)
root <- dirname(normalizePath(sub("^--file=","",args_all[grepl("^--file=",args_all)])[1]))
source(file.path(root,"modelo.R"),encoding="UTF-8")
source(file.path(root,"bayes.R"),encoding="UTF-8")
source(file.path(root,"voto_t1.R"),encoding="UTF-8")
raw <- file.path(root,"..","data","eleicoes_2022_2026","raw")
read_data <- function(name)as.data.table(arrow::read_parquet(file.path(raw,name)))
t1 <- read_data("section_votes_2022_T1.parquet")
t2 <- read_data("section_votes_2022_T2.parquet")
validar_secoes(t1);validar_secoes(t2)
d <- features_voto_t1(t1,t2)[aptos>0&aptos_t2>0&comparecimento>0&comp_t2>0&validos>0&validos_t2>0]
out <- file.path(root,"output","comparecimento_preditor_20261020")
scores <- fread(file.path(out,"comparacao.csv"))
# Escolha explícita por parcimônia: o ganho de RMSE ao variar também o
# comparecimento foi 0,00143 p.p. O log score favorece a versão com ambos.
# A seleção usou a reserva de municípios, que não é um teste final intocado.
structure <- "voto_t1"
stan <- cmdstanr::cmdstan_model(file.path(root,"comparecimento_preditor.stan"),quiet=TRUE)
final <- list()
for(s in c(structure,"ambos")) {
  message("Ajuste completo: ",s)
  final[[s]] <- fit_comparecimento(d,s,stan,file.path(out,"final",s))
  if(!isTRUE(final[[s]]$gate$pass)) stop("Não ativar modelo com MCMC insuficiente: ",s)
}
gates <- rbindlist(lapply(names(final),function(s)cbind(estrutura=s,as.data.table(final[[s]]$gate))))
fwrite(gates,file.path(out,"diagnosticos_finais.csv"))
effects <- rbindlist(lapply(names(final),function(s)cbind(estrutura=s,efeito_comparecimento(final[[s]]))))
fwrite(effects,file.path(out,"associacao_final_por_uf.csv"))
target <- read_data("section_votes_2026_T1_bu.parquet")
validar_secoes(target)
f <- features_voto_t1(target)
b <- baseline_voto_t1(final[[structure]],f[validos>0&aptos>0])
b <- align_voto_t1(b,f[,..keys])
b[f[validos==0,..keys],on=keys,fallback:="zero_validos_t1_medias_zona_ou_uf"]
processed <- file.path(root,"data","processed")
dir.create(processed,recursive=TRUE,showWarnings=FALSE)
saveRDS(list(lula=final[[structure]]),file.path(processed,"voto_t1_fits.rds"))
fwrite(b,file.path(processed,"voto_t1_baseline_2026.csv"))
fwrite(data.table(estrutura=structure,treino=nrow(d),secoes_teste=scores$n[1],
  municipios_teste=scores$municipios_teste[1],preditor_comparecimento="primeiro_turno",
  peso_pendente="validos_primeiro_turno",resposta="Lula/validos_segundo_turno"),file.path(out,"escolha.csv"))
print(scores);print(gates);print(effects[estrutura==structure][1])
message("VOTO_T1_PREPARADO; versão conjunta anterior preservada")
