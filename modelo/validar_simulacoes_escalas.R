# Verifica integridade do ensaio, comparação pareada e regressão contra V1.
# As taxas de cobertura são relatadas, não convertidas em aprovação geral de Q.
args_all <- commandArgs(FALSE)
root <- dirname(normalizePath(sub("^--file=","",args_all[grepl("^--file=",args_all)])[1]))
suppressPackageStartupMessages(library(data.table))
options(scipen=999)
out <- file.path(root,"output","escalas_online_v2_20261020")
sim <- fread(file.path(out,"simulacoes_sinteticas.csv"))
summary <- fread(file.path(out,"sensibilidade_sintetica.csv"))
comparison <- fread(file.path(out,"comparacao_pareada_v1_v2.csv"))
meta <- jsonlite::read_json(file.path(out,"proveniencia.json"),simplifyVector=TRUE)
checks <- list()
check <- function(name,yes) {
  checks[[length(checks)+1L]] <<- data.table(verificacao=name,passou=isTRUE(yes))
  if(!isTRUE(yes))stop(name)
}
check("Ensaio tem 24 mil avaliacoes",nrow(sim)==24000L)
check("Chaves de repeticao cenario perfil e N sao unicas",
  uniqueN(sim[,.(repeticao,cenario,perfil,n)])==nrow(sim))
check("Cada celula tem 200 repeticoes independentes de ruido",
  all(sim[,.N,by=.(cenario,perfil,n)]$N==200L))
check("Todos os quatro perfis estao presentes",
  setequal(unique(sim$perfil),c("restrito","central","amplo","anterior_v1")))
check("Tamanhos de amostra preservados",setequal(unique(sim$n),c(0,50,200,1000,5000,20000)))
numeric_cols <- c("rmse_media_condicional_logit","erro_coef_comparecimento","dp_posterior_comparecimento")
check("Metricas numericas sao finitas e desvios positivos",
  all(is.finite(as.matrix(sim[,..numeric_cols])))&&all(sim$dp_posterior_comparecimento>0))
check("Sem observacoes medias condicionais sao iguais entre perfis",
  all(sim[n==0,.(dif=max(rmse_media_condicional_logit)-min(rmse_media_condicional_logit)),
          by=.(repeticao,cenario)]$dif<1e-12))
check("Comparacao pareada tem todas as 30 celulas",
  nrow(comparison)==30L&&all(comparison$repeticoes==200L))
check("Identidade das diferencas pareadas e preservada",
  max(abs(comparison$diferenca_rmse_v2_menos_v1-(comparison$rmse_v2-comparison$rmse_v1)))<1e-10)
check("DP posterior diminui com informacao para todos os perfis",
  all(summary[order(n),.(ok=all(diff(dp_posterior_comparecimento_medio)<0)),by=.(cenario,perfil)]$ok))
old <- fread(file.path(root,"output","escalas_online_v1_20261020","simulacoes_sinteticas.csv"))[perfil=="central"]
old[,cenario:=fcase(cenario=="inversao_comparecimento","inversao_comparecimento_pequena",
  cenario=="mudanca_nacional_1dp","mudanca_nacional_1dp_v1",
  cenario=="mudanca_nacional_2dp","mudanca_nacional_2dp_v1",default=cenario)]
joined <- merge(old,sim[perfil=="anterior_v1"&repeticao<=40],by=c("repeticao","cenario","n"),
                suffixes=c("_original","_reproduzido"))
check("As 960 avaliacoes centrais originais V1 sao reproduzidas",nrow(joined)==960L&&
  max(abs(joined$rmse_media_condicional_logit_original-joined$rmse_media_condicional_logit_reproduzido))<1e-10&&
  max(abs(joined$erro_coef_comparecimento_original-joined$erro_coef_comparecimento_reproduzido))<1e-10&&
  max(abs(joined$dp_posterior_comparecimento_original-joined$dp_posterior_comparecimento_reproduzido))<1e-10)
check("Configuracao simulada coincide com default V2",identical(meta$config_version,
  "mudanca_entre_eleicoes_v2_2026-10-20")&&identical(meta$config_sha256,
  digest::digest(file=file.path(root,"escalas_online_v2.json"),algo="sha256")))
check("Inversao moderada aprendida no ensaio de 20 mil observacoes",
  summary[cenario=="inversao_comparecimento_moderada"&perfil=="central"&n==20000,fracao_sinal_correto]>=.95)
check("Estabilidade mostra menor ajuste inicial ao ruido na V2",
  comparison[cenario=="sem_mudanca"&n==50,rmse_v2<rmse_v1])
fwrite(rbindlist(checks),file.path(out,"checks_simulacoes.csv"))
comparison[,mudanca_percentual_rmse:=100*(rmse_v2/rmse_v1-1)]
fwrite(comparison,file.path(out,"comparacao_pareada_v1_v2.csv"))
stress <- comparison[startsWith(cenario,"mudanca_nacional")&n>0&n<=1000,
  .(cenario,n,cobertura_comparecimento_v1,cobertura_comparecimento_v2)]
fwrite(stress,file.path(out,"diagnostico_cobertura_estresse.csv"))
jsonlite::write_json(list(status="mecanismo_verificado_com_subcobertura_inicial_em_estresse",
  integrity_and_mechanism_tests_passed=length(checks),simulation_evaluations=nrow(sim),
  replications_per_cell=200,old_v1_cells_reproduced=nrow(joined),
  checked_scripts_sha256=setNames(lapply(c("avaliar_escalas_online.R","validar_escalas_online.R",
    "validar_online_conjugado.R","validar_simulacoes_escalas.R","online_conjugado.R"),
    function(p)digest::digest(file=file.path(root,p),algo="sha256")),
    c("avaliar_escalas_online.R","validar_escalas_online.R","validar_online_conjugado.R",
      "validar_simulacoes_escalas.R","online_conjugado.R")),
  diagnostic="Conditional coverage for fixed large shifts can be below 95% in early samples; no claim of uniform frequentist calibration",
  all_scales_applied_as_requested=TRUE),file.path(out,"verificacao_simulacoes.json"),
  pretty=TRUE,auto_unbox=TRUE)
print(rbindlist(checks))
print(stress)
