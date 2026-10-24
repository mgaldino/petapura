# Testes integrados 1 a 4 e tempos: coletor (código real, HTTP simulado) ->
# publicação em slots -> leitor R -> executar_previsao.R em processos separados.
# População real congelada; BUs e totais oficiais SINTÉTICOS. Nada é gravado em data/live.
args_all <- commandArgs(FALSE)
root <- dirname(normalizePath(sub("^--file=","",args_all[grepl("^--file=",args_all)])[1]))
source(file.path(root,"previsao_execucao.R"),encoding="UTF-8")
source(file.path(root,"teste_integrado_comum.R"),encoding="UTF-8")
out <- file.path(root,"output","testes_integrados_20261020")
dir.create(out,recursive=TRUE,showWarnings=FALSE)
args <- commandArgs(TRUE)
work <- if(length(args))args[1] else tempfile("teste-integrado-")
unlink(work,recursive=TRUE);dir.create(work,recursive=TRUE)
work <- normalizePath(work)
exigir_analise(!startsWith(work,normalizePath(file.path(root,"data"))),"Diretório de teste não pode ficar em data/")
rscript <- file.path(R.home("bin"),"Rscript")
python <- Find(function(p)nzchar(p)&&file.exists(p)&&identical(suppressWarnings(
  system2(p,c("-c",shQuote("import asn1tools")),stdout=FALSE,stderr=FALSE)),0L),
  c(file.path(root,".venv","bin","python"),
    path.expand("~/Documents/DCP/Papers/electoralFraud/.venv_tse_bu/bin/python"),Sys.which("python3")))
exigir_analise(!is.null(python),"Python com asn1tools não encontrado")
env <- c("current",LC_ALL="pt_BR.UTF-8",LANG="pt_BR.UTF-8")

registro <- list();tempos <- list()
registrar <- function(teste,verificacao,esperado,obtido,passou,entrada="") {
  registro[[length(registro)+1L]] <<- data.table(teste=teste,verificacao=verificacao,entrada=entrada,
    esperado=paste(esperado,collapse="; "),obtido=paste(obtido,collapse="; "),passou=isTRUE(passou))
  fwrite(rbindlist(registro),file.path(out,"registro_fluxo.csv"))
  message(sprintf("[%s] %s | %s",if(isTRUE(passou))"OK" else "FALHOU",teste,verificacao))
}
num <- function(x,d=6)format(round(x,d),scientific=FALSE,trim=TRUE)

# ---------- Verdade sintética sobre a população real ----------
initial <- file.path(root,"data","processed","estado_inicial_v2")
state <- carregar_ponto_partida_analise(initial)
pop <- state$population;N <- nrow(pop)
comp <- componentes_2022_teste(root)
truth <- gerar_verdade_teste(state,comp,"realista",seed=618370L,zero_validos=25L)
ord <- ordem_chegada_teste(truth,"ufs_velocidades",618371L)
set.seed(618372L)
first <- function(f)ord[seq_len(round(f*N))]
revised <- sample(first(.05),300)                           # versão errada em S1-S2, corrigida em S3
removed <- sample(setdiff(first(.10),revised),200)          # fora do índice em S4-S6, volta em S7
truth[,hash:=sprintf("v1-%06d",.I)]
snapshots <- data.table(nome=c("S0","S1","S2","S3","S4","S4b","S5","S6","S7","S8","S9"),
  frac_o=c(0,.01,.05,.10,.25,.25,.50,.75,.90,.99,1),frac_f=c(0,.02,.08,.15,.30,.30,.60,.85,1,1,1),
  br=c("atual","atual","atual","atual","parado","parado","parado","mais_recente","atual","atual","atual"),
  zz_falha=c(rep(FALSE,6),TRUE,rep(FALSE,4)),minuto=c(0,10,20,30,40,40,50,60,70,80,90))
versao <- function(rows,nome) {
  v <- truth[rows,.(row=rows,uf,cd_mun,zona,secao,aptos,comparecimento,validos,votos_a,votos_b,brancos,nulos,hash)]
  if(nome%in%c("S1","S2")) {
    wrong <- v$row%in%revised
    shift <- ifelse(v$votos_b[wrong]>=3,3,-3)
    v[wrong,`:=`(votos_a=votos_a+shift,votos_b=votos_b-shift,hash=sprintf("v0-%06d",row))]
  }
  if(nome%in%c("S7","S8","S9"))v[row%in%removed,hash:=sprintf("v3-%06d",row)]
  v
}
observados_snapshot <- function(s) {
  rows <- first(s$frac_o)
  if(s$nome%in%c("S4","S4b","S5","S6"))rows <- setdiff(rows,removed)
  versao(rows,s$nome)
}
hora <- function(minuto)format(as.POSIXct("2026-10-25 17:00:00",tz="America/Sao_Paulo")+60*minuto,"%H:%M:%S")
oficial_area <- function(v,area,ts,minuto,extra_s=0)list(st=nrow(v),ts=ts,votos_a=sum(v$votos_a),
  votos_b=sum(v$votos_b),dg="25/10/2026",hg=hora(minuto+extra_s/60))
ts_uf <- pop[,.N,keyby=uf]
br_frozen <- NULL
especificacao <- function(s) {
  totalized <- versao(first(s$frac_f),s$nome)   # TSE já totalizou; inclui BUs fora do coletor
  areas <- lapply(ts_uf$uf,function(u)oficial_area(totalized[uf==u],u,ts_uf[uf==u]$N,s$minuto))
  names(areas) <- ts_uf$uf
  if(s$zz_falha)areas$ZZ <- "falha"
  br <- oficial_area(totalized,"BR",N,s$minuto,if(s$br=="mais_recente")30 else 0)
  if(s$nome=="S3")br_frozen <<- br
  areas$BR <- if(s$br=="parado")br_frozen else br
  areas
}
coleta <- file.path(work,"coleta");dir.create(coleta)
export <- file.path(coleta,"tse_export")
inventory_csv <- file.path(work,"inventory.csv");fwrite(pop[,..chaves_analise],inventory_csv)
publicar <- function(s) {
  obs <- observados_snapshot(s)
  o <- obs[,.(uf,cd_mun,zona,secao,aptos,comparecimento,validos,votos_a,votos_b,brancos,nulos,hash,
    hash_status="Totalizado",source_utc=paste("25/10/2026",hora(s$minuto)),
    collected_utc="2026-10-25T21:00:00+00:00",bu_sha256=substr(paste0(gsub("-","",hash),strrep("0",64)),1,64))]
  obs_csv <- file.path(work,paste0(s$nome,"_observed.csv"));fwrite(o,obs_csv)
  spec <- file.path(work,paste0(s$nome,"_spec.json"))
  jsonlite::write_json(list(inventory=if(s$nome=="S0")inventory_csv else NULL,observed=obs_csv,
    official=especificacao(s)),spec,auto_unbox=TRUE,digits=NA,null="null")
  started <- proc.time()[["elapsed"]]
  lines <- system2(python,c(shQuote(file.path(root,"publicar_teste_integrado.py")),shQuote(coleta),shQuote(spec)),
    stdout=TRUE,stderr=TRUE)
  exigir_analise(is.null(attr(lines,"status")),paste("Publicação falhou:",paste(lines,collapse="\n")))
  r <- jsonlite::fromJSON(tail(lines,1))
  r$wall_seconds <- proc.time()[["elapsed"]]-started
  r$observed <- obs
  r
}
iniciar <- function(nome,saida,extra=character()) {
  log <- file.path(work,paste0(nome,".log"))
  p <- processx::process$new(rscript,c("--vanilla",file.path(root,"executar_previsao.R"),"acompanhar",
    "--snapshot",export,"--saida",saida,"--intervalo","2",extra),stdout=log,stderr="2>&1",env=env)
  attr(p,"log") <- log
  p
}
esperar <- function(saida,snapshot_id,proc,timeout=400) {
  started <- proc.time()[["elapsed"]]
  repeat {
    m <- tryCatch(jsonlite::read_json(file.path(saida,"latest.json")),error=function(e)NULL)
    if(!is.null(m)&&identical(m$snapshot_id,snapshot_id))return(proc.time()[["elapsed"]]-started)
    if(!proc$is_alive())stop("Executor encerrou: ",paste(tail(readLines(attr(proc,"log")),5),collapse="\n"))
    if(proc.time()[["elapsed"]]-started>timeout)stop("Tempo esgotado esperando ",snapshot_id)
    Sys.sleep(.25)
  }
}
pacote_atual <- function(saida,tables=FALSE) {
  m <- jsonlite::read_json(file.path(saida,"latest.json"))
  ler_pacote_previsao(file.path(saida,"pacotes",m$package),tables=tables)
}
eventos <- function(proc)rbindlist(lapply(readLines(attr(proc,"log"),warn=FALSE),function(l)
  tryCatch(as.data.table(jsonlite::fromJSON(l)[c("event","snapshot")]),error=function(e)NULL)),fill=TRUE)
ultimo_segundos <- function(proc,snapshot_id) {
  ev <- lapply(readLines(attr(proc,"log"),warn=FALSE),function(l)tryCatch(jsonlite::fromJSON(l),error=function(e)NULL))
  ev <- Filter(function(e)!is.null(e)&&identical(e$event,"previsao_publicada")&&identical(e$snapshot,snapshot_id),ev)
  if(length(ev))tail(ev,1)[[1]]$segundos else NA_real_
}

# Oráculo independente da âncora: mesma regra contábil, calculada fora da rotina.
# Regra aprovada (item 1): soma estadual se os 28 totais forem compatíveis; senão BR; senão nenhuma.
ancora_esperada <- function(official,obs,secoes) {
  check_area <- function(u,o,bu_a,bu_b,n_pop) {
    ok <- u$ts==n_pop&&u$st>=nrow(o)&&u$st<=u$ts&&u$votos_a>=sum(o$votos_a)&&u$votos_b>=sum(o$votos_b)&&
      (u$st!=nrow(o)||(u$votos_a==sum(o$votos_a)&&u$votos_b==sum(o$votos_b)))
    f <- if(u$ts>nrow(o))(u$ts-u$st)/(u$ts-nrow(o)) else 0
    list(ok=ok,a=u$votos_a+(bu_a-sum(o$votos_a))*f,b=u$votos_b+(bu_b-sum(o$votos_b))*f)
  }
  parts <- lapply(official$states,function(u)check_area(u,obs[uf==u$area],sum(secoes[uf==u$area]$votos_a_projetados),
    sum(secoes[uf==u$area]$votos_b_projetados),nrow(pop[uf==u$area])))
  names(parts) <- vapply(official$states,function(u)u$area,"")
  if(length(parts)==nrow(ts_uf)&&all(vapply(parts,function(p)p$ok,TRUE)))
    return(list(area="SOMA_UFS",ok=TRUE,a=sum(vapply(parts,function(p)p$a,0)),b=sum(vapply(parts,function(p)p$b,0)),uf=parts))
  br <- official[["national"]]
  if(!is.null(br)) {
    p <- check_area(br,obs,sum(secoes$votos_a_projetados),sum(secoes$votos_b_projetados),N)
    if(p$ok)return(c(list(area="BR"),p))
  }
  list(area=official$chosen$area,ok=FALSE,a=NA_real_,b=NA_real_)
}

# ---------- Execução ----------
outA <- file.path(work,"previsoes_A_continua");outB <- file.path(work,"previsoes_B_interrompida")
coefdir <- file.path(work,"coeficientes")
A <- iniciar("A",outA)
B <- iniciar("B1",outB)
resultados <- list()
for(i in seq_len(nrow(snapshots))) {
  s <- snapshots[i]
  pub <- publicar(s)
  sid <- pub$snapshot_id
  dados <- .analise_componentes$ler_dados_tse(export)
  exigir_analise(identical(dados$manifesto$snapshot_id,sid),"Snapshot publicado não é o lido")
  official <- dados$detalhes_fontes
  # B é interrompido no meio do cálculo: B consulta o snapshot a cada 2 s e leva ~13 s por ciclo.
  if(s$nome=="S4"){Sys.sleep(5);B$kill();B$wait(10000)}
  if(s$nome=="S7"){Sys.sleep(5);B$interrupt();B$wait(60000)}
  latA <- esperar(outA,sid,A)
  pA <- pacote_atual(outA,tables=TRUE)
  cp <- pA$checkpoint;tb <- pA$tables
  obs <- pub$observed
  secoes <- tb$secoes
  res <- tb$resumo
  info <- sprintf("%s: %s BUs, %s totalizadas TSE",s$nome,nrow(obs),round(s$frac_f*N))
  # Bookkeeping comum a todos os snapshots.
  ok_obs <- nrow(obs)==res$secoes_apuradas_coletor&&sum(obs$votos_a)==res$votos_a_observados&&
    sum(obs$votos_b)==res$votos_b_observados&&sum(obs$validos>0)==res$secoes_regressao
  registrar("4 replay","BUs ativos e votos observados entram uma vez",
    c(nrow(obs),sum(obs$votos_a),sum(obs$validos>0)),c(res$secoes_apuradas_coletor,res$votos_a_observados,res$secoes_regressao),ok_obs,info)
  joined <- secoes[obs,on=chaves_analise]
  pend <- secoes[apurada==FALSE][pop,on=chaves_analise,nomatch=0L]
  exigir_analise(all(c("votos_a","validos")%in%names(joined)),"Junção de conferência sem colunas do BU")
  ok_sub <- nrow(joined)==nrow(obs)&&all(joined$apurada)&&all(joined$votos_a_projetados==joined$votos_a)&&
    all(joined$validos_projetados==joined$validos)&&
    max(abs(pend$validos_projetados-pend$validos_base*pend$razao_validos_t2_t1),0)<1e-6*max(c(1,pend$validos_base))&&
    nrow(pend)==N-nrow(obs)
  registrar("4 replay","BU substitui previsão e peso; pendentes usam válidos T1 vezes a razão aprendida",
    "votos/peso idênticos",sprintf("%s apuradas, %s pendentes",sum(secoes$apurada),nrow(pend)),ok_sub,info)
  labels <- secoes[,.(n=.N,ap=sum(apurada)),keyby=fallback]
  ok_lab <- sum(labels[fallback!="nenhum"]$n)==sum(pop$fallback!="nenhum")&&
    res$fallback_t1==sum(pop$fallback!="nenhum")&&res$fallback_t1_apuradas==sum(obs[pop[fallback!="nenhum"],on=chaves_analise,nomatch=0L]$validos>=0)
  registrar("4 replay","Rótulos de aproximação preservados",sum(pop$fallback!="nenhum"),res$fallback_t1,ok_lab,info)
  expected <- ancora_esperada(official,obs,secoes)
  ok_src <- identical(res$fonte_oficial,expected$area)&&identical(res$fonte_escolhida_coletor,dados$manifesto$official_source_selected)&&
    identical(as.logical(res$ancora_oficial),expected$ok)&&(!expected$ok||abs(res$votos_a_projetados-expected$a)<1e-6*max(1,expected$a))
  registrar(if(s$br=="atual"&&!s$zz_falha)"4 replay" else "3 fonte oficial",
    "Âncora pela soma estadual quando compatível, senão BR, conforme oráculo contábil",
    sprintf("%s (coletor: %s), ancora=%s, votos_a=%s",expected$area,dados$manifesto$official_source_selected,expected$ok,num(expected$a,2)),
    sprintf("%s (coletor: %s), ancora=%s, votos_a=%s",res$fonte_oficial,res$fonte_escolhida_coletor,res$ancora_oficial,
      num(res$votos_a_projetados,2)),ok_src,info)
  frac <- sum(pop[obs,on=chaves_analise]$validos_base)/sum(pop$validos_base)
  w_exp <- min(1,frac/cp$local$fracao_plena)^cp$local$expoente
  registrar("5 tempos e saídas","Peso da atualização gradual segue a fração dos válidos T1 apurada",
    num(w_exp,6),num(res$peso_atualizacao,6),abs(res$peso_atualizacao-w_exp)<1e-12&&
      res$sorteios_atualizados==round(w_exp*400),info)
  if(identical(res$fonte_oficial,"SOMA_UFS")&&isTRUE(res$ancora_oficial)) {
    uf_exp <- vapply(tb$uf$uf,function(u)expected$uf[[u]]$a,0)
    ok_uf <- all(tb$uf$ancora_oficial)&&max(abs(tb$uf$votos_a_projetados-uf_exp))<1e-6*max(uf_exp)&&
      abs(sum(tb$uf$votos_a_projetados)-res$votos_a_projetados)<1e-6*res$votos_a_projetados
    registrar("3 fonte oficial","UFs ancoradas pela soma estadual somam o total","28 UFs ancoradas, soma = total",
      sprintf("%s UFs ancoradas",sum(tb$uf$ancora_oficial)),ok_uf,info)
  } else registrar(if(s$br=="atual"&&!s$zz_falha)"4 replay" else "3 fonte oficial",
    "UFs não usam totais estaduais fora da soma estadual ancorada","0 UFs ancoradas",sum(tb$uf$ancora_oficial),
    !any(tb$uf$ancora_oficial),info)
  ok_int <- res$pct_a_q025<=res$pct_a_projetado&&res$pct_a_projetado<=res$pct_a_q975
  registrar("5 tempos e saídas","Intervalo contém a projeção","q025 <= projeção <= q975",
    sprintf("%s <= %s <= %s",num(res$pct_a_q025,3),num(res$pct_a_projetado,3),num(res$pct_a_q975,3)),ok_int,info)
  # Cenário 2022 (sem aprendizado): mesmos BUs e mesma âncora do cenário com aprendizado.
  soma_ok <- !(identical(res$fonte_oficial,"SOMA_UFS")&&isTRUE(res$ancora_oficial))||
    abs(sum(tb$uf$votos_a_projetados_2022)-res$votos_a_projetados_2022)<1e-6*res$votos_a_projetados_2022
  ok22 <- res$pct_a_2022_q025<=res$pct_a_2022&&res$pct_a_2022<=res$pct_a_2022_q975&&soma_ok
  registrar("5 tempos e saídas","Cenário 2022: intervalo contém a projeção; com soma estadual ancorada, UFs somam o total",
    "q025 <= projeção <= q975",sprintf("%s <= %s <= %s",num(res$pct_a_2022_q025,3),num(res$pct_a_2022,3),
      num(res$pct_a_2022_q975,3)),ok22,info)
  if(s$nome=="S0") {
    d_mean <- max(abs(cp$posterior$mean-state$prior$mean))
    d_cov <- max(abs(cp$posterior$covariance-state$prior$covariance))/max(abs(state$prior$covariance))
    ok0 <- cp$posterior$n==0L&&d_mean<1e-12&&d_cov<1e-10&&abs(res$pct_a_projetado-res$pct_a_coef_iniciais)<1e-10&&
      res$pct_a_q975-res$pct_a_q025>1
    registrar("1 zero BUs","Previsão inicial imediata a partir da prior, sem fração mínima",
      "posterior = prior (inclui Q); projeção = coeficientes iniciais; intervalo não degenerado",
      sprintf("n=%s; dif. média=%g; dif. relativa cov.=%g; projeção=%s; intervalo=[%s, %s]",cp$posterior$n,d_mean,d_cov,
        num(res$pct_a_projetado,3),num(res$pct_a_q025,3),num(res$pct_a_q975,3)),ok0,info)
    registrar("1 zero BUs","Zero BUs: os dois cenários coincidem","diferença 0 no ponto e no intervalo",
      sprintf("%g",max(abs(c(res$pct_a_2022-res$pct_a_projetado,res$pct_a_2022_q025-res$pct_a_q025,res$pct_a_2022_q975-res$pct_a_q975)))),
      max(abs(c(res$pct_a_2022-res$pct_a_projetado,res$pct_a_2022_q025-res$pct_a_q025,res$pct_a_2022_q975-res$pct_a_q975)))<1e-10,info)
    registrar("5 tempos e saídas","Primeiro ciclo concluído com zero BUs","previsão publicada",
      sprintf("%s s",num(ultimo_segundos(A,sid),2)),!is.na(ultimo_segundos(A,sid)),info)
  }
  if(s$nome%in%c("S3","S9")) {
    run <- processx::run(rscript,c("--vanilla",file.path(root,"executar_analise.R"),"atualizar","--snapshot",export,"--saida",coefdir),
      env=env,error_on_status=FALSE)
    coef <- carregar_atualizacao_analise(coefdir)
    # O executor de coeficientes usa resíduos independentes: é o caso sem componentes locais.
    iid <- estado_local_previsao(state,cp$observed[,c(chaves_analise,contagens_analise),with=FALSE],componentes_locais_zero())$posterior
    ok_coef <- run$status==0L&&identical(coef$snapshot_id,sid)&&max(abs(coef$posterior$mean-iid$mean))<1e-10&&
      max(abs(coef$posterior$covariance-iid$covariance))<1e-10
    registrar("2 lotes e retomada","Executor de coeficientes coincide com a previsão sem componentes locais","diferença < 1e-10",
      sprintf("%g; previsão com efeito municipal difere em até %g",max(abs(coef$posterior$mean-iid$mean)),
        max(abs(coef$posterior$mean-cp$posterior$mean))),ok_coef,info)
  }
  if(s$nome=="S3")registrar("2 lotes e retomada","BUs corrigidos contam como revisões",300,cp$changes$revisados,cp$changes$revisados==300L,info)
  if(s$nome=="S4")registrar("2 lotes e retomada","BUs retirados do índice saem da regressão",200,cp$changes$removidos,
    cp$changes$removidos==200L&&cp$posterior$n==sum(obs$validos>0),info)
  if(s$nome=="S4b")registrar("2 lotes e retomada","Snapshot republicado com o mesmo conteúdo não altera resultados",
    resultados$S4$results_sha256,cp$results_sha256,identical(cp$results_sha256,resultados$S4$results_sha256)&&
      cp$changes$novos==0L&&cp$changes$revisados==0L&&cp$changes$removidos==0L,info)
  if(s$nome=="S7")registrar("2 lotes e retomada","BUs devolvidos ao índice voltam como novos",">= 200",cp$changes$novos,
    cp$changes$novos>=200L,info)
  if(s$nome=="S9") {
    tp <- pct_verdade_teste(truth)
    ok9 <- abs(res$pct_a_projetado-tp)<1e-9&&abs(res$pct_a_q975-res$pct_a_q025)<1e-9&&
      res$votos_a_projetados==sum(truth$votos_a)&&res$votos_b_projetados==sum(truth$votos_b)
    registrar("4 replay","100% das seções reproduz o resultado sem dupla contagem",
      sprintf("%s%%; votos_a=%s",num(tp,9),sum(truth$votos_a)),
      sprintf("%s%%; votos_a=%s; amplitude=%g",num(res$pct_a_projetado,9),res$votos_a_projetados,res$pct_a_q975-res$pct_a_q025),ok9,info)
    uf_truth <- truth[,.(pct=100*sum(votos_a)/sum(validos)),keyby=uf]
    registrar("4 replay","100%: todas as UFs reproduzem o resultado","diferença máxima 0",
      sprintf("%g",max(abs(tb$uf[uf_truth,on="uf"]$pct_a_projetado-uf_truth$pct))),
      max(abs(tb$uf[uf_truth,on="uf"]$pct_a_projetado-uf_truth$pct))<1e-9,info)
    d22 <- max(abs(c(res$pct_a_2022-tp,tb$uf[uf_truth,on="uf"]$pct_a_2022-uf_truth$pct)))
    registrar("4 replay","100%: o cenário 2022 também reproduz o resultado no total e nas UFs","diferença máxima 0",
      sprintf("%g; amplitude=%g",d22,res$pct_a_2022_q975-res$pct_a_2022_q025),
      d22<1e-9&&abs(res$pct_a_2022_q975-res$pct_a_2022_q025)<1e-9,info)
  }
  if(s$nome=="S7") {
    tp <- pct_verdade_teste(truth)
    registrar("4 replay","Total oficial completo prevalece com coletor em 90%",num(tp,9),num(res$pct_a_projetado,9),
      isTRUE(res$ancora_oficial)&&abs(res$pct_a_projetado-tp)<1e-9&&abs(res$pct_a_q975-res$pct_a_q025)<1e-9,info)
    registrar("4 replay","Total oficial completo prevalece também no cenário 2022",num(tp,9),num(res$pct_a_2022,9),
      abs(res$pct_a_2022-tp)<1e-9&&abs(res$pct_a_2022_q975-res$pct_a_2022_q025)<1e-9,info)
  }
  # Processo B: interrompido com SIGKILL em S4 e com Ctrl+C em S7.
  latB <- NA_real_
  if(s$nome=="S4") {
    pB <- pacote_atual(outB)$checkpoint
    killed_ok <- !B$is_alive()&&identical(pB$snapshot_id,resultados$S3$snapshot_id)&&
      dir.exists(file.path(outB,".executor.lock"))&&length(list.dirs(file.path(outB,"pacotes"),recursive=FALSE))==3L
    registrar("2 lotes e retomada","SIGKILL durante o cálculo não publica pacote parcial",
      "ponteiro em S3 (sequência 4); lock órfão",sprintf("ponteiro na sequência %s (%s); lock=%s",pB$sequence,
        if(identical(pB$snapshot_id,resultados$S3$snapshot_id))"S3" else "outro",
        dir.exists(file.path(outB,".executor.lock"))),killed_ok,info)
  } else if(s$nome=="S5") {
    B <- iniciar("B2",outB)
    latB <- esperar(outB,sid,B)
    ev <- eventos(B)
    registrar("2 lotes e retomada","Reinício recupera lock órfão e retoma de S3 com o coletor já em S5",
      "evento retomada; S4 não processado",paste(ev$event,collapse=","),
      "retomada"%in%ev$event&&!any(ev$snapshot%in%c(resultados$S4$snapshot_id,resultados$S4b$snapshot_id)),info)
  } else if(s$nome=="S7") {
    pB <- pacote_atual(outB)$checkpoint
    lock_free <- !B$is_alive()&&!dir.exists(file.path(outB,".executor.lock"))&&
      !length(list.files(file.path(outB,"pacotes"),pattern="^\\.previsao-",all.files=TRUE))&&
      identical(pB$snapshot_id,resultados$S6$snapshot_id)
    registrar("2 lotes e retomada","Ctrl+C durante o cálculo encerra, libera o lock e não publica S7",
      "processo encerrado; lock removido; ponteiro em S6",sprintf("vivo=%s; lock=%s; status=%s; ponteiro %s",B$is_alive(),
        dir.exists(file.path(outB,".executor.lock")),B$get_exit_status(),
        if(identical(pB$snapshot_id,resultados$S6$snapshot_id))"S6" else "outro"),lock_free,info)
    B <- iniciar("B3",outB)
    latB <- esperar(outB,sid,B)
  } else if(!s$nome%in%c("S4b")) latB <- esperar(outB,sid,B)
  if(!is.na(latB)||s$nome%in%c("S0","S1","S2","S3")) {
    pB <- pacote_atual(outB)$checkpoint
    registrar("2 lotes e retomada","Retomada produz as mesmas saídas da execução contínua",cp$results_sha256,pB$results_sha256,
      identical(pB$results_sha256,cp$results_sha256)&&identical(pB$snapshot_id,sid),info)
  }
  resultados[[s$nome]] <- list(snapshot_id=sid,results_sha256=cp$results_sha256)
  tempos[[length(tempos)+1L]] <- data.table(snapshot=s$nome,bus=nrow(obs),pct_bus=100*nrow(obs)/N,
    peso_atualizacao=res$peso_atualizacao,
    totalizadas_tse=round(s$frac_f*N),fonte=res$fonte_oficial,ancora=res$ancora_oficial,
    exportacao_coletor_s=pub$export_seconds,publicacao_s=pub$publish_seconds,
    ciclo_previsao_s=ultimo_segundos(A,sid),latencia_ate_publicar_s=latA,
    checkpoint_mb=file.info(file.path(pA$directory,"checkpoint.rds"))$size/1e6,
    pacote_mb=sum(file.info(list.files(pA$directory,full.names=TRUE))$size)/1e6,
    pct_a_projetado=res$pct_a_projetado,pct_a_q025=res$pct_a_q025,pct_a_q975=res$pct_a_q975,
    pct_a_somente_bu=res$pct_a_somente_bu,pct_verdade_final=pct_verdade_teste(truth),
    erro_pp=res$pct_a_projetado-pct_verdade_teste(truth),
    cobre=res$pct_a_q025<=pct_verdade_teste(truth)&&pct_verdade_teste(truth)<=res$pct_a_q975)
  fwrite(rbindlist(tempos),file.path(out,"tempos_fluxo.csv"))
}
Sys.sleep(5)
evA <- eventos(A)
hA <- fread(file.path(outA,"historico.csv"),colClasses="character")
registrar("2 lotes e retomada","Execução contínua processa cada snapshot uma vez e ignora repetições",
  sprintf("%s pacotes; histórico sem repetição",nrow(snapshots)),
  sprintf("%s publicados; %s ignorados; histórico %s linhas",sum(evA$event=="previsao_publicada"),
    sum(evA$event=="snapshot_ja_processado"),nrow(hA)),
  sum(evA$event=="previsao_publicada")==nrow(snapshots)&&any(evA$event=="snapshot_ja_processado")&&
    nrow(hA)==nrow(snapshots)&&!anyDuplicated(hA$snapshot_id),"A: S0-S9")
hB <- fread(file.path(outB,"historico.csv"),colClasses="character")
registrar("2 lotes e retomada","Histórico da execução interrompida não duplica snapshots",
  "sem S4/S4b; sem repetição",paste(hB$snapshot_id%in%c(resultados$S4$snapshot_id,resultados$S4b$snapshot_id),collapse=","),
  !anyDuplicated(hB$snapshot_id)&&!any(hB$snapshot_id%in%c(resultados$S4$snapshot_id,resultados$S4b$snapshot_id))&&
    !anyDuplicated(hB$sequencia),"B: SIGKILL e Ctrl+C")
registrar("2 lotes e retomada","Retenção mantém três pacotes por saída","3 e 3",
  paste(length(list.dirs(file.path(outA,"pacotes"),recursive=FALSE)),length(list.dirs(file.path(outB,"pacotes"),recursive=FALSE))),
  length(list.dirs(file.path(outA,"pacotes"),recursive=FALSE))==3L&&length(list.dirs(file.path(outB,"pacotes"),recursive=FALSE))==3L)
inspect <- processx::run(rscript,c("--vanilla",file.path(root,"executar_previsao.R"),"inspecionar","--saida",outB,"--completo","sim"),
  env=env,error_on_status=FALSE)
registrar("2 lotes e retomada","Checkpoint final regenera exatamente as previsões","status 0",inspect$status,inspect$status==0L)
A$interrupt();A$wait(60000);B$interrupt();B$wait(60000)
if(A$is_alive())A$kill();if(B$is_alive())B$kill()
registrar("2 lotes e retomada","Executores encerrados ao fim do teste","nenhum ativo",paste(A$is_alive(),B$is_alive()),!A$is_alive()&&!B$is_alive())
r <- rbindlist(registro)
jsonlite::write_json(list(scope=paste("Integrated flow on the real frozen 2026 population (499,248 sections) with SYNTHETIC BUs",
    "and official totals written by the real collector code (mock HTTP) and publish_snapshot; executar_previsao.R as separate processes"),
  measured_utc=agora_analise(),passed=sum(r$passou),failed=sum(!r$passou),
  local_components=list(version=cp$local$versao,sha256=cp$local$sha256),
  truth=list(scenario="realista",seed=618370L,arrival="ufs_velocidades",pct_final=pct_verdade_teste(truth),
    zero_valid_sections=25L,revised=300L,removed=200L),
  components_2022=list(residual_var_total=comp$residuo[["total"]],municipal_var=comp$residuo[["entre"]],
    model_sigma2=comp$sigma2_modelo,log_ratio_municipal_var=comp$razao[["entre"]],log_ratio_section_var=comp$razao[["dentro"]]),
  python=python,work_dir=work,code_sha256=c(hashes_codigo_previsao(),
    list(testar_integracao_previsao.R=hash_arquivo_analise(file.path(root,"testar_integracao_previsao.R")),
      teste_integrado_comum.R=hash_arquivo_analise(file.path(root,"teste_integrado_comum.R")),
      publicar_teste_integrado.py=hash_arquivo_analise(file.path(root,"publicar_teste_integrado.py"))))),
  file.path(out,"verificacao_fluxo.json"),pretty=TRUE,auto_unbox=TRUE,digits=NA)
fwrite(comp$rho_uf,file.path(out,"razao_validos_2022_uf.csv"))
print(r[,.(teste,verificacao,passou)])
if(any(!r$passou))quit(status=1L)
