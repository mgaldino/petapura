# Persistência do ponto de partida e execução do atualizador por snapshot.
# As saídas desta etapa são coeficientes; agregação preditiva fica no item 3.
.analise_dir <- dirname(normalizePath(sys.frame(1)$ofile))
.analise_componentes <- new.env(parent=globalenv())
.analise_componentes$root <- .analise_dir
for(.arquivo in c("bayes.R","comparecimento_preditor.R","voto_t1.R","online_conjugado.R","ler_dados_tse.R"))
  source(file.path(.analise_dir,.arquivo),local=.analise_componentes,encoding="UTF-8")

chaves_analise <- c("uf","cd_mun","zona","secao")
contagens_analise <- c("aptos","comparecimento","validos","votos_a","votos_b","brancos","nulos")
agora_analise <- function()format(Sys.time(),"%Y-%m-%dT%H:%M:%OS6Z",tz="UTC")
hash_arquivo_analise <- function(p)digest::digest(file=p,algo="sha256")
hash_objeto_analise <- function(x)digest::digest(x,algo="sha256",serializeVersion=2)
exigir_analise <- function(ok,message)if(!isTRUE(ok))stop(message,call.=FALSE)
hashes_codigo_analise <- function() {
  files <- c("analise_execucao.R","executar_analise.R","online_conjugado.R","bayes.R",
             "comparecimento_preditor.R","voto_t1.R","ler_dados_tse.R")
  setNames(as.list(vapply(file.path(.analise_dir,files),hash_arquivo_analise,"")),files)
}

normalizar_chaves_analise <- function(d) {
  d <- data.table::copy(data.table::as.data.table(d))
  exigir_analise(!anyDuplicated(names(d))&&all(chaves_analise%in%names(d)),"Chaves de seção ausentes ou colunas duplicadas")
  d[,uf:=toupper(trimws(as.character(uf)))]
  exigir_analise(!anyNA(d$uf)&&all(grepl("^[A-Z]{2}$",d$uf)),"UF inválida")
  for(k in chaves_analise[-1]) {
    v <- d[[k]]
    if(is.character(v))exigir_analise(all(!is.na(v)&grepl("^[0-9]+$",v)),paste("Chave inválida:",k))
    v <- suppressWarnings(as.numeric(v))
    exigir_analise(all(is.finite(v)&v>=1&v==floor(v)&v<=.Machine$integer.max),paste("Chave inválida:",k))
    data.table::set(d,j=k,value=as.integer(v))
  }
  exigir_analise(!anyDuplicated(d[,..chaves_analise]),"Seção duplicada após normalizar as chaves")
  data.table::setorderv(d,chaves_analise)
  d
}

hash_inventario_analise <- function(d) {
  z <- normalizar_chaves_analise(d)[,..chaves_analise]
  # Lista de vetores elimina atributos transitórios de data.table da assinatura.
  hash_objeto_analise(as.list(z))
}

identidade_analise <- function(identity,candidates) {
  fields <- c("year","round","election","pleito")
  numbers <- c(unlist(identity[fields]),unlist(candidates[c("votos_a","votos_b")]))
  exigir_analise(length(numbers)==6L&&is.numeric(numbers)&&all(is.finite(numbers))&&
    all(numbers>0&numbers==floor(numbers)),"Identidade eleitoral incompleta ou inválida")
  list(identity=setNames(as.list(as.integer(numbers[1:4])),fields),
       candidate_columns=setNames(as.list(as.integer(numbers[5:6])),c("votos_a","votos_b")))
}

validar_snapshot_analise <- function(dados,expected=NULL) {
  m <- dados$manifesto
  exigir_analise(identical(as.integer(m$schema_version),1L)&&identical(m$mode,"observed_data_only"),"Contrato TSE incompatível")
  exigir_analise(identical(as.character(unlist(m$keys)),chaves_analise),"Chaves do manifesto incompatíveis")
  exigir_analise(is.character(m$snapshot_id)&&length(m$snapshot_id)==1L&&
    grepl("^[A-Za-z0-9._-]{1,128}$",m$snapshot_id),"Identificador de snapshot inválido")
  identity <- identidade_analise(m$identity,m$candidate_columns)
  if(!is.null(expected))exigir_analise(identical(identity,expected),"Eleição, turno ou correspondência de candidaturas divergente do estado inicial")
  inventory <- normalizar_chaves_analise(dados$inventario)[,..chaves_analise]
  observed <- normalizar_chaves_analise(dados$secoes)
  exigir_analise(nrow(inventory)>0L&&nrow(inventory)==m$inventory_sections&&
    nrow(observed)==m$observed_sections,"Contagens de linhas divergentes do manifesto")
  exigir_analise(all(contagens_analise%in%names(observed)),"Contagens de BU ausentes")
  observed <- observed[,c(chaves_analise,contagens_analise),with=FALSE]
  for(k in contagens_analise) {
    exigir_analise(is.numeric(observed[[k]])||!nrow(observed),paste("Tipo de contagem inválido:",k))
    data.table::set(observed,j=k,value=as.numeric(observed[[k]]))
  }
  .analise_componentes$validar_observados_voto(observed)
  exigir_analise(!nrow(observed[!inventory,on=chaves_analise]),"BU fora do inventário do snapshot")
  list(identity=identity,inventory=inventory,observed=observed,manifest=m)
}

preparar_populacao_analise <- function(t1,inventory,prior) {
  t1 <- normalizar_chaves_analise(t1)
  needed <- c("aptos","comparecimento","validos","c13","c22")
  exigir_analise(all(needed%in%names(t1)),"Contagens T1 ausentes")
  for(k in needed)exigir_analise(is.numeric(t1[[k]])&&all(is.finite(t1[[k]])&
    t1[[k]]>=0&t1[[k]]==floor(t1[[k]])),paste("Contagem T1 inválida:",k))
  exigir_analise(all(t1$comparecimento<=t1$aptos&t1$validos<=t1$comparecimento&
    t1$c13+t1$c22<=t1$validos),"Denominadores T1 inconsistentes")
  inventory <- normalizar_chaves_analise(inventory)[,..chaves_analise]
  exigir_analise(all(inventory$uf%in%prior$levels),"Inventário contém grupo sem ajuste histórico")
  f <- .analise_componentes$features_voto_t1(t1)[aptos>0&comparecimento>0&validos>0]
  cols <- c("aptos","validos_base",prior$spec$vars)
  f[,validos_base:=as.numeric(validos)]
  f[,aptos:=as.numeric(aptos)]
  usable <- f[,c(chaves_analise,cols),with=FALSE]
  b <- merge(inventory,usable,by=chaves_analise,all.x=TRUE,sort=TRUE)
  missing <- which(is.na(b$validos_base))
  b[,fallback:="nenhum"]
  if(length(missing)) {
    zones <- usable[,lapply(.SD,mean),by=.(uf,zona),.SDcols=cols]
    states <- usable[,lapply(.SD,mean),by=uf,.SDcols=cols]
    z <- zones[b[missing,.(uf,zona)],on=.(uf,zona)]
    u <- states[b[missing,.(uf)],on="uf"]
    use_zone <- !is.na(z$validos_base)
    exigir_analise(all(use_zone|!is.na(u$validos_base)),"UF sem dados T1 para aproximar preditores")
    for(k in cols)data.table::set(b,i=missing,j=k,value=ifelse(use_zone,z[[k]],u[[k]]))
    known_t1 <- t1[b[missing,..chaves_analise],on=chaves_analise,which=TRUE]
    reason <- ifelse(is.na(known_t1),"sem_secao_t1","denominador_t1_zero")
    b[missing,fallback:=paste0(reason,ifelse(use_zone,"_medias_zona","_medias_uf"))]
  }
  exigir_analise(all(is.finite(as.matrix(b[,..cols])))&&all(b$validos_base>0&
    b$validos_base<=b$aptos&b$taxa_comparecimento>=0&b$taxa_comparecimento<=1),"População inicial inválida")
  .analise_componentes$X_comparecimento(b,prior$spec)
  b
}

validar_ponto_partida_analise <- function(state) {
  exigir_analise(identical(state$schema_version,1L)&&identical(state$kind,"initial_analysis"),"Formato de estado inicial incompatível")
  p <- state$prior
  q <- length(p$mean)
  exigir_analise(q==2L*length(p$levels)+3L&&all(is.finite(p$mean))&&p$sigma>0&&
    is.finite(p$sigma)&&identical(names(p$mean),p$names),"Parâmetros iniciais inválidos")
  for(k in c("covariance","historical_covariance","drift_covariance","precision"))
    exigir_analise(identical(dim(p[[k]]),c(q,q))&&all(is.finite(p[[k]]))&&
      max(abs(p[[k]]-t(p[[k]])))<1e-8,paste("Matriz inicial inválida:",k))
  chol(p$covariance)
  exigir_analise(max(abs(p$covariance-p$historical_covariance-p$drift_covariance))<1e-9&&
    max(abs(p$covariance%*%p$precision-diag(q)))<1e-6,"Covariância ou precisão inicial inconsistente")
  b <- normalizar_chaves_analise(state$population)
  exigir_analise(nrow(b)>0&&identical(hash_inventario_analise(b),state$inventory_sha256),"Inventário inicial inconsistente")
  exigir_analise(identical(hash_objeto_analise(as.list(b)),state$population_sha256),"Preditores iniciais alterados")
  exigir_analise(all(b$uf%in%p$levels)&&all(c(p$spec$vars,"aptos","validos_base","fallback")%in%names(b)),"Preditores iniciais incompletos")
  exigir_analise(all(is.finite(.analise_componentes$X_comparecimento(b,p$spec))),"Transformações iniciais inválidas")
  exigir_analise(identical(p$assumptions$drift_config_sha256,state$provenance$scales_sha256),"Versão de Q inconsistente")
  identity <- identidade_analise(state$identity$identity,state$identity$candidate_columns)
  exigir_analise(identical(identity,state$identity),"Identidade inicial inconsistente")
  invisible(TRUE)
}

gravar_pacote_analise <- function(object,directory) {
  dir.create(dirname(directory),recursive=TRUE,showWarnings=FALSE)
  directory <- file.path(normalizePath(dirname(directory)),basename(directory))
  if(file.exists(directory)) {
    old <- ler_pacote_analise(directory)
    exigir_analise(identical(old$id,object$id),"Destino já contém outro estado; use um diretório novo")
    return(invisible(directory))
  }
  tmp <- tempfile(".analise-",tmpdir=dirname(directory))
  dir.create(tmp)
  on.exit(unlink(tmp,recursive=TRUE),add=TRUE)
  saveRDS(object,file.path(tmp,"estado.rds"),version=3,compress="gzip")
  jsonlite::write_json(list(schema_version=1L,kind=object$kind,id=object$id,
    file="estado.rds",sha256=hash_arquivo_analise(file.path(tmp,"estado.rds")),
    created_utc=object$created_utc),file.path(tmp,"manifest.json"),pretty=TRUE,auto_unbox=TRUE)
  exigir_analise(file.rename(tmp,directory),"Não foi possível publicar o pacote de análise")
  invisible(directory)
}

ler_pacote_analise <- function(directory) {
  m <- jsonlite::read_json(file.path(directory,"manifest.json"),simplifyVector=TRUE)
  exigir_analise(identical(as.integer(m$schema_version),1L)&&identical(m$file,"estado.rds"),"Manifesto de análise incompatível")
  path <- file.path(directory,"estado.rds")
  exigir_analise(identical(hash_arquivo_analise(path),m$sha256),"SHA256 do estado de análise divergente")
  state <- readRDS(path)
  exigir_analise(identical(state$id,m$id)&&identical(state$kind,m$kind),"Identidade do pacote divergente")
  state
}

carregar_ponto_partida_analise <- function(directory) {
  state <- ler_pacote_analise(directory)
  validar_ponto_partida_analise(state)
  state
}

inicializar_analise <- function(directory,fit_path,t1_path,config_path,snapshot_dir,
                               scales_path=file.path(.analise_dir,"escalas_online_v2.json"),profile="central") {
  files <- c(fit=fit_path,t1=t1_path,config=config_path,scales=scales_path)
  before <- vapply(files,hash_arquivo_analise,"")
  cfg <- jsonlite::read_json(config_path,simplifyVector=TRUE)
  identity <- identidade_analise(cfg,list(votos_a=cfg$candidate_a,votos_b=cfg$candidate_b))
  exigir_analise(identity$candidate_columns$votos_a==13L&&identity$candidate_columns$votos_b==22L,
    "O ajuste salvo usa resposta c13 e preditores c13/c22; configuração incompatível")
  tse <- validar_snapshot_analise(.analise_componentes$ler_dados_tse(snapshot_dir),identity)
  fit <- readRDS(fit_path)$lula
  prior <- .analise_componentes$prior_online(fit,arquivo_escalas=scales_path,perfil=profile)
  pop <- preparar_populacao_analise(arrow::read_parquet(t1_path),tse$inventory,prior)
  state <- list(schema_version=1L,kind="initial_analysis",created_utc=agora_analise(),
    identity=identity,prior=prior,population=pop,
    inventory_sha256=hash_inventario_analise(pop),population_sha256=hash_objeto_analise(as.list(pop)),
    initial_snapshot_id=tse$manifest$snapshot_id,
    scales_config=jsonlite::read_json(scales_path,simplifyVector=FALSE),
    provenance=list(fit_sha256=unname(before["fit"]),t1_sha256=unname(before["t1"]),
      config_sha256=unname(before["config"]),scales_sha256=unname(before["scales"]),
      historical_n=fit$n,historical_signature=fit$signature,
      drift_version=prior$assumptions$drift_config_version,profile=profile,
      R=R.version.string,source_paths=as.list(normalizePath(files)),code_sha256=hashes_codigo_analise(),
      packages=setNames(lapply(c("data.table","arrow","jsonlite","digest"),
        function(p)as.character(packageVersion(p))),c("data.table","arrow","jsonlite","digest"))))
  state$id <- hash_objeto_analise(list(state$identity,state$provenance[c("fit_sha256","t1_sha256","config_sha256","scales_sha256","profile")],
    state$inventory_sha256,state$population_sha256,hash_objeto_analise(prior)))
  validar_ponto_partida_analise(state)
  exigir_analise(identical(before,vapply(files,hash_arquivo_analise,"")),"Entrada alterada durante inicialização")
  gravar_pacote_analise(state,directory)
  carregar_ponto_partida_analise(directory)
}

processar_snapshot_analise <- function(state,snapshot_dir) {
  if(is.character(state))state <- carregar_ponto_partida_analise(state)
  dados <- .analise_componentes$ler_dados_tse(snapshot_dir)
  tse <- validar_snapshot_analise(dados,state$identity)
  exigir_analise(identical(hash_inventario_analise(tse$inventory),state$inventory_sha256),
    "Inventário mudou; inicialize outro estado com a nova população antes de analisar")
  posterior <- .analise_componentes$snapshot_online(state$prior,state$population,tse$observed)
  fingerprint <- hash_objeto_analise(tse$manifest)
  list(schema_version=1L,kind="coefficient_update",id=hash_objeto_analise(list(state$id,fingerprint)),
    created_utc=agora_analise(),initial_state_id=state$id,identity=state$identity,
    snapshot_id=tse$manifest$snapshot_id,snapshot_manifest=tse$manifest,posterior=posterior,
    runtime_code_sha256=hashes_codigo_analise(),
    inventory_sections=nrow(tse$inventory),observed_sections=nrow(tse$observed),
    zero_valid_sections=sum(tse$observed$validos==0),
    approximated_observed_sections=sum(tse$observed[state$population[fallback!="nenhum"],on=chaves_analise,nomatch=0L]$validos>=0),
    official_selected=dados$totalizacao_selecionada,official_details=dados$detalhes_fontes,
    scope="coefficients_only; no section or aggregate predictions; posterior recomputed from immutable original prior")
}

publicar_atualizacao_analise <- function(result,directory) {
  dir.create(directory,recursive=TRUE,showWarnings=FALSE)
  pointer <- file.path(directory,"latest.json")
  if(file.exists(pointer)) {
    old <- jsonlite::read_json(pointer,simplifyVector=TRUE)
    exigir_analise(identical(old$initial_state_id,result$initial_state_id),"Saída pertence a outro estado inicial; use outro diretório")
  }
  relative <- file.path("snapshots",result$id)
  gravar_pacote_analise(result,file.path(directory,relative))
  tmp <- tempfile(".latest-",tmpdir=directory)
  on.exit(unlink(tmp),add=TRUE)
  jsonlite::write_json(list(schema_version=1L,initial_state_id=result$initial_state_id,
    snapshot_id=result$snapshot_id,result_id=result$id,path=relative),tmp,pretty=TRUE,auto_unbox=TRUE)
  exigir_analise(file.rename(tmp,pointer),"Falha ao publicar ponteiro da análise")
  invisible(file.path(directory,relative))
}

carregar_atualizacao_analise <- function(directory) {
  pointer <- jsonlite::read_json(file.path(directory,"latest.json"),simplifyVector=TRUE)
  exigir_analise(grepl("^snapshots/[a-f0-9]{64}$",pointer$path),"Caminho de resultado inválido")
  result <- ler_pacote_analise(file.path(directory,pointer$path))
  exigir_analise(identical(result$kind,"coefficient_update")&&identical(result$id,pointer$result_id)&&
    identical(result$initial_state_id,pointer$initial_state_id)&&identical(result$snapshot_id,pointer$snapshot_id),"Ponteiro de resultado inconsistente")
  result
}

com_lock_executor_analise <- function(directory,expr) {
  dir.create(directory,recursive=TRUE,showWarnings=FALSE)
  lock <- file.path(directory,".executor.lock")
  if(!dir.create(lock,showWarnings=FALSE)) {
    pid <- tryCatch(as.integer(readLines(file.path(lock,"pid"),warn=FALSE)),error=function(e)NA_integer_)
    alive <- length(pid)==1L&&!is.na(pid)&&isTRUE(tryCatch(tools::pskill(pid,0L),error=function(e)TRUE))
    exigir_analise(!alive,"Outro executor está usando esse diretório")
    # Lock sem PID pode pertencer a outro processo ainda iniciando: não remover.
    exigir_analise(length(pid)==1L&&!is.na(pid),"Lock sem identidade: confira antes de remover .executor.lock")
    stale <- tempfile(".executor-stale-",tmpdir=directory)
    exigir_analise(file.rename(lock,stale),"Não foi possível recuperar lock obsoleto")
    on.exit(unlink(stale,recursive=TRUE),add=TRUE)
    exigir_analise(dir.create(lock,showWarnings=FALSE),"Outro executor adquiriu o lock")
  }
  writeLines(as.character(Sys.getpid()),file.path(lock,"pid"))
  on.exit(unlink(lock,recursive=TRUE),add=TRUE)
  force(expr)
}
