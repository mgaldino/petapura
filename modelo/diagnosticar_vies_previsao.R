# Diagnósticos dos testes integrados: (1) viés do replay de 2022; (2) cenário correto;
# (3) âncora BR versus soma das UFs no snapshot S6 do fluxo completo.
# (1) e (2) descrevem o protótipo anterior às correções 2 e 3 e gravam em prototipo/;
# (3) usa a versão atual, com componentes locais.
# Em (1), com chegada aleatória, a projeção pontual das pendentes é decomposta, sem sorteios:
#   (a) rotina atual: válidos T1 como peso e proporção plogis integrada;
#   (b) mesma proporção com válidos T2 reais como peso (oráculo, indisponível na operação);
#   (c) pesos T1 com a inversa do logit suavizado: (plogis(z)(V+1) - 0,5) / V;
#   (d) oráculo de pesos e inversa juntos.
args_all <- commandArgs(FALSE)
root <- dirname(normalizePath(sub("^--file=","",args_all[grepl("^--file=",args_all)])[1]))
source(file.path(root,"previsao_execucao.R"),encoding="UTF-8")
source(file.path(root,"teste_integrado_comum.R"),encoding="UTF-8")
out <- file.path(root,"output","testes_integrados_20261020")
proto <- file.path(out,"prototipo")
raw <- file.path(root,"..","data","eleicoes_2022_2026","raw")
read <- function(f)as.data.table(arrow::read_parquet(file.path(raw,f)))
t1 <- read("section_votes_2022_T1.parquet");t2 <- read("section_votes_2022_T2.parquet")
d <- .analise_componentes$features_voto_t1(t1,t2)[aptos>0&aptos_t2>0&comparecimento>0&comp_t2>0&validos>0&validos_t2>0]
m <- unique(d[,.(uf,cd_mun)])[order(uf,cd_mun)]
m[,teste:=seq_len(.N)%%5L==0L,by=uf]
test <- d[m[teste==TRUE,.(uf,cd_mun)],on=.(uf,cd_mun)]
setorderv(test,chaves_analise)
fit <- readRDS(file.path(root,"output","comparecimento_preditor_20261020","T1","voto_t1","posterior.rds"))
prior <- .analise_componentes$prior_online(fit)
X <- .analise_componentes$X_comparecimento(test,prior$spec)
group <- match(test$uf,prior$levels)
truth <- 100*sum(test$lula_t2)/sum(test$validos_t2)
rows <- list()
for(rep in 1:40)for(f in c(.01,.05,.25)) {
  set.seed(910000L+rep)
  perm <- sample.int(nrow(test))
  obs <- sort(perm[seq_len(round(f*nrow(test)))]);pend <- setdiff(seq_len(nrow(test)),obs)
  s <- .analise_componentes$online_stats(prior,test[obs],test$y_lula[obs])
  post <- .analise_componentes$posterior_online(prior,s)
  p <- preditiva_secoes_previsao(prior,X[pend,,drop=FALSE],group[pend],post$mean,post$covariance)
  known_a <- sum(test$lula_t2[obs]);known_v <- sum(test$validos_t2[obs])
  w1 <- test$validos[pend];w2 <- test$validos_t2[pend]
  # Inversa do logit suavizado aplicada à média preditiva do numerador (a + 0,5) / (V + 1).
  inv <- function(w)pmin(w,pmax(0,p$p*(w+1)-.5))
  est <- function(a_pend,w)100*(known_a+sum(a_pend))/(known_v+sum(w))
  rows[[length(rows)+1L]] <- data.table(repeticao=rep,fracao=f,
    atual=est(w1*p$p,w1)-truth,oraculo_pesos=est(w2*p$p,w2)-truth,
    inversa_logit=est(inv(w1),w1)-truth,oraculo_e_inversa=est(inv(w2),w2)-truth)
}
r <- rbindlist(rows)
summary <- r[,lapply(.SD,mean),keyby=fracao,.SDcols=c("atual","oraculo_pesos","inversa_logit","oraculo_e_inversa")]
fwrite(r,file.path(proto,"diagnostico_vies_replay_2022.csv"))
fwrite(summary,file.path(proto,"diagnostico_vies_replay_2022_resumo.csv"))
print(summary)

# Cenário sintético "correto" na população de 2026, chegada aleatória e 25% dos BUs:
# compara a rotina atual, a inversa do logit suavizado e os coeficientes verdadeiros.
state <- carregar_ponto_partida_analise(file.path(root,"data","processed","estado_inicial_v2"))
pop <- state$population;p26 <- state$prior
X26 <- .analise_componentes$X_comparecimento(pop,p26$spec);g26 <- match(pop$uf,p26$levels)
sim <- fread(file.path(proto,"chegada_simulacao_2026.csv"))[cenario=="correto"&ordem=="aleatoria"&fracao==.25]
rows <- list()
for(rep in 1:12) {
  truth26 <- gerar_verdade_teste(state,NULL,"correto",seed=700000L+rep*10L)
  perm <- ordem_chegada_teste(truth26,"aleatoria",800000L+rep*100L+1L)
  obs <- perm[seq_len(round(.25*nrow(truth26)))];pend <- setdiff(seq_len(nrow(truth26)),obs)
  o <- truth26[obs,.(uf,cd_mun,zona,secao,aptos,comparecimento,validos,votos_a,votos_b,brancos,nulos)]
  post <- .analise_componentes$snapshot_online(p26,pop,o)
  p <- preditiva_secoes_previsao(p26,X26[pend,,drop=FALSE],g26[pend],post$mean,post$covariance)
  tp <- pct_verdade_teste(truth26);w <- pop$validos_base[pend]
  ka <- sum(truth26$votos_a[obs]);kv <- sum(truth26$validos[obs])
  mu <- preditor_linear_teste(p26,X26[pend,,drop=FALSE],g26[pend],attr(truth26,"theta"))
  rows[[rep]] <- data.table(repeticao=rep,erro_atual=100*(ka+sum(w*p$p))/(kv+sum(w))-tp,
    erro_inversa_logit=100*(ka+sum(pmax(0,p$p*(w+1)-.5)))/(kv+sum(w))-tp,
    erro_coeficientes_verdadeiros=100*(ka+sum(w*.analise_componentes$logistic_normal_mean(mu,p26$sigma)))/(kv+sum(w))-tp,
    erro_rotina_registrado=sim[repeticao==rep]$erro_pp,amplitude_intervalo=sim[repeticao==rep]$amplitude_pp)
}
r26 <- rbindlist(rows)
exigir_analise(max(abs(r26$erro_atual-r26$erro_rotina_registrado))<1e-8,"Diagnóstico não reproduz a rotina registrada")
fwrite(r26,file.path(proto,"diagnostico_vies_correto_2026.csv"))
print(r26[,lapply(.SD,function(x)c(media=mean(x),reqm=sqrt(mean(x^2)))),.SDcols=-1])

# (3) Snapshot S6 do fluxo completo, reconstruído com as sementes de
# testar_integracao_previsao.R: coletor em 75%, TSE em 85%, UFs em ritmos diferentes.
comp <- componentes_2022_teste(root)
truth6 <- gerar_verdade_teste(state,comp,"realista",seed=618370L,zero_validos=25L)
ord <- ordem_chegada_teste(truth6,"ufs_velocidades",618371L)
first <- function(f)ord[seq_len(round(f*nrow(truth6)))]
set.seed(618372L)
revised <- sample(first(.05),300)
removed <- sample(setdiff(first(.10),revised),200)
obs <- truth6[setdiff(first(.75),removed),.(uf,cd_mun,zona,secao,aptos,comparecimento,validos,votos_a,votos_b,brancos,nulos)]
tot <- truth6[first(.85)]
area <- function(name,v,ts)list(area=name,st=nrow(v),ts=ts,votos_a=sum(v$votos_a),votos_b=sum(v$votos_b),
  validos=sum(v$votos_a+v$votos_b),generated="2026-10-25T18:00:00",current=TRUE)
states <- lapply(sort(unique(pop$uf)),function(u)area(u,tot[uf==u],nrow(pop[uf==u])))
local <- ler_componentes_locais();est6 <- estado_local_previsao(state,obs,local)
br <- resultados_previsao_analise(state,obs,list(chosen=area("BR",tot,nrow(pop))),400L,local=local,est=est6)
soma <- resultados_previsao_analise(state,obs,list(chosen=area("SOMA_UFS",tot,nrow(pop)),states=states),400L,local=local,est=est6)
flow <- fread(file.path(out,"tempos_fluxo.csv"))[snapshot=="S6"]
exigir_analise(abs(soma$resumo$pct_a_projetado-flow$pct_a_projetado)<1e-9,"Reconstrução de S6 difere do fluxo registrado")
tp6 <- pct_verdade_teste(truth6)
s6 <- data.table(ancora=c("BR","SOMA_UFS","somente_BUs"),
  pct_a_projetado=c(br$resumo$pct_a_projetado,soma$resumo$pct_a_projetado,br$resumo$pct_a_somente_bu),
  q025=c(br$resumo$pct_a_q025,soma$resumo$pct_a_q025,br$resumo$pct_a_somente_bu_q025),
  q975=c(br$resumo$pct_a_q975,soma$resumo$pct_a_q975,br$resumo$pct_a_somente_bu_q975),verdade_final=tp6)
s6[,erro_pp:=pct_a_projetado-verdade_final]
fwrite(s6,file.path(out,"diagnostico_ancora_s6.csv"))
print(s6)
