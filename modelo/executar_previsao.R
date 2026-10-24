#!/usr/bin/env Rscript
# Previsões por seção, UF e total com checkpoint (itens 3 e 4). Não inicia a coleta.
# Dois cenários: pct_a_projetado* aprende com os BUs; pct_a_2022* supõe a relação de 2022.
args_all <- commandArgs(FALSE)
root <- dirname(normalizePath(sub("^--file=","",args_all[grepl("^--file=",args_all)])[1]))
source(file.path(root,"previsao_execucao.R"),encoding="UTF-8")
args <- commandArgs(TRUE)
help <- function()cat(paste(
  "Uso: Rscript --vanilla executar_previsao.R COMANDO [opções]",
  "Comandos: atualizar, acompanhar, inspecionar",
  "--estado-inicial DIR  Pacote inicial (padrão: data/processed/estado_inicial_v2)",
  "--snapshot DIR        Exportação TSE (padrão: data/live/tse_export)",
  "--saida DIR           Previsões e checkpoints (padrão: data/live/analise_previsoes)",
  "--sorteios N          Sorteios conjuntos por snapshot (padrão: 400)",
  "--semente N           Semente dos sorteios (padrão: 618360)",
  "--manter N            Pacotes recentes preservados (padrão: 3)",
  "--componentes JSON    Componentes locais de voto e válidos (padrão: componentes_locais_v2.json)",
  "Acompanhar: --intervalo SEGUNDOS --ciclos N (opcional; padrão contínuo)",
  "Inspecionar: --completo sim regenera as previsões do checkpoint e compara",
  "Retomada: atualizar e acompanhar carregam o último checkpoint íntegro da saída.",
  "Encerrar acompanhamento em primeiro plano: Ctrl+C. Não encerra o coletor.",sep="\n"),"\n")
if(!length(args)||args[1]%in%c("--help","-h")){help();quit(status=0L)}
emit <- function(x)cat(jsonlite::toJSON(x,auto_unbox=TRUE,null="null",na="null",digits=10),"\n")
resumo_evento <- function(event,cp,extra=list()) {
  s <- cp$results$resumo
  c(list(event=event,sequencia=cp$sequence,snapshot=cp$snapshot_id,
    secoes_coletadas=s$secoes_apuradas_coletor,secoes_regressao=s$secoes_regressao,
    pct_a_projetado=s$pct_a_projetado,pct_a_q025=s$pct_a_q025,pct_a_q975=s$pct_a_q975,
    pct_a_2022=s$pct_a_2022,pct_a_2022_q025=s$pct_a_2022_q025,pct_a_2022_q975=s$pct_a_2022_q975,
    fonte_oficial=s$fonte_oficial,ancora_oficial=s$ancora_oficial,
    bus_novos=cp$changes$novos,bus_revisados=cp$changes$revisados,bus_removidos=cp$changes$removidos),extra)
}
main <- function() {
  command <- args[1]
  exigir_analise(command%in%c("atualizar","acompanhar","inspecionar"),"Comando desconhecido; use --help")
  opts <- list("estado-inicial"=file.path(root,"data","processed","estado_inicial_v2"),
    snapshot=file.path(root,"data","live","tse_export"),saida=file.path(root,"data","live","analise_previsoes"),
    sorteios="400",semente="618360",manter="3",intervalo="60",ciclos="Inf",completo="nao",
    componentes=file.path(root,"componentes_locais_v2.json"))
  rest <- args[-1]
  exigir_analise(length(rest)%%2L==0L,"Cada opção exige um valor")
  seen <- character()
  if(length(rest))for(i in seq(1,length(rest),by=2)) {
    key <- sub("^--","",rest[i])
    exigir_analise(startsWith(rest[i],"--")&&key%in%names(opts)&&!key%in%seen,paste("Opção desconhecida ou repetida:",rest[i]))
    seen <- c(seen,key)
    opts[[key]] <- rest[i+1]
  }
  exigir_analise(command=="acompanhar"||!any(seen%in%c("intervalo","ciclos")),"Intervalo e ciclos só se aplicam a acompanhar")
  exigir_analise(command=="inspecionar"||!"completo"%in%seen,"--completo só se aplica a inspecionar")
  exigir_analise(command!="inspecionar"||!"componentes"%in%seen,"Inspecionar usa os componentes salvos no checkpoint")
  exigir_analise(opts$completo%in%c("sim","nao"),"--completo aceita sim ou nao")
  state <- carregar_ponto_partida_analise(opts[["estado-inicial"]])
  if(command=="inspecionar") {
    cp <- carregar_checkpoint_previsao(opts$saida,state,verificar_previsoes=opts$completo=="sim")
    exigir_analise(!is.null(cp),"Nenhum checkpoint de previsão nesta saída")
    emit(resumo_evento("checkpoint_validado",cp,list(previsoes_regeneradas=opts$completo=="sim",
      recuperado_de=attr(cp,"recuperacao")$pacote)))
    return(invisible(NULL))
  }
  number <- function(x)suppressWarnings(as.numeric(x))
  draws <- number(opts$sorteios);seed <- number(opts$semente);keep <- number(opts$manter)
  interval <- number(opts$intervalo);cycles <- number(opts$ciclos)
  validar_sorteios_previsao(draws,seed)
  exigir_analise(length(keep)==1L&&is.finite(keep)&&keep>=2&&keep==floor(keep),"--manter deve ser inteiro maior ou igual a 2")
  exigir_analise(length(interval)==1L&&is.finite(interval)&&interval>0,"Intervalo deve ser positivo")
  exigir_analise(length(cycles)==1L&&!is.na(cycles)&&cycles>=1&&
    (is.infinite(cycles)||cycles==floor(cycles)),"Número de ciclos inválido")
  local <- ler_componentes_locais(opts$componentes)
  com_lock_executor_analise(opts$saida,{
    cp <- carregar_checkpoint_previsao(opts$saida,state)
    if(!is.null(cp))emit(resumo_evento("retomada",cp,list(recuperado_de=attr(cp,"recuperacao")$pacote)))
    cycle <- 0L
    successes <- 0L
    repeat {
      cycle <- cycle+1L
      run <- function() {
        started <- proc.time()[["elapsed"]]
        step <- avancar_previsao_analise(state,opts$snapshot,opts$saida,cp,draws,seed,keep,local)
        cp <<- step$checkpoint
        emit(if(step$processado)resumo_evento("previsao_publicada",cp,list(ciclo=cycle,
          segundos=round(proc.time()[["elapsed"]]-started,3),pacote=step$caminho)) else
          list(event="snapshot_ja_processado",ciclo=cycle,sequencia=cp$sequence,snapshot=cp$snapshot_id))
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
