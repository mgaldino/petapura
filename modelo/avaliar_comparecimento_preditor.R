args_all <- commandArgs(FALSE)
root <- dirname(normalizePath(sub("^--file=","",args_all[grepl("^--file=",args_all)])[1]))
source(file.path(root,"bayes.R"),encoding="UTF-8")
source(file.path(root,"comparecimento_preditor.R"),encoding="UTF-8")
raw <- file.path(root,"..","data","eleicoes_2022_2026","raw")
t1 <- as.data.table(arrow::read_parquet(file.path(raw,"section_votes_2022_T1.parquet")))
t2 <- as.data.table(arrow::read_parquet(file.path(raw,"section_votes_2022_T2.parquet")))
d <- features(t1,t2)[aptos>0&aptos_t2>0&comparecimento>0&comp_t2>0&validos>0&validos_t2>0]
d[,taxa_comparecimento:=taxa_comp_t1]
municipios <- unique(d[,.(uf,cd_mun)])[order(uf,cd_mun)]
municipios[,teste:=seq_len(.N)%%5L==0L,by=uf]
test_keys <- municipios[teste==TRUE,.(uf,cd_mun)]
train <- d[!test_keys,on=.(uf,cd_mun)]
test <- d[test_keys,on=.(uf,cd_mun)]
out <- file.path(root,"output","comparecimento_preditor_20261020")
dir.create(out,recursive=TRUE,showWarnings=FALSE)
stan <- cmdstanr::cmdstan_model(file.path(root,"comparecimento_preditor.stan"),quiet=FALSE)
scores <- gates <- effects <- list()
  tr <- copy(train);te <- copy(test)
  structures <- c("intercepto","voto_t1","comparecimento","ambos")
  for(structure in structures) {
    message("Comparecimento T1; estrutura ",structure)
    f <- fit_comparecimento(tr,structure,stan,file.path(out,"T1",structure))
    if(!isTRUE(f$gate$pass)) stop("Diagnóstico MCMC insuficiente: ",structure)
    name <- structure
    scores[[name]] <- score_comparecimento(f,te)
    gates[[name]] <- cbind(turno=1L,estrutura=structure,as.data.table(f$gate))
    effects[[name]] <- cbind(turno=1L,estrutura=structure,efeito_comparecimento(f))
    fwrite(rbindlist(scores),file.path(out,"comparacao.csv"))
    fwrite(rbindlist(gates),file.path(out,"diagnosticos.csv"))
    fwrite(rbindlist(effects),file.path(out,"associacao_por_uf.csv"))
  }
print(rbindlist(scores));print(rbindlist(gates))
message("COMPARECIMENTO_COMO_PREDITOR_CONCLUIDO; modelos de votação candidatos, sem alterar fits ativos")
