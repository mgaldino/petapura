#!/usr/bin/env Rscript
args_all <- commandArgs(FALSE)
root <- dirname(normalizePath(sub("^--file=","",args_all[grepl("^--file=",args_all)])[1]))
source(file.path(root,"analise_execucao.R"),encoding="UTF-8")
args <- commandArgs(TRUE)
help <- function()cat(paste(
  "Uso: Rscript --vanilla executar_analise.R COMANDO [opções]",
  "Comandos: inicializar, inspecionar, atualizar, acompanhar",
  "--estado-inicial DIR  Pacote inicial (padrão: data/processed/estado_inicial_v2)",
  "--snapshot DIR        Exportação TSE (padrão: data/live/tse_export)",
  "--saida DIR           Resultados de coeficientes (padrão: data/live/analise_coeficientes)",
  "Inicializar: --ajuste RDS --t1 PARQUET --config JSON --escalas JSON --perfil central",
  "Acompanhar: --intervalo SEGUNDOS --ciclos N (opcional; padrão contínuo)",
  "Encerrar acompanhamento em primeiro plano: Ctrl+C. Não encerra o coletor.",sep="\n"),"\n")
if(!length(args)||args[1]%in%c("--help","-h")){help();quit(status=0L)}
emit <- function(x)cat(jsonlite::toJSON(x,auto_unbox=TRUE,null="null",digits=16),"\n")
main <- function() {
  command <- args[1]
  exigir_analise(command%in%c("inicializar","inspecionar","atualizar","acompanhar"),"Comando desconhecido; use --help")
  opts <- list("estado-inicial"=file.path(root,"data","processed","estado_inicial_v2"),
    snapshot=file.path(root,"data","live","tse_export"),saida=file.path(root,"data","live","analise_coeficientes"),
    ajuste=file.path(root,"data","processed","voto_t1_fits.rds"),
    t1=file.path(root,"..","data","eleicoes_2022_2026","raw","section_votes_2026_T1_bu.parquet"),
    config=file.path(root,"config.json"),escalas=file.path(root,"escalas_online_v2.json"),
    perfil="central",intervalo="60",ciclos="Inf")
  rest <- args[-1]
  exigir_analise(length(rest)%%2L==0L,"Cada opção exige um valor")
  seen <- character()
  if(length(rest))for(i in seq(1,length(rest),by=2)) {
    key <- sub("^--","",rest[i])
    exigir_analise(startsWith(rest[i],"--")&&key%in%names(opts)&&!key%in%seen,paste("Opção desconhecida ou repetida:",rest[i]))
    seen <- c(seen,key)
    opts[[key]] <- rest[i+1]
  }
  init_only <- c("ajuste","t1","config","escalas","perfil")
  exigir_analise(command=="inicializar"||!any(seen%in%init_only),"Opções de ajuste/configuração só podem ser usadas em inicializar; o estado salvo fica congelado")
  exigir_analise(command=="acompanhar"||!any(seen%in%c("intervalo","ciclos")),"Intervalo e ciclos só se aplicam a acompanhar")
  if(command=="inicializar") {
    s <- inicializar_analise(opts[["estado-inicial"]],opts$ajuste,opts$t1,opts$config,opts$snapshot,opts$escalas,opts$perfil)
    emit(list(event="estado_inicial_pronto",id=s$id,secoes=nrow(s$population),
      aproximacoes=sum(s$population$fallback!="nenhum"),coeficientes=length(s$prior$mean),
      versao=s$provenance$drift_version,diretorio=opts[["estado-inicial"]]))
    return(invisible(NULL))
  }
  state <- carregar_ponto_partida_analise(opts[["estado-inicial"]])
  if(command=="inspecionar") {
    emit(list(event="estado_inicial_validado",id=state$id,secoes=nrow(state$population),
      aproximacoes=sum(state$population$fallback!="nenhum"),coeficientes=length(state$prior$mean),
      versao=state$provenance$drift_version,perfil=state$provenance$profile))
    return(invisible(NULL))
  }
  interval <- suppressWarnings(as.numeric(opts$intervalo))
  cycles <- suppressWarnings(as.numeric(opts$ciclos))
  exigir_analise(length(interval)==1L&&is.finite(interval)&&interval>0,"Intervalo deve ser positivo")
  exigir_analise(length(cycles)==1L&&!is.na(cycles)&&cycles>=1&&
    (is.infinite(cycles)||cycles==floor(cycles)),"Número de ciclos inválido")
  com_lock_executor_analise(opts$saida,{
    cycle <- 0L
    successes <- 0L
    repeat {
      cycle <- cycle+1L
      run <- function() {
        result <- processar_snapshot_analise(state,opts$snapshot)
        path <- publicar_atualizacao_analise(result,opts$saida)
        emit(list(event="coeficientes_atualizados",ciclo=cycle,snapshot=result$snapshot_id,
          secoes_observadas=result$observed_sections,secoes_com_validos=result$posterior$n,
          secoes_zero_validos=result$zero_valid_sections,saida=path))
      }
      if(command=="atualizar") {run();successes <- successes+1L} else {
        ok <- tryCatch({run();TRUE},error=function(e){
          emit(list(event="erro_snapshot",ciclo=cycle,message=conditionMessage(e)));FALSE})
        if(ok)successes <- successes+1L
      }
      if(command=="atualizar"||cycle>=cycles)break
      Sys.sleep(interval)
    }
    exigir_analise(successes>0L,"Nenhum snapshot pôde ser processado")
  })
}
tryCatch(main(),error=function(e){message(conditionMessage(e));quit(status=1L)})
