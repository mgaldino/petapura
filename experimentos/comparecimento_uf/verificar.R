options(scipen=999)
library(data.table)
setDTthreads(1)
root <- normalizePath(getwd())
p <- jsonlite::read_json(file.path(root,"local/comparecimento-uf/variant.json"),simplifyVector=TRUE)
source(file.path(p$model_source,"previsao_execucao.R"),encoding="UTF-8")
state <- carregar_ponto_partida_analise(p$variant_initial)
fit <- readRDS(p$variant_fit)$lula
prior <- state$prior;G <- length(prior$levels)
stopifnot(G==28L,length(prior$mean)==86L,fit$gate$pass,
  max(abs(prior$mean[2L*G+seq_len(G)]-
    colMeans(fit$draws[,sprintf("theta[%d,3]",seq_len(G)),drop=FALSE])))<1e-12,
  diff(range(prior$mean[2L*G+seq_len(G)]))>.001)
comp <- 2L*G+seq_len(G)
stopifnot(max(abs(prior$drift_covariance[comp,comp]-.02^2))<1e-12,
  max(abs(prior$covariance-prior$historical_covariance-prior$drift_covariance))<1e-12)
# Caminho explícito registrado no estado de produção, com hash verificado.
production <- jsonlite::read_json(file.path(root,"local/cloudflare-production/current.json"),simplifyVector=TRUE)
original <- readRDS(file.path(production$settings$initial_state,"estado.rds"))
common_path <- unlist(original$provenance$source_paths)[1]
stopifnot(hash_arquivo_analise(common_path)==original$provenance$fit_sha256)
common <- readRDS(common_path)$lula
a <- .analise_componentes$prior_online(common,arquivo_escalas=file.path(p$model_source,"escalas_online_v2.json"))
b <- .analise_componentes$.prior_original(common,arquivo_escalas=file.path(p$model_source,"escalas_online_v2.json"))
stopifnot(identical(a,b),length(a$mean)==59L)
rejected <- tryCatch({carregar_checkpoint_previsao(file.path(production$settings$runtime,"model"),state);FALSE},error=function(e)TRUE)
stopifnot(rejected)
report <- list(passed=TRUE,coefficients=86,groups=G,historical_gate=fit$gate,
  varying_turnout_confirmed=TRUE,shared_national_turnout_drift_confirmed=TRUE,
  covariance_decomposition_confirmed=TRUE,default_59_prior_unchanged=TRUE,
  public_checkpoint_rejected=TRUE)
jsonlite::write_json(report,file.path(p$base,"statistical-verification.json"),auto_unbox=TRUE,pretty=TRUE)
print(report)
