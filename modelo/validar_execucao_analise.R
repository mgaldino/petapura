args_all <- commandArgs(FALSE)
root <- dirname(normalizePath(sub("^--file=","",args_all[grepl("^--file=",args_all)])[1]))
source(file.path(root,"analise_execucao.R"),encoding="UTF-8")
out <- file.path(root,"output","execucao_analise_20261020")
dir.create(out,recursive=TRUE,showWarnings=FALSE)
tmp <- tempfile("teste-analise-");dir.create(tmp)
on.exit_cleanup <- function()unlink(tmp,recursive=TRUE)
checks <- list()
check <- function(name,ok) {
  checks[[length(checks)+1L]] <<- data.table(verificacao=name,passou=isTRUE(ok))
  fwrite(rbindlist(checks),file.path(out,"checks.csv"))
  if(!isTRUE(ok))stop(name)
}
fails <- function(expr)inherits(tryCatch(force(expr),error=function(e)e),"error")
close <- function(a,b)max(abs(a-b))<1e-8
inventory <- data.table(uf=c("AC","AC","AC","AL"),cd_mun=c(1L,1L,1L,2L),
  zona=c(1L,1L,3L,2L),secao=c(1L,2L,3L,1L))
t1 <- inventory[c(1,2,4)]
t1[,`:=`(aptos=200L,comparecimento=c(150L,0L,150L),validos=c(100L,0L,120L),
  c13=c(50L,0L,60L),c22=c(50L,0L,60L))]
t1path <- file.path(tmp,"t1.parquet");arrow::write_parquet(t1,t1path)
cfgpath <- file.path(tmp,"config.json");file.copy(file.path(root,"config.json"),cfgpath)
cfg <- jsonlite::read_json(cfgpath,simplifyVector=TRUE)
snap <- file.path(tmp,"tse");dir.create(snap)
empty <- inventory[0]
for(k in contagens_analise)empty[,(k):=numeric()]
write_snapshot <- function(observed=empty,id="teste-0",inv=inventory,candidate_a=13L,round=2L) {
  files <- list()
  save <- function(name,object) {
    path <- file.path(snap,name)
    if(endsWith(name,".csv"))fwrite(object,path) else
      jsonlite::write_json(object,path,auto_unbox=TRUE,pretty=TRUE)
    files[[name]] <<- list(path=name,sha256=hash_arquivo_analise(path),
      kind=if(endsWith(name,".csv"))"csv" else "json")
  }
  save("inventory.csv",inv);save("observed.csv",observed)
  official <- data.table(area="BR",st=nrow(observed),ts=nrow(inv),votos_a=sum(observed$votos_a),
    votos_b=sum(observed$votos_b),validos=sum(observed$validos))
  save("official_sources.csv",official);save("official_selected.csv",official)
  save("official_selected.json",list(chosen=as.list(official[1])))
  save("status.json",list(fixture=TRUE))
  identity <- cfg[c("year","round","election","pleito")];identity$round <- round
  jsonlite::write_json(list(schema_version=1L,mode="observed_data_only",snapshot_id=id,
    identity=identity,candidate_columns=list(votos_a=candidate_a,votos_b=22L),keys=chaves_analise,
    inventory_sections=nrow(inv),observed_sections=nrow(observed),files=files),
    file.path(snap,"manifest.json"),auto_unbox=TRUE,pretty=TRUE)
}
write_snapshot()
initial <- file.path(tmp,"initial")
fitpath <- file.path(root,"data","processed","voto_t1_fits.rds")
fit_hash <- hash_arquivo_analise(fitpath)
s <- inicializar_analise(initial,fitpath,t1path,cfgpath,snap)
loaded <- carregar_ponto_partida_analise(initial)
check("Estado salvo e carregado preserva prior e população",identical(s$id,loaded$id)&&
  close(s$prior$mean,loaded$prior$mean)&&close(s$prior$covariance,loaded$prior$covariance)&&nrow(loaded$population)==4)
check("Preditores sem T1 e com denominador zero são rotulados",
  all(c("sem_secao_t1_medias_uf","denominador_t1_zero_medias_zona")%in%loaded$population$fallback))
check("Estado usa V2 central e ajuste completo",s$provenance$historical_n==472024L&&
  s$provenance$drift_version=="mudanca_entre_eleicoes_v2_2026-10-20"&&s$provenance$profile=="central")
original_file_hash <- hash_arquivo_analise(file.path(initial,"estado.rds"))
s2 <- inicializar_analise(initial,fitpath,t1path,cfgpath,snap)
check("Inicialização repetida é idempotente sem sobrescrever",identical(s$id,s2$id)&&
  identical(original_file_hash,hash_arquivo_analise(file.path(initial,"estado.rds"))))
check("Outro perfil não sobrescreve estado existente",fails(inicializar_analise(initial,fitpath,t1path,cfgpath,snap,profile="restrito")))
r0 <- processar_snapshot_analise(loaded,snap)
check("Zero BUs preserva média e covariância com Q",r0$posterior$n==0&&
  close(r0$posterior$mean,s$prior$mean)&&close(r0$posterior$covariance,s$prior$covariance))
o <- inventory[1]
o[,`:=`(aptos=200,comparecimento=150,validos=140,votos_a=80,votos_b=60,brancos=5,nulos=5)]
write_snapshot(o,"teste-1")
r1 <- processar_snapshot_analise(loaded,snap)
check("BU válido atualiza os coeficientes",r1$posterior$n==1&&!close(r1$posterior$mean,r0$posterior$mean))
direct <- .analise_componentes$snapshot_online(s$prior,s$population,o)
check("Executor coincide com chamada direta do atualizador",close(r1$posterior$mean,direct$mean)&&close(r1$posterior$covariance,direct$covariance))
repeat1 <- processar_snapshot_analise(loaded,snap)
check("Repetir snapshot não acumula informação",close(r1$posterior$mean,repeat1$posterior$mean)&&
  close(r1$posterior$covariance,repeat1$posterior$covariance)&&identical(r1$id,repeat1$id))
o2 <- copy(o);o2[,`:=`(votos_a=85,votos_b=55)]
write_snapshot(o2,"teste-2")
corrected <- processar_snapshot_analise(loaded,snap)
check("Correção substitui o BU sem aumentar N",corrected$posterior$n==1&&!close(corrected$posterior$mean,r1$posterior$mean))
write_snapshot(empty,"teste-removido")
removed <- processar_snapshot_analise(loaded,snap)
check("Remoção de BU recompõe a prior sem reinflar Q",removed$posterior$n==0&&close(removed$posterior$covariance,s$prior$covariance))
zero <- copy(o);zero[,`:=`(validos=0,votos_a=0,votos_b=0,brancos=75,nulos=75)]
write_snapshot(zero,"teste-zero-validos")
z <- processar_snapshot_analise(loaded,snap)
check("BU sem válidos é contado mas não entra na regressão",z$observed_sections==1&&z$zero_valid_sections==1&&z$posterior$n==0)
write_snapshot(o,"teste-mapa",candidate_a=22L)
check("Correspondência errada de candidaturas é rejeitada",fails(processar_snapshot_analise(loaded,snap)))
write_snapshot(o,"teste-turno",round=1L)
check("Turno errado é rejeitado",fails(processar_snapshot_analise(loaded,snap)))
extra <- rbind(inventory,inventory[1][,secao:=9L])
write_snapshot(o,"teste-populacao",inv=extra)
check("Mudança de inventário é rejeitada explicitamente",fails(processar_snapshot_analise(loaded,snap)))
unknown <- copy(o);unknown[,secao:=9L]
write_snapshot(unknown,"teste-extra")
check("BU fora do inventário é rejeitado",fails(processar_snapshot_analise(loaded,snap)))
write_snapshot(rbind(o,o),"teste-duplicado")
check("Seção duplicada é rejeitada",fails(processar_snapshot_analise(loaded,snap)))
bad <- copy(o);bad[,votos_a:=-1]
write_snapshot(bad,"teste-contagem")
check("Contagens inválidas são rejeitadas",fails(processar_snapshot_analise(loaded,snap)))
write_snapshot(o,"teste-corrupcao")
cat("corrompido",file=file.path(snap,"observed.csv"),append=TRUE)
check("Snapshot corrompido falha antes da atualização",fails(processar_snapshot_analise(loaded,snap)))
write_snapshot(o,"teste-publicacao")
r <- processar_snapshot_analise(loaded,snap)
destination <- file.path(tmp,"results")
publicar_atualizacao_analise(r,destination)
published <- carregar_atualizacao_analise(destination)
check("Resultado publicado e recarregado mantém posterior",identical(published$id,r$id)&&close(published$posterior$mean,r$posterior$mean))
publicar_atualizacao_analise(r,destination)
check("Publicação repetida reutiliza pacote imutável",length(list.dirs(file.path(destination,"snapshots"),recursive=FALSE))==1L)
other <- r;other$initial_state_id <- "outra-analise"
check("Saídas de estados diferentes não se misturam",fails(publicar_atualizacao_analise(other,destination)))
check("Lock impede dois executores simultâneos",com_lock_executor_analise(destination,
  fails(com_lock_executor_analise(destination,NULL))))
check("Lock é removido após erro do executor",fails(com_lock_executor_analise(destination,stop("teste")))&&
  !dir.exists(file.path(destination,".executor.lock")))
duplicate <- data.table(uf=c("AC","ac"),cd_mun=c("001","1"),zona=c("01","1"),secao=c("01","1"))
check("Normalização detecta duplicidade com zeros e caixa",fails(normalizar_chaves_analise(duplicate)))
run_cli <- function(command,extra=character()) {
  lines <- suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),
    c("--vanilla",shQuote(file.path(root,"executar_analise.R")),command,
      "--estado-inicial",shQuote(initial),"--snapshot",shQuote(snap),"--saida",shQuote(destination),extra),
    stdout=TRUE,stderr=TRUE))
  list(status=if(is.null(attr(lines,"status")))0L else attr(lines,"status"),lines=lines)
}
check("CLI inspeciona estado persistido",run_cli("inspecionar")$status==0L)
check("CLI inicializa idempotentemente em outro processo R",
  run_cli("inicializar",c("--ajuste",shQuote(fitpath),"--t1",shQuote(t1path),"--config",shQuote(cfgpath)))$status==0L&&
  identical(original_file_hash,hash_arquivo_analise(file.path(initial,"estado.rds"))))
check("CLI processa um snapshot",run_cli("atualizar")$status==0L)
check("CLI acompanha ciclos sem duplicar BU",run_cli("acompanhar",c("--ciclos","2","--intervalo","0.01"))$status==0L&&
  carregar_atualizacao_analise(destination)$posterior$n==1)
check("CLI rejeita alteração de Q após inicializar",run_cli("atualizar",c("--perfil","amplo"))$status!=0L)
check("CLI rejeita opção desconhecida",run_cli("atualizar",c("--inexistente","1"))$status!=0L)
write_snapshot(o,"teste-erro-ciclos",round=1L)
check("CLI retorna erro quando nenhum ciclo é válido",run_cli("acompanhar",c("--ciclos","1","--intervalo","0.01"))$status!=0L)
check("Erro de ciclo preserva último resultado válido",identical(carregar_atualizacao_analise(destination)$snapshot_id,"teste-publicacao"))
portable <- file.path(tmp,"portable");dir.create(portable)
file.copy(file.path(initial,c("estado.rds","manifest.json")),portable)
unlink(c(t1path,cfgpath))
check("Estado é portátil sem depender das entradas originais",identical(carregar_ponto_partida_analise(portable)$id,s$id))
raw <- readBin(file.path(portable,"estado.rds"),"raw",n=file.info(file.path(portable,"estado.rds"))$size)
writeBin(c(raw,as.raw(0)),file.path(portable,"estado.rds"))
check("Corrupção do estado inicial é rejeitada",fails(carregar_ponto_partida_analise(portable)))
check("Execução não altera ajuste histórico nem ponto de partida",
  identical(fit_hash,hash_arquivo_analise(fitpath))&&identical(original_file_hash,hash_arquivo_analise(file.path(initial,"estado.rds"))))
jsonlite::write_json(list(status="passou",tests_passed=length(checks),
  fixture="synthetic counts and keys; full saved historical fit",historical_fit_preserved=TRUE,
  scope="initial persistence and snapshot-to-coefficient executor; no aggregate predictions"),
  file.path(out,"verificacao_testes.json"),pretty=TRUE,auto_unbox=TRUE)
print(rbindlist(checks))
on.exit_cleanup()
