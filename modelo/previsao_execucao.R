# Itens 3 e 4: previsões com a posterior conjunta dos 59 coeficientes e checkpoint.
# Compõe o estado inicial e o leitor validado (itens 1 e 2), o atualizador
# conjugado, a substituição por BUs, os pesos T1 e a âncora oficial.
# Correções 2 e 3 dos testes integrados (componentes_locais.R): efeito municipal no voto,
# razão de válidos T2/T1 aprendida com os BUs e inversa do logit suavizado.
# Dois cenários (21/10/2026): "com aprendizado" (colunas pct_a_projetado, pct_a_q025,
# pct_a_q975) e "2022", sem aprendizado (colunas pct_a_2022*), com os mesmos BUs e a mesma
# âncora oficial. Plano: ../../quality_reports/plans/2026-10-21_dois-cenarios-previsao.md.
.previsao_dir <- dirname(normalizePath(sys.frame(1)$ofile))
source(file.path(.previsao_dir,"analise_execucao.R"),encoding="UTF-8")
source(file.path(.previsao_dir,"ancorar.R"),local=.analise_componentes,encoding="UTF-8")
source(file.path(.previsao_dir,"componentes_locais.R"),encoding="UTF-8")

hashes_codigo_previsao <- function()c(hashes_codigo_analise(),
  list(previsao_execucao.R=hash_arquivo_analise(file.path(.previsao_dir,"previsao_execucao.R")),
       componentes_locais.R=hash_arquivo_analise(file.path(.previsao_dir,"componentes_locais.R")),
       ancorar.R=hash_arquivo_analise(file.path(.previsao_dir,"ancorar.R"))))

validar_sorteios_previsao <- function(sorteios,semente) {
  exigir_analise(length(sorteios)==1L&&is.finite(sorteios)&&sorteios>=2&&sorteios==floor(sorteios),
    "Número de sorteios deve ser inteiro maior ou igual a 2")
  exigir_analise(length(semente)==1L&&is.finite(semente)&&semente==floor(semente)&&
    abs(semente)<=.Machine$integer.max,"Semente inválida")
  list(sorteios=as.integer(sorteios),semente=as.integer(semente))
}

# Preditiva da seção no logit: N(x'm, sigma^2 + x'Vx). Usa o bloco de 5 coeficientes da UF.
preditiva_secoes_previsao <- function(prior,X,group,mean,covariance) {
  mu <- variance <- numeric(nrow(X))
  for(g in seq_along(prior$levels)) {
    i <- which(group==g)
    if(!length(i))next
    j <- prior$map[[g]]
    Xi <- X[i,,drop=FALSE]
    mu[i] <- as.numeric(Xi%*%mean[j])
    variance[i] <- rowSums((Xi%*%covariance[j,j,drop=FALSE])*Xi)
  }
  sd <- sqrt(pmax(variance,0)+prior$sigma^2)
  list(mu=mu,sd=sd,p=.analise_componentes$logistic_normal_mean(mu,sd))
}

# Uma linha por UF de draw: coeficientes conjuntos, choques municipais condicionais aos
# coeficientes, razão de válidos T2/T1 e resíduo em cada seção pendente.
sorteios_uf_previsao <- function(state,est,X,group,mun_rows,weights,pending,observed_uf,sorteios,semente) {
  prior <- state$prior;loc <- est$local;v <- est$voto;w <- est$validos
  theta <- .analise_componentes$sample_online(est$posterior,n=sorteios,seed=semente)
  lambda <- sortear_lambda(w,sorteios)
  ufs <- observed_uf$uf;gk <- match(ufs,prior$levels)
  index <- lapply(gk,function(g)pending[group[pending]==g])
  blocks <- lapply(index,function(i)X[i,,drop=FALSE])
  w1 <- lapply(index,function(i)weights[i]);mb <- lapply(index,function(i)mun_rows[i])
  maps <- lapply(gk,function(g)prior$map[[g]])
  idx <- if(length(v$mun))matrix(unlist(lapply(v$g,function(g)prior$map[[g]])),ncol=5L,byrow=TRUE) else NULL
  pending_a <- pending_v <- matrix(0,sorteios,length(ufs))
  for(d in seq_len(sorteios)) {
    u <- rnorm(est$municipios,0,sqrt(loc$tau2))
    if(length(v$mun))u[v$mun] <- v$c*(v$Y-rowSums(v$S*matrix(theta[d,idx],ncol=5L)))+
      rnorm(length(v$mun),0,sqrt(v$var_u))
    nu <- rnorm(est$municipios,0,sqrt(loc$var_m))
    if(length(w$mun))nu[w$mun] <- w$k*(w$lbar-lambda[d,w$g])+rnorm(length(w$mun),0,sqrt(w$var_nu))
    for(k in seq_along(ufs)) {
      n <- length(index[[k]])
      if(!n)next
      z <- as.numeric(blocks[[k]]%*%theta[d,maps[[k]]])+u[mb[[k]]]+rnorm(n,0,sqrt(est$s2w))
      W <- w1[[k]]*exp(lambda[d,gk[k]]+nu[mb[[k]]]+rnorm(n,0,sqrt(loc$var_i)))
      pending_a[d,k] <- sum(votos_da_proporcao(plogis(z),W));pending_v[d,k] <- sum(W)
    }
  }
  data.table(draw=rep(seq_len(sorteios),times=length(ufs)),uf=rep(ufs,each=sorteios),
    votos_a=rep(observed_uf$a,each=sorteios)+as.numeric(pending_a),
    votos_b=rep(observed_uf$b,each=sorteios)+as.numeric(pending_v)-as.numeric(pending_a))
}

# Âncora por UF somente quando a soma estadual é a fonte escolhida e ancorou o total.
# Cada UF passa pela mesma função do total, com a UF como área única.
ancorar_ufs_previsao <- function(uf,posterior_uf,official,total) {
  uf[,`:=`(pct_a_somente_bu=pct_a_projetado,pct_a_somente_bu_q025=pct_a_q025,
    pct_a_somente_bu_q975=pct_a_q975,fonte_oficial=NA_character_,secoes_totalizadas_tse=NA_real_,
    pct_a_apurado_oficial=NA_real_,ancora_oficial=FALSE)]
  if(is.null(official)||!identical(official$chosen$area,"SOMA_UFS")||!isTRUE(total$ancora_oficial))return(uf)
  areas <- vapply(official$states,function(u)u$area,"")
  exigir_analise(setequal(areas,uf$uf)&&!anyDuplicated(areas),"Soma estadual sem correspondência com as UFs da população")
  for(u in official$states) {
    row <- uf[uf==u$area]
    a <- .analise_componentes$ancorar_oficial(list(resumo=data.table::copy(row),
      posterior=posterior_uf[uf==u$area]),list(chosen=u))
    exigir_analise(isTRUE(a$ancora_oficial),paste("UF incompatível com total já ancorado:",u$area))
    uf[uf==u$area,`:=`(votos_a_projetados=a$votos_a_projetados,votos_b_projetados=a$votos_b_projetados,
      pct_a_projetado=a$pct_a_projetado,pct_a_q025=a$pct_a_q025,pct_a_q975=a$pct_a_q975,
      fonte_oficial="SOMA_UFS",secoes_totalizadas_tse=as.numeric(u$st),
      pct_a_apurado_oficial=a$pct_a_apurado_oficial,ancora_oficial=TRUE)]
  }
  exigir_analise(abs(sum(uf$votos_a_projetados)-total$votos_a_projetados)<=1e-6*max(1,total$votos_a_projetados),
    "UFs ancoradas não somam o total ancorado")
  uf
}

# Item 1 (aprovado): a soma das 27 UFs e ZZ ancora quando os 28 totais estão disponíveis e
# compatíveis com os BUs, mesmo que o total BR esteja mais avançado; o BR só ancora quando a
# soma estadual não serve. As duas fontes nunca se somam.
ancorar_previsao <- function(total,uf,draws,posterior_uf,official) {
  result <- list(resumo=total,uf=uf,posterior=draws,posterior_uf=posterior_uf)
  attempt <- function(o)list(total=.analise_componentes$ancorar_oficial(result,o),official=o)
  if(is.null(official))return(attempt(NULL))
  states <- official$states
  areas <- vapply(states,function(u)if(is.null(u$area))"" else u$area,"")
  if(length(states)==nrow(uf)&&setequal(areas,uf$uf)&&!anyDuplicated(areas)) {
    num <- function(k)sum(vapply(states,function(u)as.numeric(u[[k]]),0))
    gen <- unlist(lapply(states,function(u)u$generated))
    soma <- list(area="SOMA_UFS",st=num("st"),ts=num("ts"),votos_a=num("votos_a"),votos_b=num("votos_b"),
      validos=num("validos"),generated=if(length(gen))max(gen) else NULL,
      current=all(vapply(states,function(u)!isFALSE(u$current),TRUE)))
    r <- attempt(list(chosen=soma,states=states,national_lag_sections=official$national_lag_sections))
    if(isTRUE(r$total$ancora_oficial))return(r)
  }
  # [[ ]] exige nome exato: official$national casaria parcialmente com national_lag_sections.
  br <- if(!is.null(official[["national"]]))official[["national"]] else if(identical(official$chosen$area,"BR"))official$chosen else NULL
  if(!is.null(br)) {
    r <- attempt(list(chosen=br,national_lag_sections=official$national_lag_sections))
    if(isTRUE(r$total$ancora_oficial))return(r)
  }
  # Nenhuma fonte compatível: projeção só com BUs, mantendo a descrição da escolha do coletor.
  attempt(official)
}

resultados_previsao_analise <- function(state,observed,official=NULL,sorteios=400L,semente=618360L,
                                       local=ler_componentes_locais(),est=NULL) {
  settings <- validar_sorteios_previsao(sorteios,semente)
  prior <- state$prior;pop <- state$population
  vars <- prior$spec$vars
  need <- c(chaves_analise,"validos_base","fallback",vars)
  exigir_analise(all(need%in%names(pop)),"População sem preditores, pesos ou rótulos")
  obs <- data.table::as.data.table(observed)[,c(chaves_analise,"validos","votos_a","votos_b"),with=FALSE]
  exigir_analise(!nrow(obs[!pop,on=chaves_analise]),"BU fora da população congelada")
  if(is.null(est))est <- estado_local_previsao(state,obs,local)
  posterior <- est$posterior;loc <- est$local
  exigir_analise(identical(names(posterior$mean),prior$names)&&
    identical(dim(posterior$covariance),dim(prior$covariance))&&posterior$sigma==prior$sigma,
    "Posterior incompatível com o estado inicial")
  b <- merge(pop[,..need],obs,by=chaves_analise,all.x=TRUE,sort=TRUE)
  exigir_analise(nrow(b)==nrow(pop)&&identical(b$uf,pop$uf)&&identical(b$cd_mun,pop$cd_mun)&&
    identical(b$secao,pop$secao),"Ordem da população divergente")
  b[,apurada:=!is.na(validos)]
  X <- .analise_componentes$X_comparecimento(b,prior$spec)
  group <- match(b$uf,prior$levels)
  exigir_analise(!anyNA(group),"Seção em grupo sem coeficientes")
  mun <- municipios_populacao(pop)
  now <- preditiva_local(state,est,X,group,mun)
  start <- preditiva_secoes_previsao(prior,X,group,prior$mean,prior$covariance)
  z <- qnorm(.975)
  # Atualização gradual: peso w do modelo atualizado cresce com a fração dos válidos T1 apurada.
  frac <- sum(b$validos_base[b$apurada])/sum(b$validos_base)
  w <- peso_atualizacao(frac,loc)
  p1 <- .analise_componentes$logistic_normal_mean(now$mu_z,now$sd_z);p0 <- start$p
  # Válidos T2 esperados das pendentes: válidos T1 vezes a razão (aprendida ou da prior), lognormal.
  ew1 <- b$validos_base*exp(now$log_ratio_mean+now$log_ratio_var/2)
  ew0 <- b$validos_base*exp((loc$s0^2+loc$sg^2+loc$var_m+loc$var_i)/2)
  obs_v <- as.numeric(b$validos)
  V1 <- fifelse(b$apurada,obs_v,ew1);V0 <- fifelse(b$apurada,obs_v,ew0)
  a1 <- votos_da_proporcao(p1,V1);a0 <- votos_da_proporcao(p0,V0)
  V <- (1-w)*V0+w*V1;a_mod <- (1-w)*a0+w*a1
  observed_pct <- 100*b$votos_a/b$validos
  observed_pct[!b$apurada|b$validos==0] <- NA_real_
  pending <- which(!b$apurada)
  share <- function(p,W)100*votos_da_proporcao(p,W)/W
  q_lo <- q_hi <- q0_lo <- q0_hi <- rep(NA_real_,nrow(b))
  if(length(pending)) {
    i <- pending
    # Cenário 2022: preditiva da relação de 2022 (com Q), sem aprendizado.
    q0_lo[i] <- share(plogis(start$mu[i]-z*start$sd[i]),V0[i]);q0_hi[i] <- share(plogis(start$mu[i]+z*start$sd[i]),V0[i])
    if(w>=1) {
      q_lo[i] <- share(plogis(now$mu_z[i]-z*now$sd_z[i]),V1[i]);q_hi[i] <- share(plogis(now$mu_z[i]+z*now$sd_z[i]),V1[i])
    } else if(w<=0) {
      q_lo[i] <- q0_lo[i];q_hi[i] <- q0_hi[i]
    } else for(pr in c(.025,.975)) {
      q <- 100*quantis_mistura(pr,w,start$mu[i],start$sd[i],V0[i],now$mu_z[i],now$sd_z[i],V1[i])
      if(pr<.5)q_lo[i] <- q else q_hi[i] <- q
    }
  }
  # Votos efetivos substituem previsão e peso das seções apuradas.
  b[,`:=`(validos_projetados=V,razao_validos_t2_t1=fifelse(apurada,NA_real_,V/validos_base),
    votos_a_projetados=fifelse(apurada,as.numeric(votos_a),a_mod),
    votos_b_projetados=fifelse(apurada,as.numeric(votos_b),V-a_mod),
    votos_a_coef_iniciais=fifelse(apurada,as.numeric(votos_a),a0),validos_coef_iniciais=V0,
    pct_a_modelo=fifelse(V>0,100*a_mod/V,NA_real_),logit_media_modelo=now$mu_z,logit_dp_preditivo=now$sd_z)]
  b[,`:=`(pct_a_projetado=fifelse(apurada,observed_pct,100*a_mod/V),
    pct_a_q025=fifelse(apurada,observed_pct,q_lo),pct_a_q975=fifelse(apurada,observed_pct,q_hi),
    pct_a_2022=fifelse(apurada,observed_pct,fifelse(V0>0,100*a0/V0,NA_real_)),
    pct_a_2022_q025=fifelse(apurada,observed_pct,q0_lo),pct_a_2022_q975=fifelse(apurada,observed_pct,q0_hi))]
  observed_uf <- b[,.(a=sum(votos_a,na.rm=TRUE),b=sum(votos_b,na.rm=TRUE)),keyby=uf]
  # Sorteios estratificados da mistura: round(w * S) do modelo atualizado e o restante do
  # inicial (prior, sem aprendizado). sample_online() fixa a semente de cada componente,
  # então o mesmo snapshot gera os mesmos sorteios numa execução contínua ou retomada.
  n1 <- as.integer(round(w*settings$sorteios));n0 <- settings$sorteios-n1
  est0 <- estado_local_previsao(state,obs[0],loc)
  seed0 <- if(settings$semente<.Machine$integer.max)settings$semente+1L else settings$semente-1L
  parts <- list()
  if(n1>0)parts[[1]] <- sorteios_uf_previsao(state,est,X,group,mun,b$validos_base,pending,observed_uf,n1,settings$semente)
  if(n0>0) {
    d0 <- sorteios_uf_previsao(state,est0,X,group,mun,b$validos_base,pending,observed_uf,n0,seed0)
    d0[,draw:=draw+n1];parts[[length(parts)+1L]] <- d0
  }
  posterior_uf <- rbindlist(parts)
  # Cenário 2022: os mesmos BUs apurados e, nas pendentes, a relação de 2022 com a incerteza
  # da mudança entre eleições (Q), sem aprender nada com os BUs. Com w = 0 os dois coincidem.
  posterior_uf_2022 <- if(n0==settings$sorteios)data.table::copy(posterior_uf) else
    sorteios_uf_previsao(state,est0,X,group,mun,b$validos_base,pending,observed_uf,settings$sorteios,seed0)
  agregar <- function(d)d[,.(votos_a=sum(votos_a),votos_b=sum(votos_b)),keyby=draw][,pct_a:=100*votos_a/(votos_a+votos_b)][]
  draws <- agregar(posterior_uf);draws_2022 <- agregar(posterior_uf_2022)
  posterior_uf[,pct_a:=100*votos_a/(votos_a+votos_b)]
  posterior_uf_2022[,pct_a:=100*votos_a/(votos_a+votos_b)]
  uf_draws <- posterior_uf[,.(pct_a_q025=quantile(pct_a,.025,names=FALSE),
    pct_a_q975=quantile(pct_a,.975,names=FALSE)),keyby=uf]
  ratio <- data.table(uf=prior$levels,razao_validos_uf=exp(est$validos$mu),
    razao_validos_uf_q025=exp(est$validos$mu-z*sqrt(diag(est$validos$cov))),
    razao_validos_uf_q975=exp(est$validos$mu+z*sqrt(diag(est$validos$cov))))
  b[,mun:=mun]
  seen_mun <- est$voto$mun
  uf <- b[,.(secoes=.N,secoes_apuradas_coletor=sum(apurada),secoes_pendentes=sum(!apurada),
    secoes_zero_validos=sum(apurada&validos==0),secoes_aproximadas=sum(fallback!="nenhum"),
    aproximadas_apuradas=sum(fallback!="nenhum"&apurada),municipios=uniqueN(mun),
    municipios_com_bus=sum(unique(mun)%in%seen_mun),
    votos_a_observados=sum(votos_a,na.rm=TRUE),votos_b_observados=sum(votos_b,na.rm=TRUE),
    validos_pendentes_projetados=sum(validos_projetados[!apurada]),validos_pendentes_t1=sum(validos_base[!apurada]),
    votos_a_projetados=sum(votos_a_projetados),votos_b_projetados=sum(votos_b_projetados),
    votos_a_coef_iniciais=sum(votos_a_coef_iniciais),validos_coef_iniciais=sum(validos_coef_iniciais)),keyby=uf]
  uf[,`:=`(pct_a_apurado=fifelse(votos_a_observados+votos_b_observados>0,
      100*votos_a_observados/(votos_a_observados+votos_b_observados),NA_real_),
    pct_a_projetado=100*votos_a_projetados/(votos_a_projetados+votos_b_projetados),
    pct_a_coef_iniciais=100*votos_a_coef_iniciais/validos_coef_iniciais)]
  uf <- merge(merge(uf,uf_draws,by="uf",sort=TRUE),ratio,by="uf",all.x=TRUE,sort=TRUE)
  # Cenário 2022: ponto com os coeficientes iniciais e intervalo dos sorteios próprios.
  cenario_2022 <- function(x,q025,q975)data.table::copy(x)[,`:=`(votos_a_projetados=votos_a_coef_iniciais,
    votos_b_projetados=validos_coef_iniciais-votos_a_coef_iniciais,pct_a_projetado=pct_a_coef_iniciais,
    pct_a_q025=q025,pct_a_q975=q975)][]
  q22 <- posterior_uf_2022[,.(q025=quantile(pct_a,.025,names=FALSE),q975=quantile(pct_a,.975,names=FALSE)),keyby=uf]
  exigir_analise(identical(q22$uf,uf$uf),"UFs do cenário 2022 divergentes")
  uf_2022 <- cenario_2022(uf,q22$q025,q22$q975)
  valid_obs <- sum(b$validos,na.rm=TRUE)
  total <- b[,.(secoes=.N,secoes_apuradas_coletor=sum(apurada),pct_secoes_coletor=100*mean(apurada),
    secoes_regressao=posterior$n,secoes_zero_validos=sum(apurada&validos==0),
    municipios=uniqueN(mun),municipios_com_bus=length(seen_mun),
    fallback_t1=sum(fallback!="nenhum"),fallback_t1_apuradas=sum(fallback!="nenhum"&apurada),
    votos_a_observados=sum(votos_a,na.rm=TRUE),votos_b_observados=sum(votos_b,na.rm=TRUE),
    validos_pendentes_projetados=sum(validos_projetados[!apurada]),validos_pendentes_t1=sum(validos_base[!apurada]),
    votos_a_projetados=sum(votos_a_projetados),votos_b_projetados=sum(votos_b_projetados),
    votos_a_coef_iniciais=sum(votos_a_coef_iniciais),validos_coef_iniciais=sum(validos_coef_iniciais))]
  total[,`:=`(pct_a_apurado=if(valid_obs>0)100*votos_a_observados/valid_obs else NA_real_,
    pct_a_projetado=100*votos_a_projetados/(votos_a_projetados+votos_b_projetados),
    pct_a_coef_iniciais=100*votos_a_coef_iniciais/validos_coef_iniciais,
    razao_validos_pendentes=if(validos_pendentes_t1>0)validos_pendentes_projetados/validos_pendentes_t1 else NA_real_,
    fracao_validos_t1_apurada=frac,peso_atualizacao=w,sorteios_atualizados=n1,
    pct_a_q025=quantile(draws$pct_a,.025,names=FALSE),pct_a_q975=quantile(draws$pct_a,.975,names=FALSE))]
  total[,`:=`(pct_a_somente_bu_q025=pct_a_q025,pct_a_somente_bu_q975=pct_a_q975)]
  total_2022 <- cenario_2022(total,quantile(draws_2022$pct_a,.025,names=FALSE),quantile(draws_2022$pct_a,.975,names=FALSE))
  # Item 1: soma estadual quando completa e compatível; senão BR; nunca as duas.
  anchored <- ancorar_previsao(total,uf,draws,posterior_uf,official)
  total <- anchored$total
  total[,fonte_escolhida_coletor:=if(is.null(official$chosen$area))NA_character_ else official$chosen$area]
  uf <- ancorar_ufs_previsao(uf,posterior_uf,anchored$official,total)
  # Os BUs apurados são os mesmos nos dois cenários; logo a fonte compatível também.
  anchored_2022 <- ancorar_previsao(total_2022,uf_2022,draws_2022,posterior_uf_2022,official)
  t22 <- anchored_2022$total
  exigir_analise(identical(t22$fonte_oficial,total$fonte_oficial)&&identical(t22$ancora_oficial,total$ancora_oficial),
    "Cenário 2022 e cenário com aprendizado com âncoras diferentes")
  uf_2022 <- ancorar_ufs_previsao(uf_2022,posterior_uf_2022,anchored_2022$official,t22)
  total[,`:=`(votos_a_projetados_2022=t22$votos_a_projetados,votos_b_projetados_2022=t22$votos_b_projetados,
    pct_a_2022=t22$pct_a_projetado,pct_a_2022_q025=t22$pct_a_q025,pct_a_2022_q975=t22$pct_a_q975)]
  uf[uf_2022,on="uf",`:=`(votos_a_projetados_2022=i.votos_a_projetados,votos_b_projetados_2022=i.votos_b_projetados,
    pct_a_2022=i.pct_a_projetado,pct_a_2022_q025=i.pct_a_q025,pct_a_2022_q975=i.pct_a_q975)]
  for(x in list(total,uf))data.table::setcolorder(x,c("pct_a_2022","pct_a_2022_q025","pct_a_2022_q975"),after="pct_a_q975")
  effect <- .analise_componentes$coefficient_online(prior,posterior)
  total[,`:=`(comp_log_odds_por_1pp=effect$media_log_odds_por_1pp,comp_q025_log_odds=effect$q025_log_odds,
    comp_q975_log_odds=effect$q975_log_odds,comp_prob_positivo=effect$prob_positivo,
    sorteios=settings$sorteios,semente=settings$semente,modelo="voto_t1_conjugado_59_coeficientes_local",
    versao_escalas=state$provenance$drift_version,perfil_escalas=state$provenance$profile,
    versao_componentes_locais=loc$versao,estado_inicial_id=state$id)]
  sd0 <- sqrt(diag(prior$covariance));sd1 <- sqrt(diag(posterior$covariance))
  coefficients <- data.table(coeficiente=prior$names,media_inicial=unname(prior$mean),dp_inicial=unname(sd0),
    media_atual=unname(posterior$mean),dp_atual=unname(sd1),
    q025_atual=unname(posterior$mean-z*sd1),q975_atual=unname(posterior$mean+z*sd1),
    mudanca=unname(posterior$mean-prior$mean),mudanca_em_dp_inicial=unname((posterior$mean-prior$mean)/sd0),
    secoes_regressao=posterior$n)
  approximations <- b[,.(secoes=.N,apuradas=sum(apurada),pendentes=sum(!apurada)),keyby=fallback]
  sections <- b[,c(chaves_analise,"fallback","apurada","validos","votos_a","votos_b","validos_projetados",
    "razao_validos_t2_t1","votos_a_projetados","votos_b_projetados","pct_a_projetado","pct_a_q025","pct_a_q975",
    "pct_a_2022","pct_a_2022_q025","pct_a_2022_q975","pct_a_modelo","logit_media_modelo","logit_dp_preditivo"),with=FALSE]
  data.table::setnames(sections,c("validos","votos_a","votos_b"),
    c("validos_observados","votos_a_observados","votos_b_observados"))
  list(resumo=total,uf=uf,secoes=sections,coeficientes=coefficients,aproximacoes=approximations,
    posterior=draws,posterior_uf=posterior_uf[,.(draw,uf,votos_a,votos_b,pct_a)],
    posterior_2022=draws_2022,posterior_uf_2022=posterior_uf_2022[,.(draw,uf,votos_a,votos_b,pct_a)],settings=settings,estado=est)
}

# ---------- Item 4: checkpoint e retomada ----------

tabelas_previsao <- c(resumo="resumo.csv",uf="uf.csv",secoes="secoes.csv",coeficientes="coeficientes.csv",
  aproximacoes="aproximacoes.csv",posterior="sorteios_total.csv",posterior_uf="sorteios_uf.csv")
padrao_pacote_previsao <- "^[0-9]{8}_[a-f0-9]{64}$"


versoes_bus_previsao <- function(dados,observed) {
  versions <- normalizar_chaves_analise(dados$secoes)
  if(!"hash"%in%names(versions))versions[,hash:=NA_character_]
  versions <- versions[,.(uf,cd_mun,zona,secao,hash=as.character(hash))]
  z <- merge(observed,versions,by=chaves_analise,all.x=TRUE,sort=TRUE)
  exigir_analise(nrow(z)==nrow(observed),"Versões de BU sem correspondência")
  z
}

mudancas_bus_previsao <- function(old,new) {
  if(is.null(old))return(list(novos=nrow(new),revisados=0L,removidos=0L,inalterados=0L))
  cols <- c("hash",contagens_analise)
  both <- merge(old[,c(chaves_analise,cols),with=FALSE],new[,c(chaves_analise,cols),with=FALSE],
    by=chaves_analise,suffixes=c("_old","_new"))
  same <- Reduce(`&`,lapply(cols,function(k){
    a <- both[[paste0(k,"_old")]];b <- both[[paste0(k,"_new")]]
    (is.na(a)&is.na(b))|(!is.na(a)&!is.na(b)&a==b)}),init=rep(TRUE,nrow(both)))
  list(novos=nrow(new[!old,on=chaves_analise]),revisados=sum(!same),
    removidos=nrow(old[!new,on=chaves_analise]),inalterados=sum(same))
}

gravar_pacote_previsao <- function(checkpoint,tables,directory) {
  if(dir.exists(directory)) {
    old <- ler_pacote_previsao(directory)
    exigir_analise(identical(old$checkpoint$id,checkpoint$id),"Pacote existente com outro conteúdo")
    return(invisible(directory))
  }
  tmp <- tempfile(".previsao-",tmpdir=dirname(directory))
  dir.create(tmp)
  on.exit(unlink(tmp,recursive=TRUE),add=TRUE)
  saveRDS(checkpoint,file.path(tmp,"checkpoint.rds"),version=3,compress="gzip")
  for(name in names(tabelas_previsao))data.table::fwrite(tables[[name]],file.path(tmp,tabelas_previsao[[name]]))
  files <- c("checkpoint.rds",unname(tabelas_previsao))
  jsonlite::write_json(list(schema_version=1L,kind=checkpoint$kind,id=checkpoint$id,sequence=checkpoint$sequence,
    snapshot_id=checkpoint$snapshot_id,initial_state_id=checkpoint$initial_state_id,created_utc=checkpoint$created_utc,
    files=setNames(lapply(files,function(f)hash_arquivo_analise(file.path(tmp,f))),files)),
    file.path(tmp,"manifest.json"),pretty=TRUE,auto_unbox=TRUE)
  exigir_analise(file.rename(tmp,directory),"Não foi possível publicar o pacote de previsão")
  invisible(directory)
}

ler_pacote_previsao <- function(directory,tables=FALSE) {
  m <- jsonlite::read_json(file.path(directory,"manifest.json"),simplifyVector=FALSE)
  files <- c("checkpoint.rds",unname(tabelas_previsao))
  exigir_analise(identical(as.integer(m$schema_version),1L)&&identical(m$kind,"forecast_checkpoint")&&
    setequal(names(m$files),files),"Manifesto de previsão incompatível")
  for(f in files)exigir_analise(identical(hash_arquivo_analise(file.path(directory,f)),m$files[[f]]),
    paste("SHA256 divergente no pacote de previsão:",f))
  cp <- readRDS(file.path(directory,"checkpoint.rds"))
  exigir_analise(identical(cp$id,m$id)&&identical(cp$sequence,as.integer(m$sequence))&&
    identical(cp$snapshot_id,m$snapshot_id),"Identidade do pacote de previsão divergente")
  out <- list(checkpoint=cp,directory=directory)
  if(tables)out$tables <- lapply(tabelas_previsao,function(f)data.table::fread(file.path(directory,f)))
  out
}

validar_checkpoint_previsao <- function(cp,state,verificar_previsoes=FALSE) {
  exigir_analise(identical(cp$schema_version,1L)&&identical(cp$kind,"forecast_checkpoint"),"Formato de checkpoint incompatível")
  exigir_analise(identical(cp$initial_state_id,state$id)&&identical(cp$identity,state$identity),
    "Checkpoint pertence a outro estado inicial ou eleição")
  exigir_analise(!nrow(cp$observed[!state$population,on=chaves_analise]),"Checkpoint contém BU fora da população")
  .analise_componentes$validar_observados_voto(cp$observed[,c(chaves_analise,contagens_analise),with=FALSE])
  exigir_analise(identical(cp$settings$componentes,cp$local$sha256),"Componentes locais do checkpoint inconsistentes")
  # Recompõe a posterior desde a prior ORIGINAL com as observações e os componentes salvos:
  # nenhuma informação pode estar contada duas vezes e Q não pode ter sido somada de novo.
  again <- estado_local_previsao(state,cp$observed[,c(chaves_analise,contagens_analise),with=FALSE],cp$local)
  tol <- function(a,b)max(abs(a-b))<=1e-9*max(1,abs(b))
  exigir_analise(again$posterior$n==cp$posterior$n&&tol(again$posterior$mean,cp$posterior$mean)&&
    tol(again$posterior$covariance,cp$posterior$covariance),"Posterior salva não corresponde às observações salvas")
  st <- cp$statistics
  exigir_analise(tol(st$A,again$A)&&tol(st$b,again$b)&&identical(st$voto$mun,again$voto$mun)&&
    tol(st$validos$mu,again$validos$mu)&&tol(st$validos$cov,again$validos$cov),"Estatísticas suficientes divergentes")
  # A posterior salva precisa decorrer das estatísticas salvas e da prior original.
  V <- chol2inv(chol(state$prior$precision+st$A))
  m <- state$prior$mean+as.numeric(V%*%(st$b-st$A%*%state$prior$mean))
  exigir_analise(tol(m,cp$posterior$mean)&&tol(V,cp$posterior$covariance)&&identical(st$posterior$mean,cp$posterior$mean),
    "Estatísticas e posterior do checkpoint inconsistentes")
  if(verificar_previsoes) {
    r <- resultados_previsao_analise(state,cp$observed,cp$official_details,
      cp$settings$sorteios,cp$settings$semente,cp$local)
    exigir_analise(identical(hash_objeto_analise(lapply(r[names(tabelas_previsao)],as.list)),cp$results_sha256)&&
      identical(hash_objeto_analise(lapply(r[names(cp$results)],as.list)),hash_objeto_analise(lapply(cp$results,as.list))),
      "Previsões regeneradas diferem das salvas")
  }
  invisible(TRUE)
}

ponteiro_previsao <- function(directory)file.path(directory,"latest.json")

carregar_checkpoint_previsao <- function(directory,state,verificar_previsoes=FALSE) {
  packages <- file.path(directory,"pacotes")
  candidates <- if(dir.exists(packages))sort(grep(padrao_pacote_previsao,basename(list.dirs(packages,recursive=FALSE)),value=TRUE),decreasing=TRUE) else character()
  pointer <- ponteiro_previsao(directory)
  if(!file.exists(pointer)&&!length(candidates))return(NULL)
  load <- function(name) {
    p <- ler_pacote_previsao(file.path(packages,name))
    validar_checkpoint_previsao(p$checkpoint,state,verificar_previsoes)
    p$checkpoint
  }
  first_error <- NULL
  cp <- tryCatch({
    m <- jsonlite::read_json(pointer,simplifyVector=TRUE)
    exigir_analise(grepl(padrao_pacote_previsao,m$package),"Ponteiro de previsão inválido")
    cp <- load(m$package)
    exigir_analise(identical(cp$id,m$id),"Ponteiro e pacote de previsão divergentes")
    cp
  },error=function(e){first_error <<- conditionMessage(e);NULL})
  if(!is.null(cp))return(cp)
  # Ponteiro ausente ou pacote danificado: usa o pacote íntegro mais recente.
  for(name in candidates) {
    cp <- tryCatch(load(name),error=function(e)NULL)
    if(!is.null(cp)) {
      attr(cp,"recuperacao") <- list(pacote=name,erro_ponteiro=first_error)
      return(cp)
    }
  }
  stop("Nenhum checkpoint de previsão íntegro: ",first_error,call.=FALSE)
}

historico_previsao <- function(directory,cp) {
  path <- file.path(directory,"historico.csv")
  published <- cp$snapshot_manifest$published_utc
  row <- cbind(data.table(sequencia=cp$sequence,checkpoint_id=cp$id,snapshot_id=cp$snapshot_id,
    snapshot_publicado_utc=if(is.null(published))NA_character_ else as.character(published),
    processado_utc=cp$created_utc,
    bus_novos=cp$changes$novos,bus_revisados=cp$changes$revisados,bus_removidos=cp$changes$removidos),
    cp$results$resumo)
  # Texto em ambos os lados: fread converteria horários ISO em POSIXct e a junção
  # com a linha nova apagaria esses horários.
  row <- row[,lapply(.SD,as.character)]
  old <- if(file.exists(path))data.table::fread(path,colClasses="character") else NULL
  # Após interrupção antes do ponteiro, a mesma sequência é reprocessada: substitui a linha.
  if(!is.null(old))old <- old[as.integer(sequencia)<cp$sequence]
  tmp <- tempfile(".historico-",tmpdir=directory)
  on.exit(unlink(tmp),add=TRUE)
  data.table::fwrite(data.table::rbindlist(list(old,row),fill=TRUE,use.names=TRUE),tmp)
  exigir_analise(file.rename(tmp,path),"Falha ao gravar histórico de previsões")
}

podar_pacotes_previsao <- function(directory,current,manter) {
  packages <- file.path(directory,"pacotes")
  names <- grep(padrao_pacote_previsao,basename(list.dirs(packages,recursive=FALSE)),value=TRUE)
  seq <- as.integer(substr(names,1,8))
  current_seq <- as.integer(substr(current,1,8))
  keep <- c(current,head(sort(names[seq<current_seq],decreasing=TRUE),manter-1L))
  # Somente pacotes derivados deste diretório; brutos do coletor e estado inicial ficam fora.
  for(name in setdiff(names,keep))unlink(file.path(packages,name),recursive=TRUE)
  # Temporários de uma gravação interrompida à força; o lock do executor exclui outro escritor.
  unlink(list.files(packages,pattern="^\\.previsao-",all.files=TRUE,full.names=TRUE),recursive=TRUE)
  invisible(keep)
}

publicar_previsao_analise <- function(cp,results,directory,manter=3L) {
  exigir_analise(length(manter)==1L&&is.finite(manter)&&manter>=2&&manter==floor(manter),
    "Retenção deve manter ao menos dois pacotes")
  dir.create(file.path(directory,"pacotes"),recursive=TRUE,showWarnings=FALSE)
  pointer <- ponteiro_previsao(directory)
  if(file.exists(pointer)) {
    old <- tryCatch(jsonlite::read_json(pointer,simplifyVector=TRUE),error=function(e)NULL)
    exigir_analise(is.null(old)||identical(old$initial_state_id,cp$initial_state_id),
      "Saída pertence a outro estado inicial; use outro diretório")
  }
  name <- sprintf("%08d_%s",cp$sequence,cp$id)
  gravar_pacote_previsao(cp,results,file.path(directory,"pacotes",name))
  historico_previsao(directory,cp)
  tmp <- tempfile(".latest-",tmpdir=directory)
  on.exit(unlink(tmp),add=TRUE)
  jsonlite::write_json(list(schema_version=1L,initial_state_id=cp$initial_state_id,sequence=cp$sequence,
    id=cp$id,snapshot_id=cp$snapshot_id,package=name),tmp,pretty=TRUE,auto_unbox=TRUE)
  # Ponto de confirmação: o ponteiro só muda depois de pacote e histórico gravados.
  exigir_analise(file.rename(tmp,pointer),"Falha ao publicar ponteiro de previsão")
  podar_pacotes_previsao(directory,name,manter)
  invisible(file.path(directory,"pacotes",name))
}

avancar_previsao_analise <- function(state,snapshot_dir,directory,checkpoint=NULL,
                                    sorteios=400L,semente=618360L,manter=3L,local=ler_componentes_locais()) {
  settings <- c(validar_sorteios_previsao(sorteios,semente),list(componentes=local$sha256))
  dados <- .analise_componentes$ler_dados_tse(snapshot_dir)
  tse <- validar_snapshot_analise(dados,state$identity)
  exigir_analise(identical(hash_inventario_analise(tse$inventory),state$inventory_sha256),
    "Inventário mudou; inicialize outro estado com a nova população antes de analisar")
  fingerprint <- hash_objeto_analise(tse$manifest)
  if(!is.null(checkpoint)) {
    exigir_analise(identical(checkpoint$initial_state_id,state$id),"Checkpoint pertence a outro estado inicial")
    if(identical(checkpoint$snapshot_id,tse$manifest$snapshot_id)) {
      exigir_analise(identical(checkpoint$snapshot_fingerprint,fingerprint),
        "Mesmo identificador de snapshot com conteúdo diferente")
      if(identical(checkpoint$settings,settings))
        return(list(checkpoint=checkpoint,processado=FALSE,motivo="snapshot_ja_processado"))
    }
  }
  observed <- versoes_bus_previsao(dados,tse$observed)
  statistical <- estado_local_previsao(state,tse$observed,local)
  results <- resultados_previsao_analise(state,tse$observed,dados$detalhes_fontes,
    settings$sorteios,settings$semente,local,statistical)
  sequence <- if(is.null(checkpoint))1L else checkpoint$sequence+1L
  code <- hashes_codigo_previsao()
  cp <- list(schema_version=1L,kind="forecast_checkpoint",sequence=sequence,created_utc=agora_analise(),
    initial_state_id=state$id,identity=state$identity,snapshot_id=tse$manifest$snapshot_id,
    snapshot_fingerprint=fingerprint,snapshot_manifest=tse$manifest,official_details=dados$detalhes_fontes,
    observed=observed,statistics=statistical,posterior=statistical$posterior,settings=settings,local=local,
    results=results[c("resumo","uf","coeficientes","aproximacoes","posterior","posterior_uf")],
    results_sha256=hash_objeto_analise(lapply(results[names(tabelas_previsao)],as.list)),
    changes=mudancas_bus_previsao(checkpoint$observed,observed),
    previous=if(is.null(checkpoint))NULL else list(id=checkpoint$id,sequence=checkpoint$sequence,
      snapshot_id=checkpoint$snapshot_id),
    code_sha256=code,
    scope=paste("posterior recomposed from the original prior and the complete active BU set; drift Q is only in the",
      "initial state; municipal vote shocks and T2/T1 valid-vote ratios learned from the same BU set"))
  cp$id <- hash_objeto_analise(list(state$id,fingerprint,settings,sequence,code))
  path <- publicar_previsao_analise(cp,results,directory,manter)
  list(checkpoint=cp,resultados=results,processado=TRUE,caminho=path)
}
