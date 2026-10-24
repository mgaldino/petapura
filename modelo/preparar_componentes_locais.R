# Grava componentes_locais_v2.json: variâncias locais de 2022 e atualização gradual.
# Repetir só confere; nunca sobrescreve. A v1, sem atualização gradual, fica preservada.
args_all <- commandArgs(FALSE)
root <- dirname(normalizePath(sub("^--file=","",args_all[grepl("^--file=",args_all)])[1]))
source(file.path(root,"previsao_execucao.R"),encoding="UTF-8")
comp <- estimar_componentes_2022(root)
cfg <- list(versao="componentes_locais_v2_2026-10-20",
  status="estimado em 2022 (variâncias locais); hipótese de magnitude (dp nacional e de UF da razão de válidos)",
  voto=list(tau2_municipio=signif(comp$residuo[["entre"]],6),
    variancia_residual_total_2022=signif(comp$residuo[["total"]],6),sigma2_modelo=signif(comp$sigma2_modelo,6),
    fonte="Momentos ANOVA dos resíduos de voto_t1_fits.rds em 472.024 seções de 2022, por município"),
  validos=list(dp_nacional=0.02,dp_uf=round(comp$dp_log_rho_uf,3),
    var_municipio=signif(comp$razao[["entre"]],6),var_secao=signif(comp$razao[["dentro"]],6),
    razao_nacional_2022=signif(comp$razao_nacional,6),
    fonte=paste("log(válidos T2 / válidos T1) em 2022: variâncias municipal e por seção em torno da razão da UF;",
      "dp_uf = desvio-padrão entre UFs do log da razão em 2022; dp_nacional é hipótese (cerca de +-4% em 95%)")),
  atualizacao=list(fracao_plena=0.15,expoente=2,
    base="fração dos válidos T1 da população nas seções com BU",
    regra="peso do modelo atualizado = min(1, fração / 0,15)^2; o restante é o modelo inicial, sem aprendizado",
    fonte="pedido do usuário em 20/10/2026: previsões que mudem pouco nos primeiros 15% dos votos apurados"),
  media_dos_desvios=0,
  aplicacao="Prior das mudanças locais com média zero; aprendidas com os BUs a cada snapshot, desde a prior original")
path <- file.path(root,"componentes_locais_v2.json")
txt <- jsonlite::toJSON(cfg,pretty=TRUE,auto_unbox=TRUE,digits=NA)
if(file.exists(path)) {
  exigir_analise(identical(jsonlite::fromJSON(path),jsonlite::fromJSON(txt)),"Configuração existente difere; use nova versão")
} else writeLines(txt,path,useBytes=TRUE)
print(ler_componentes_locais(path)[c("versao","tau2","s0","sg","var_m","var_i","fracao_plena","expoente")])
