args_all <- commandArgs(FALSE)
root <- dirname(normalizePath(sub("^--file=","",args_all[grepl("^--file=",args_all)])[1]))
source(file.path(root,"previsao_execucao.R"),encoding="UTF-8")
out <- file.path(root,"output","previsao_execucao_20261020")
dir.create(out,recursive=TRUE,showWarnings=FALSE)
tmp <- tempfile("teste-previsao-");dir.create(tmp)
checks <- list()
check <- function(name,ok) {
  checks[[length(checks)+1L]] <<- data.table(verificacao=name,passou=isTRUE(ok))
  fwrite(rbindlist(checks),file.path(out,"checks.csv"))
  if(!isTRUE(ok))stop(name)
}
fails <- function(expr)inherits(tryCatch(force(expr),error=function(e)e),"error")
near <- function(a,b,tol=1e-8)max(abs(a-b))<=tol*max(1,abs(b))

# Fixture: 40 seções sintéticas em duas UFs, ajuste histórico e escala V2 reais.
# Quatro municípios: AC 1 e 3, AL 2 e 4; dez seções cada.
inventory <- rbind(data.table(uf="AC",cd_mun=rep(c(1L,3L),each=10),zona=rep(1:2,each=10),secao=1:20),
                   data.table(uf="AL",cd_mun=rep(c(2L,4L),each=10),zona=1L,secao=1:20))
t1 <- copy(inventory[!(uf=="AC"&secao==20L)])
t1[,`:=`(aptos=300L,comparecimento=240L,validos=225L)]
t1[,c13:=as.integer(round(225*seq(.2,.7,length.out=.N))),by=uf]
t1[,c22:=225L-c13-10L]
t1[uf=="AL"&secao==20L,`:=`(comparecimento=0L,validos=0L,c13=0L,c22=0L)]
t1path <- file.path(tmp,"t1.parquet");arrow::write_parquet(t1,t1path)
cfgpath <- file.path(tmp,"config.json");file.copy(file.path(root,"config.json"),cfgpath)
cfg <- jsonlite::read_json(cfgpath,simplifyVector=TRUE)
snap <- file.path(tmp,"tse");dir.create(snap)
empty <- inventory[0][,hash:=character()]
for(k in contagens_analise)empty[,(k):=numeric()]
bus <- function(rows,share,hash="h1") {
  o <- inventory[rows]
  o[,`:=`(aptos=300,comparecimento=230,validos=220,brancos=5,nulos=5,hash=hash)]
  o[,votos_a:=round(220*share)][,votos_b:=220-votos_a]
  o[]
}
area <- function(name,o,st=nrow(o),ts=NULL,extra_a=0,extra_b=0) {
  ts <- if(is.null(ts))nrow(inventory[uf==name|name%in%c("BR","SOMA_UFS")]) else ts
  list(area=name,st=st,ts=ts,votos_a=sum(o$votos_a)+extra_a,votos_b=sum(o$votos_b)+extra_b,
    validos=sum(o$validos)+extra_a+extra_b,generated="2026-10-25T18:00:00",current=TRUE)
}
oficial_br <- function(o,...)list(chosen=area("BR",o,...),national_lag_sections=0L,
  states=list(area("AC",o[uf=="AC"]),area("AL",o[uf=="AL"])))
write_snapshot <- function(observed=empty,id="prev-0",official=oficial_br(observed)) {
  files <- list()
  save <- function(name,object) {
    path <- file.path(snap,name)
    if(endsWith(name,".csv"))fwrite(object,path) else
      jsonlite::write_json(object,path,auto_unbox=TRUE,pretty=TRUE,digits=NA)
    files[[name]] <<- list(path=name,sha256=hash_arquivo_analise(path),kind=if(endsWith(name,".csv"))"csv" else "json")
  }
  save("inventory.csv",inventory);save("observed.csv",observed)
  chosen <- as.data.table(official$chosen)
  save("official_sources.csv",chosen);save("official_selected.csv",chosen)
  save("official_selected.json",official);save("status.json",list(fixture=TRUE))
  jsonlite::write_json(list(schema_version=1L,mode="observed_data_only",snapshot_id=id,
    published_utc="2026-10-25T21:00:00+00:00",identity=cfg[c("year","round","election","pleito")],
    candidate_columns=list(votos_a=13L,votos_b=22L),keys=chaves_analise,
    inventory_sections=nrow(inventory),observed_sections=nrow(observed),files=files),
    file.path(snap,"manifest.json"),auto_unbox=TRUE,pretty=TRUE)
}
write_snapshot()
fitpath <- file.path(root,"data","processed","voto_t1_fits.rds")
fit_hash <- hash_arquivo_analise(fitpath)
initial <- file.path(tmp,"initial")
state <- inicializar_analise(initial,fitpath,t1path,cfgpath,snap)
initial_hash <- hash_arquivo_analise(file.path(initial,"estado.rds"))
prior <- state$prior
dados <- .analise_componentes$ler_dados_tse(snap)
tse <- validar_snapshot_analise(dados,state$identity)

# ---------- Item 3: previsões (com correções 2 e 3) ----------
local <- ler_componentes_locais();zero <- componentes_locais_zero()
pop <- state$population;s2w <- prior$sigma^2-local$tau2
v_total0 <- local$s0^2+local$sg^2+local$var_m+local$var_i
r0 <- resultados_previsao_analise(state,tse$observed,dados$detalhes_fontes,sorteios=400L,local=local)
post0 <- r0$estado$posterior
check("Zero BUs: previsão existe e usa a prior com Q",post0$n==0L&&near(post0$covariance,prior$covariance)&&
  near(post0$mean,prior$mean)&&is.finite(r0$resumo$pct_a_projetado)&&r0$resumo$pct_a_q025<r0$resumo$pct_a_projetado&&
  r0$resumo$pct_a_projetado<r0$resumo$pct_a_q975)
check("Zero BUs: válidos esperados são T1 vezes a razão lognormal da prior e variam nos sorteios",
  near(r0$resumo$validos_pendentes_projetados,sum(pop$validos_base)*exp(v_total0/2))&&
  sd(r0$posterior$votos_a+r0$posterior$votos_b)>0)
check("Zero BUs: coeficientes atuais coincidem com os iniciais",
  near(r0$resumo$pct_a_projetado,r0$resumo$pct_a_coef_iniciais)&&near(r0$coeficientes$media_atual,r0$coeficientes$media_inicial))
check("Saída tem 40 seções, duas UFs, quatro municípios e 59 coeficientes",nrow(r0$secoes)==40L&&nrow(r0$uf)==2L&&
  r0$resumo$municipios==4L&&nrow(r0$coeficientes)==59L)
check("Rótulos de aproximação da população são preservados por seção",
  identical(r0$secoes[order(uf,cd_mun,zona,secao),fallback],pop[order(uf,cd_mun,zona,secao),fallback])&&
  all(c("sem_secao_t1_medias_zona","denominador_t1_zero_medias_zona")%in%r0$aproximacoes$fallback)&&
  r0$resumo$fallback_t1==2L&&sum(r0$uf$secoes_aproximadas)==2L)
check("Correção 3: inversa do logit suavizado recupera os votos",
  all(abs(votos_da_proporcao((0:225+.5)/226,225)-0:225)<1e-9)&&votos_da_proporcao(.001,5)==0&&votos_da_proporcao(.999,5)==5)
# Fórmula independente com matriz densa de 59 colunas.
X <- .analise_componentes$X_comparecimento(pop,prior$spec)
Z <- matrix(0,nrow(X),length(prior$mean))
for(i in seq_len(nrow(X)))Z[i,prior$map[[match(pop$uf[i],prior$levels)]]] <- X[i,]
mu <- as.numeric(Z%*%prior$mean);sdv <- sqrt(rowSums((Z%*%prior$covariance)*Z)+prior$sigma^2)
ew0 <- pop$validos_base*exp(v_total0/2)
check("Zero BUs: preditiva por seção coincide com a matriz densa e com a inversa do logit",
  near(r0$secoes$logit_media_modelo,mu)&&near(r0$secoes$logit_dp_preditivo,sdv)&&
  near(r0$secoes$pct_a_modelo,100*votos_da_proporcao(.analise_componentes$logistic_normal_mean(mu,sdv),ew0)/ew0)&&
  near(r0$secoes$validos_projetados,ew0))
big <- resultados_previsao_analise(state,tse$observed,NULL,sorteios=4000L,local=local)
se_a <- sd(big$posterior$votos_a)/sqrt(4000);se_v <- sd(big$posterior$votos_a+big$posterior$votos_b)/sqrt(4000)
check("Médias dos sorteios coincidem com votos e válidos esperados",
  abs(mean(big$posterior$votos_a)-big$resumo$votos_a_projetados)<4*se_a+1e-4*big$resumo$votos_a_projetados&&
  abs(mean(big$posterior$votos_a+big$posterior$votos_b)-big$resumo$validos_pendentes_projetados)<4*se_v)
again <- resultados_previsao_analise(state,tse$observed,dados$detalhes_fontes,sorteios=400L,local=local)
other_seed <- resultados_previsao_analise(state,tse$observed,dados$detalhes_fontes,sorteios=400L,semente=1L,local=local)
check("Mesma entrada e semente reproduzem todas as saídas",identical(hash_objeto_analise(lapply(r0[1:7],as.list)),
  hash_objeto_analise(lapply(again[1:7],as.list))))
check("Semente muda apenas os sorteios, não as médias",!identical(r0$posterior$votos_a,other_seed$posterior$votos_a)&&
  identical(hash_objeto_analise(as.list(r0$secoes)),hash_objeto_analise(as.list(other_seed$secoes)))&&near(r0$resumo$votos_a_projetados,other_seed$resumo$votos_a_projetados))

o1 <- bus(c(1:8,21:26),.9)
o1[c(2,9),`:=`(validos=210,votos_a=round(210*.9))][,votos_b:=validos-votos_a][,comparecimento:=validos+brancos+nulos]
est1 <- estado_local_previsao(state,o1,local)
r1 <- resultados_previsao_analise(state,o1,NULL,local=local,est=est1)
post1 <- est1$posterior
plain <- .analise_componentes$snapshot_online(prior,pop,o1)
ez <- estado_local_previsao(state,o1,zero)
check("Sem componentes locais, a posterior é a do atualizador original",
  near(ez$posterior$mean,plain$mean,1e-10)&&near(ez$posterior$covariance,plain$covariance,1e-10))
rz0 <- resultados_previsao_analise(state,o1,NULL,local=zero,est=ez)
check("Sem componentes locais, válidos T1 são o peso fixo das pendentes",
  near(rz0$resumo$validos_pendentes_projetados,sum(pop$validos_base)-sum(pop[o1,on=chaves_analise]$validos_base))&&
  sd(rz0$posterior$votos_a+rz0$posterior$votos_b)<1e-8)
# Força bruta: verossimilhança com bloco municipal denso.
row <- pop[o1,on=chaves_analise,which=TRUE];mun <- municipios_populacao(pop)
y <- .analise_componentes$safe_logit(o1$votos_a,o1$validos);Zo <- Z[row,,drop=FALSE]
Sigma <- diag(s2w,nrow(o1))+local$tau2*outer(mun[row],mun[row],"==")
P0 <- solve(prior$covariance);Si <- solve(Sigma)
Vb <- solve(P0+t(Zo)%*%Si%*%Zo);mb <- as.numeric(Vb%*%(P0%*%prior$mean+t(Zo)%*%Si%*%y))
check("Correção 2: posterior com efeito municipal coincide com mínimos quadrados generalizados densos",
  near(post1$mean,mb,1e-8)&&near(post1$covariance,Vb,1e-8))
# Força bruta conjunta de coeficientes e choques municipais.
M <- max(mun);H <- outer(mun[row],seq_len(M),"==")*1
Pj <- rbind(cbind(P0+t(Zo)%*%Zo/s2w,t(Zo)%*%H/s2w),cbind(t(H)%*%Zo/s2w,diag(1/local$tau2,M)+t(H)%*%H/s2w))
Vj <- solve(Pj);mj <- as.numeric(Vj%*%c(P0%*%prior$mean+t(Zo)%*%y/s2w,t(H)%*%y/s2w))
pend <- which(!r1$secoes$apurada)
L <- cbind(Z[pend,,drop=FALSE],outer(mun[pend],seq_len(M),"==")*1)
check("Correção 2: preditiva das pendentes coincide com a posterior conjunta de coeficientes e choques",
  near(r1$secoes$logit_media_modelo[pend],as.numeric(L%*%mj),1e-8)&&
  near(r1$secoes$logit_dp_preditivo[pend],sqrt(rowSums((L%*%Vj)*L)+s2w),1e-8))
# Força bruta da razão de válidos: lambda (2 UFs) e nu (4 municípios), sem seções aproximadas.
ok <- which(pop$fallback[row]=="nenhum");l <- log(o1$validos[ok]/pop$validos_base[row[ok]])
G <- length(prior$levels);g_obs <- match(pop$uf[row[ok]],prior$levels)
Hl <- cbind(outer(g_obs,seq_len(G),"==")*1,outer(mun[row[ok]],seq_len(M),"==")*1)
Pl0 <- solve(rbind(cbind(matrix(local$s0^2,G,G)+diag(local$sg^2,G),matrix(0,G,M)),cbind(matrix(0,M,G),diag(local$var_m,M))))
Vl <- solve(Pl0+t(Hl)%*%Hl/local$var_i);ml <- as.numeric(Vl%*%(t(Hl)%*%l/local$var_i))
Ll <- cbind(outer(match(pop$uf[pend],prior$levels),seq_len(G),"==")*1,outer(mun[pend],seq_len(M),"==")*1)
ratio_bf <- exp(as.numeric(Ll%*%ml)+(rowSums((Ll%*%Vl)*Ll)+local$var_i)/2)
check("Correção 2: razão de válidos das pendentes coincide com a posterior hierárquica densa",
  near(r1$secoes$razao_validos_t2_t1[pend],ratio_bf,1e-8)&&near(r1$secoes$validos_projetados[pend],pop$validos_base[pend]*ratio_bf,1e-8))
s1 <- r1$secoes[o1,on=chaves_analise]
check("BU substitui previsão e peso da seção",all(s1$apurada)&&near(s1$votos_a_projetados,o1$votos_a)&&
  near(s1$validos_projetados,o1$validos)&&near(s1$pct_a_q025,s1$pct_a_q975))
check("Total combina votos observados e pendentes sem duplicar",near(r1$resumo$votos_a_projetados,
  sum(o1$votos_a)+sum(r1$secoes[apurada==FALSE,votos_a_projetados]))&&
  near(r1$resumo$votos_a_observados,sum(o1$votos_a))&&r1$resumo$secoes_regressao==nrow(o1))
check("Coeficientes e choques atualizados mudam as pendentes na direção dos BUs",
  r1$resumo$pct_a_projetado>r1$resumo$pct_a_coef_iniciais&&
  all(r1$secoes[apurada==FALSE,pct_a_modelo]>r0$secoes[r1$secoes$apurada==FALSE,pct_a_modelo]))
check("Pendentes de município com BUs aprendem mais que as de município sem BUs",
  mean(r1$secoes[apurada==FALSE&cd_mun%in%c(1L,2L),logit_media_modelo]-r0$secoes[r1$secoes$apurada==FALSE&r1$secoes$cd_mun%in%c(1L,2L),logit_media_modelo])>
  mean(r1$secoes[apurada==FALSE&cd_mun%in%c(3L,4L),logit_media_modelo]-r0$secoes[r1$secoes$apurada==FALSE&r1$secoes$cd_mun%in%c(3L,4L),logit_media_modelo]))
check("Atualização reduz a incerteza das seções pendentes",
  all(r1$secoes[apurada==FALSE,logit_dp_preditivo]<r0$secoes[r1$secoes$apurada==FALSE,logit_dp_preditivo]))
check("UFs somam o total em votos projetados",near(sum(r1$uf$votos_a_projetados),r1$resumo$votos_a_projetados)&&
  all(r1$uf$pct_a_q025<=r1$uf$pct_a_projetado&r1$uf$pct_a_projetado<=r1$uf$pct_a_q975))
zero_valid <- copy(o1);zero_valid[1,`:=`(validos=0,votos_a=0,votos_b=0,brancos=115,nulos=115)]
zero_valid[,comparecimento:=validos+brancos+nulos]
rz <- resultados_previsao_analise(state,zero_valid,NULL,local=local)
check("BU com zero válidos entra como apurado sem votos e fora da regressão e da razão",
  rz$resumo$secoes_zero_validos==1L&&rz$resumo$secoes_regressao==nrow(o1)-1L&&
  rz$secoes[zero_valid[1],on=chaves_analise]$votos_a_projetados==0&&sum(rz$estado$validos$n)==nrow(o1)-1L)

all_bus <- bus(seq_len(nrow(inventory)),.55)
all_bus[uf=="AL",votos_a:=60][,votos_b:=validos-votos_a]
rc <- resultados_previsao_analise(state,all_bus,oficial_br(all_bus),local=local)
check("Apuração completa reproduz o resultado e colapsa a incerteza",
  near(rc$resumo$pct_a_projetado,100*sum(all_bus$votos_a)/sum(all_bus$validos))&&
  near(rc$resumo$pct_a_q025,rc$resumo$pct_a_q975)&&near(rc$resumo$pct_a_projetado,rc$resumo$pct_a_coef_iniciais)&&
  all(near(rc$uf$pct_a_q025,rc$uf$pct_a_q975)))
check("Apuração completa preserva aproximações apenas como rótulo",rc$resumo$fallback_t1_apuradas==2L&&
  all(rc$secoes$apurada))

# Âncora: BR à frente do coletor. Seções oficiais ainda não baixadas recebem a mesma composição.
br <- oficial_br(o1,st=nrow(o1)+6,extra_a=500,extra_b=340)
br_only <- list(chosen=br$chosen,national_lag_sections=0L)
rb <- resultados_previsao_analise(state,o1,br_only,local=local,est=est1)
bu_only <- resultados_previsao_analise(state,o1,NULL,local=local,est=est1)$resumo
f <- (40-(nrow(o1)+6))/(40-nrow(o1))
expected_a <- br$chosen$votos_a+(bu_only$votos_a_projetados-bu_only$votos_a_observados)*f
expected_b <- br$chosen$votos_b+(bu_only$votos_b_projetados-bu_only$votos_b_observados)*f
check("Âncora BR usa o total oficial e escala os pendentes",isTRUE(rb$resumo$ancora_oficial)&&
  rb$resumo$fonte_oficial=="BR"&&near(rb$resumo$pct_a_projetado,100*expected_a/(expected_a+expected_b))&&
  near(rb$resumo$pct_a_somente_bu,bu_only$pct_a_projetado))
check("Sem totais estaduais completos, a âncora é BR e as UFs não são ancoradas",!any(rb$uf$ancora_oficial)&&
  all(is.na(rb$uf$fonte_oficial)))
rbs <- resultados_previsao_analise(state,o1,br,local=local,est=est1)
check("Item 1: com os totais estaduais completos e compatíveis, a soma estadual ancora mesmo com BR à frente",
  isTRUE(rbs$resumo$ancora_oficial)&&rbs$resumo$fonte_oficial=="SOMA_UFS"&&rbs$resumo$fonte_escolhida_coletor=="BR"&&
  all(rbs$uf$ancora_oficial)&&near(sum(rbs$uf$votos_a_projetados),rbs$resumo$votos_a_projetados))
br_bad_states <- br;br_bad_states$states[[1]]$votos_a <- 1
rbb <- resultados_previsao_analise(state,o1,br_bad_states,local=local,est=est1)
check("Item 1: soma estadual incompatível com os BUs recorre ao BR",isTRUE(rbb$resumo$ancora_oficial)&&
  rbb$resumo$fonte_oficial=="BR"&&near(rbb$resumo$pct_a_projetado,rb$resumo$pct_a_projetado))
states <- list(chosen=c(area("SOMA_UFS",o1,st=nrow(o1)+6,extra_a=500,extra_b=340),list(oldest_generated="2026-10-25T17:50:00")),
  national=area("BR",o1[0],st=0L),national_lag_sections=nrow(o1)+6L,
  states=list(area("AC",o1[uf=="AC"],st=nrow(o1[uf=="AC"])+3,extra_a=250,extra_b=170),
              area("AL",o1[uf=="AL"],st=nrow(o1[uf=="AL"])+3,extra_a=250,extra_b=170)))
rs <- resultados_previsao_analise(state,o1,states,local=local,est=est1)
check("BR parado e UFs avançando: soma estadual ancora total e UFs",isTRUE(rs$resumo$ancora_oficial)&&
  rs$resumo$fonte_oficial=="SOMA_UFS"&&all(rs$uf$ancora_oficial)&&
  near(sum(rs$uf$votos_a_projetados),rs$resumo$votos_a_projetados)&&
  near(sum(rs$uf$votos_b_projetados),rs$resumo$votos_b_projetados))
check("UF ancorada mantém intervalo e valor só dos BUs",all(rs$uf$pct_a_q025<=rs$uf$pct_a_projetado&
  rs$uf$pct_a_projetado<=rs$uf$pct_a_q975)&&near(rs$uf$pct_a_somente_bu,r1$uf$pct_a_projetado))
complete_states <- list(chosen=area("SOMA_UFS",all_bus),national_lag_sections=40L,
  states=list(area("AC",all_bus[uf=="AC"]),area("AL",all_bus[uf=="AL"])))
rcs <- resultados_previsao_analise(state,o1,complete_states,local=local,est=est1)
check("Total oficial completo prevalece sem somar BUs novamente",isTRUE(rcs$resumo$ancora_oficial)&&
  near(rcs$resumo$pct_a_projetado,100*sum(all_bus$votos_a)/sum(all_bus$validos))&&
  near(rcs$resumo$pct_a_q025,rcs$resumo$pct_a_q975))
bad_official <- list(chosen=oficial_br(o1)$chosen);bad_official$chosen$votos_a <- 1
check("Total oficial incompatível com BUs não é ancorado",
  !isTRUE(resultados_previsao_analise(state,o1,bad_official,local=local,est=est1)$resumo$ancora_oficial))
# Atualização gradual: com cerca de 5% dos válidos T1 apurados, peso (0,05/0,15)^2.
o_small <- bus(c(1,21),.9)
r_small <- resultados_previsao_analise(state,o_small,NULL,sorteios=400L,local=local)
frac_small <- sum(pop[o_small,on=chaves_analise]$validos_base)/sum(pop$validos_base)
w_small <- min(1,frac_small/local$fracao_plena)^local$expoente
r_full <- resultados_previsao_analise(state,o_small,NULL,sorteios=400L,local=modifyList(local,list(fracao_plena=0)))
check("Atualização gradual: peso e número de sorteios atualizados seguem a fração apurada",
  near(r_small$resumo$fracao_validos_t1_apurada,frac_small)&&near(r_small$resumo$peso_atualizacao,w_small)&&
  w_small>0&&w_small<1&&r_small$resumo$sorteios_atualizados==round(w_small*400)&&r_full$resumo$peso_atualizacao==1)
check("Atualização gradual: votos esperados são a mistura do modelo inicial e do atualizado",
  near(r_small$resumo$votos_a_projetados,(1-w_small)*r_small$resumo$votos_a_coef_iniciais+w_small*r_full$resumo$votos_a_projetados))
check("Atualização gradual: a projeção muda menos que a atualização plena",
  abs(r_small$resumo$pct_a_projetado-r0$resumo$pct_a_projetado)<abs(r_full$resumo$pct_a_projetado-r0$resumo$pct_a_projetado))
pend_s <- which(!r_small$secoes$apurada)[1:5]
cdf_mix <- function(sh,k) {
  p0 <- r0$secoes;mu0 <- p0$logit_media_modelo[k];sd0 <- p0$logit_dp_preditivo[k];w0 <- p0$validos_projetados[k]
  mu1 <- r_full$secoes$logit_media_modelo[k];sd1 <- r_full$secoes$logit_dp_preditivo[k];w1 <- r_full$secoes$validos_projetados[k]
  (1-w_small)*pnorm((qlogis((sh*w0+.5)/(w0+1))-mu0)/sd0)+w_small*pnorm((qlogis((sh*w1+.5)/(w1+1))-mu1)/sd1)
}
check("Atualização gradual: quantis por seção são os da mistura dos dois componentes",
  max(abs(cdf_mix(r_small$secoes$pct_a_q025[pend_s]/100,pend_s)-.025))<1e-6&&
  max(abs(cdf_mix(r_small$secoes$pct_a_q975[pend_s]/100,pend_s)-.975))<1e-6)
big_small <- resultados_previsao_analise(state,o_small,NULL,sorteios=4000L,local=local)
check("Atualização gradual: média dos sorteios da mistura coincide com o ponto",
  abs(mean(big_small$posterior$votos_a)-big_small$resumo$votos_a_projetados)<4*sd(big_small$posterior$votos_a)/sqrt(4000)+
    1e-4*big_small$resumo$votos_a_projetados)
# Dois cenários: "2022" não aprende nada com os BUs; "com aprendizado" é o modelo acima.
check("Dois cenários: sem BUs, o cenário 2022 coincide com o cenário com aprendizado",
  near(r0$resumo$pct_a_2022,r0$resumo$pct_a_projetado)&&near(r0$resumo$pct_a_2022_q025,r0$resumo$pct_a_q025)&&
  near(r0$resumo$pct_a_2022_q975,r0$resumo$pct_a_q975)&&identical(r0$posterior_2022,r0$posterior)&&
  near(r0$secoes$pct_a_2022,r0$secoes$pct_a_projetado)&&near(r0$uf$pct_a_2022,r0$uf$pct_a_projetado))
pend1 <- which(!r1$secoes$apurada);obs1 <- which(r1$secoes$apurada)
check("Dois cenários: no cenário 2022, as pendentes têm a previsão sem BUs e as apuradas, o voto do BU",
  near(r1$resumo$pct_a_2022,r1$resumo$pct_a_coef_iniciais)&&near(r1$secoes$pct_a_2022[pend1],r0$secoes$pct_a_modelo[pend1])&&
  near(r1$secoes$pct_a_2022_q025[pend1],r0$secoes$pct_a_q025[pend1])&&near(r1$secoes$pct_a_2022_q975[pend1],r0$secoes$pct_a_q975[pend1])&&
  near(r1$secoes$pct_a_2022[obs1],100*r1$secoes$votos_a_observados[obs1]/r1$secoes$validos_observados[obs1]))
o1b <- copy(o1)[,votos_a:=round(validos*.3)][,votos_b:=validos-votos_a]
r1b <- resultados_previsao_analise(state,o1b,NULL,local=local)
check("Dois cenários: mudar o voto dos BUs apurados não muda as pendentes do cenário 2022 e muda as do outro",
  near(r1$resumo$votos_a_projetados_2022-sum(o1$votos_a),r1b$resumo$votos_a_projetados_2022-sum(o1b$votos_a))&&
  near(r1$posterior_2022$votos_a-sum(o1$votos_a),r1b$posterior_2022$votos_a-sum(o1b$votos_a))&&
  abs((r1$resumo$votos_a_projetados-sum(o1$votos_a))-(r1b$resumo$votos_a_projetados-sum(o1b$votos_a)))>1)
check("Dois cenários: intervalos do cenário 2022 contêm o ponto e as UFs somam o total",
  r1$resumo$pct_a_2022_q025<r1$resumo$pct_a_2022&&r1$resumo$pct_a_2022<r1$resumo$pct_a_2022_q975&&
  all(r1$uf$pct_a_2022_q025<=r1$uf$pct_a_2022&r1$uf$pct_a_2022<=r1$uf$pct_a_2022_q975)&&
  near(sum(r1$uf$votos_a_projetados_2022),r1$resumo$votos_a_projetados_2022)&&
  near(sum(r1$uf$votos_b_projetados_2022),r1$resumo$votos_b_projetados_2022))
big1 <- resultados_previsao_analise(state,o1,NULL,sorteios=4000L,local=local,est=est1)
check("Dois cenários: média dos sorteios do cenário 2022 coincide com o ponto",
  abs(mean(big1$posterior_2022$votos_a)-big1$resumo$votos_a_projetados_2022)<4*sd(big1$posterior_2022$votos_a)/sqrt(4000)+
    1e-4*big1$resumo$votos_a_projetados_2022)
check("Dois cenários: com a apuração completa, os dois reproduzem o resultado",
  near(rc$resumo$pct_a_2022,rc$resumo$pct_a_projetado)&&near(rc$resumo$pct_a_2022_q025,rc$resumo$pct_a_2022_q975)&&
  all(near(rc$uf$pct_a_2022,rc$uf$pct_a_projetado)))
expected_a22 <- br$chosen$votos_a+(bu_only$votos_a_projetados_2022-bu_only$votos_a_observados)*f
expected_b22 <- br$chosen$votos_b+(bu_only$votos_b_projetados_2022-bu_only$votos_b_observados)*f
check("Dois cenários: âncora BR escala as pendentes do cenário 2022 pela mesma regra",
  near(rb$resumo$pct_a_2022,100*expected_a22/(expected_a22+expected_b22))&&
  rb$resumo$pct_a_2022_q025<=rb$resumo$pct_a_2022&&rb$resumo$pct_a_2022<=rb$resumo$pct_a_2022_q975)
check("Dois cenários: soma estadual ancora o cenário 2022 no total e nas UFs",
  near(sum(rs$uf$votos_a_projetados_2022),rs$resumo$votos_a_projetados_2022)&&
  near(sum(rs$uf$votos_b_projetados_2022),rs$resumo$votos_b_projetados_2022)&&
  all(rs$uf$pct_a_2022_q025<=rs$uf$pct_a_2022&rs$uf$pct_a_2022<=rs$uf$pct_a_2022_q975)&&
  near(rcs$resumo$pct_a_2022,100*sum(all_bus$votos_a)/sum(all_bus$validos))&&near(rcs$resumo$pct_a_2022_q025,rcs$resumo$pct_a_2022_q975))
bad_est <- est1;bad_est$posterior$mean <- bad_est$posterior$mean[-1]
check("Posterior de outro tamanho é rejeitada",fails(resultados_previsao_analise(state,o1,NULL,local=local,est=bad_est)))
check("BU fora da população é rejeitado",fails(resultados_previsao_analise(state,
  rbind(o1,bus(1,.5)[,secao:=99L]),NULL,local=local)))
check("Número de sorteios inválido é rejeitado",fails(resultados_previsao_analise(state,o1,NULL,sorteios=1L,local=local)))
check("Variância municipal maior que a residual é rejeitada",fails(estado_local_previsao(state,o1,
  modifyList(local,list(tau2=prior$sigma^2)))))

# ---------- Item 4: checkpoint e retomada ----------
outA <- file.path(tmp,"continuo");outB <- file.path(tmp,"retomado")
step0 <- avancar_previsao_analise(state,snap,outA)
check("Primeiro snapshot cria pacote, histórico e ponteiro",step0$processado&&step0$checkpoint$sequence==1L&&
  file.exists(file.path(outA,"latest.json"))&&nrow(fread(file.path(outA,"historico.csv")))==1L)
loaded0 <- carregar_checkpoint_previsao(outA,state)
check("Checkpoint recarregado coincide com o publicado",identical(loaded0$id,step0$checkpoint$id)&&
  near(loaded0$posterior$covariance,prior$covariance))
same <- avancar_previsao_analise(state,snap,outA,loaded0)
check("Mesmo snapshot não é reprocessado nem duplica histórico",!same$processado&&same$checkpoint$sequence==1L&&
  length(list.dirs(file.path(outA,"pacotes"),recursive=FALSE))==1L&&nrow(fread(file.path(outA,"historico.csv")))==1L)
snapshots <- list(list(o=bus(c(1:5,21:24),.8,"h1"),id="prev-1"))
o2 <- rbind(snapshots[[1]]$o,bus(c(6:8,25:26),.8,"h1"))
o2[1,`:=`(votos_a=200,votos_b=20,hash="h2")]
snapshots[[2]] <- list(o=o2,id="prev-2")
snapshots[[3]] <- list(o=o2[-2],id="prev-3")
run_snapshot <- function(i,directory,cp) {
  write_snapshot(snapshots[[i]]$o,snapshots[[i]]$id,oficial_br(snapshots[[i]]$o))
  avancar_previsao_analise(state,snap,directory,cp)$checkpoint
}
cpA <- step0$checkpoint
for(i in 1:3)cpA <- run_snapshot(i,outA,cpA)
check("Contagem de BUs novos, revisados e removidos entre checkpoints",
  identical(unlist(cpA$changes),c(novos=0L,revisados=0L,removidos=1L,inalterados=13L))&&
  identical(carregar_checkpoint_previsao(outA,state)$sequence,4L))
check("Posterior do checkpoint é recomposta desde a prior original",
  near(cpA$posterior$mean,estado_local_previsao(state,snapshots[[3]]$o,local)$posterior$mean)&&
  cpA$posterior$n==nrow(snapshots[[3]]$o))
cpB <- NULL
write_snapshot(); cpB <- avancar_previsao_analise(state,snap,outB,cpB)$checkpoint
for(i in 1:2)cpB <- run_snapshot(i,outB,cpB)
corrected <- carregar_checkpoint_previsao(outB,state)
check("BU corrigido entra como revisão sem aumentar N",corrected$changes$revisados==1L&&
  corrected$changes$novos==5L&&corrected$posterior$n==nrow(o2))
# Interrupção: descarta objetos em memória e recarrega estado inicial e checkpoint do disco.
rm(cpB)
state_reloaded <- carregar_ponto_partida_analise(initial)
write_snapshot(snapshots[[3]]$o,"prev-3",oficial_br(snapshots[[3]]$o))
resumed_cp <- carregar_checkpoint_previsao(outB,state_reloaded,verificar_previsoes=TRUE)
check("Checkpoint recupera exatamente o snapshot anterior já substituído no coletor",
  identical(resumed_cp$snapshot_id,"prev-2")&&identical(resumed_cp$results_sha256,corrected$results_sha256))
resumed <- avancar_previsao_analise(state_reloaded,snap,outB,resumed_cp)$checkpoint
check("Retomada coincide com execução contínua",identical(resumed$id,cpA$id)&&
  identical(resumed$results_sha256,cpA$results_sha256)&&near(resumed$posterior$covariance,cpA$posterior$covariance))
tables <- ler_pacote_previsao(file.path(outB,"pacotes",jsonlite::read_json(file.path(outB,"latest.json"))$package),tables=TRUE)$tables
check("CSVs publicados coincidem com o checkpoint",near(tables$resumo$pct_a_projetado,resumed$results$resumo$pct_a_projetado)&&
  nrow(tables$secoes)==40L&&nrow(tables$posterior)==400L&&nrow(tables$coeficientes)==59L)
write_snapshot(empty,"prev-vazio")
dir.create(file.path(outB,"pacotes",".previsao-interrompida"))
emptied <-avancar_previsao_analise(state_reloaded,snap,outB,resumed)$checkpoint
check("Remover todos os BUs volta à prior sem somar Q de novo",emptied$posterior$n==0L&&
  near(emptied$posterior$covariance,prior$covariance,1e-12)&&near(emptied$posterior$mean,prior$mean,1e-12)&&
  near(emptied$posterior$covariance,prior$historical_covariance+prior$drift_covariance,1e-12))
check("Retenção mantém somente os pacotes recentes e remove temporários interrompidos",
  length(list.dirs(file.path(outB,"pacotes"),recursive=FALSE))==3L&&
  nrow(fread(file.path(outB,"historico.csv")))==5L)
# Falha entre histórico e ponteiro: o mesmo snapshot gera o mesmo pacote e substitui a linha.
pointer_before <- readLines(file.path(outB,"latest.json"))
write_snapshot(snapshots[[1]]$o,"prev-crash",oficial_br(snapshots[[1]]$o))
crash <- avancar_previsao_analise(state_reloaded,snap,outB,emptied)$checkpoint
writeLines(pointer_before,file.path(outB,"latest.json"))
back <- carregar_checkpoint_previsao(outB,state_reloaded)
redo <- avancar_previsao_analise(state_reloaded,snap,outB,back)$checkpoint
h <- fread(file.path(outB,"historico.csv"))
check("Interrupção antes do ponteiro não duplica pacote nem histórico",identical(redo$id,crash$id)&&
  !anyDuplicated(h$sequencia)&&nrow(h)==6L&&identical(carregar_checkpoint_previsao(outB,state_reloaded)$id,crash$id))
h <- fread(file.path(outB,"historico.csv"),colClasses="character")
check("Histórico preserva horários, snapshots e valores após várias gravações",
  identical(h$sequencia,as.character(1:6))&&!anyNA(h$processado_utc)&&all(grepl("Z$",h$processado_utc))&&
  identical(h$snapshot_publicado_utc,rep("2026-10-25T21:00:00+00:00",6))&&
  identical(h$snapshot_id,c("prev-0","prev-1","prev-2","prev-3","prev-vazio","prev-crash"))&&
  near(as.numeric(h$pct_a_projetado[6]),crash$results$resumo$pct_a_projetado,1e-12))
latest_dir <- file.path(outB,"pacotes",jsonlite::read_json(file.path(outB,"latest.json"))$package)
raw <- readBin(file.path(latest_dir,"checkpoint.rds"),"raw",n=file.info(file.path(latest_dir,"checkpoint.rds"))$size)
writeBin(c(raw,as.raw(0)),file.path(latest_dir,"checkpoint.rds"))
fallback <- carregar_checkpoint_previsao(outB,state_reloaded)
check("Checkpoint corrompido recorre ao pacote íntegro anterior",identical(fallback$sequence,redo$sequence-1L)&&
  !is.null(attr(fallback,"recuperacao")))
writeLines("{corrompido",file.path(outB,"latest.json"))
check("Ponteiro corrompido também recorre ao pacote íntegro mais recente",
  identical(carregar_checkpoint_previsao(outB,state_reloaded)$sequence,redo$sequence-1L))
# Pacotes adulterados com manifesto recalculado: só a recomposição desde a prior os detecta.
tamper <- function(change) {
  directory <- file.path(tmp,paste0("adulterado_",length(checks)))
  dir.create(file.path(directory,"pacotes"),recursive=TRUE)
  name <- jsonlite::read_json(file.path(outA,"latest.json"))$package
  file.copy(file.path(outA,"pacotes",name),file.path(directory,"pacotes"),recursive=TRUE)
  file.copy(file.path(outA,"latest.json"),directory)
  path <- file.path(directory,"pacotes",name)
  cp <- change(readRDS(file.path(path,"checkpoint.rds")))
  saveRDS(cp,file.path(path,"checkpoint.rds"))
  m <- jsonlite::read_json(file.path(path,"manifest.json"),simplifyVector=FALSE)
  m$files$checkpoint.rds <- hash_arquivo_analise(file.path(path,"checkpoint.rds"))
  jsonlite::write_json(m,file.path(path,"manifest.json"),pretty=TRUE,auto_unbox=TRUE)
  directory
}
posterior_de <- function(p,st) {
  V <- chol2inv(chol(p$precision+st$A))
  list(mean=setNames(p$mean+as.numeric(V%*%(st$b-st$A%*%p$mean)),p$names),covariance=V,n=st$posterior$n,sigma=p$sigma)
}
doubled <- tamper(function(cp) {
  st <- cp$statistics;st$A <- 2*st$A;st$b <- 2*st$b
  st$posterior <- posterior_de(prior,st);cp$statistics <- st;cp$posterior <- st$posterior
  cp})
check("Checkpoint com BUs contados duas vezes é recusado",fails(carregar_checkpoint_previsao(doubled,state)))
reinflated <- tamper(function(cp) {
  p2 <- prior;p2$covariance <- prior$covariance+prior$drift_covariance
  p2$precision <- chol2inv(chol(p2$covariance))
  cp$statistics$posterior <- posterior_de(p2,cp$statistics);cp$posterior <- cp$statistics$posterior
  cp})
check("Checkpoint com Q somada novamente é recusado",fails(carregar_checkpoint_previsao(reinflated,state)))
altered <- tamper(function(cp){cp$results$resumo$pct_a_projetado <- 99;cp})
check("Checkpoint com previsões alteradas falha na verificação completa",
  !fails(carregar_checkpoint_previsao(altered,state))&&fails(carregar_checkpoint_previsao(altered,state,TRUE)))
initial2 <- file.path(tmp,"initial_restrito")
state2 <- inicializar_analise(initial2,fitpath,t1path,cfgpath,snap,profile="restrito")
check("Checkpoint de outro estado inicial é recusado",fails(carregar_checkpoint_previsao(outA,state2))&&
  fails(avancar_previsao_analise(state2,snap,outA,cpA)))
write_snapshot(snapshots[[3]]$o,"prev-3",oficial_br(snapshots[[3]]$o,st=9L))
check("Mesmo identificador de snapshot com outro conteúdo é rejeitado",fails(avancar_previsao_analise(state,snap,outA,cpA)))
write_snapshot(snapshots[[3]]$o,"prev-3",oficial_br(snapshots[[3]]$o))
check("Outro número de sorteios reprocessa o mesmo snapshot",
  avancar_previsao_analise(state,snap,outA,cpA,sorteios=200L)$checkpoint$sequence==cpA$sequence+1L)
check("Diretório de saída não mistura estados iniciais",fails(publicar_previsao_analise(
  modifyList(cpA,list(initial_state_id="outro")),cpA$results,outA)))

run_cli <- function(command,extra=character(),directory=file.path(tmp,"cli")) {
  lines <- suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),
    c("--vanilla",shQuote(file.path(root,"executar_previsao.R")),command,
      "--estado-inicial",shQuote(initial),"--snapshot",shQuote(snap),"--saida",shQuote(directory),extra),
    stdout=TRUE,stderr=TRUE))
  list(status=if(is.null(attr(lines,"status")))0L else attr(lines,"status"),lines=lines)
}
cli1 <- run_cli("atualizar",c("--sorteios","100"))
check("CLI processa um snapshot com previsões",cli1$status==0L&&any(grepl("previsao_publicada",cli1$lines)))
cli2 <- run_cli("acompanhar",c("--sorteios","100","--ciclos","2","--intervalo","0.01"))
check("CLI retoma do checkpoint e não reprocessa o mesmo snapshot",cli2$status==0L&&
  any(grepl("\"event\":\"retomada\"",cli2$lines))&&sum(grepl("snapshot_ja_processado",cli2$lines))==2L&&
  nrow(fread(file.path(tmp,"cli","historico.csv")))==1L)
check("CLI inspeciona e regenera as previsões do checkpoint",run_cli("inspecionar",c("--completo","sim"))$status==0L)
check("CLI rejeita opções fora do comando",run_cli("atualizar",c("--ciclos","2"))$status!=0L&&
  run_cli("atualizar",c("--inexistente","1"))$status!=0L&&run_cli("atualizar",c("--sorteios","1"))$status!=0L)
check("Execução não altera ajuste histórico nem ponto de partida",identical(fit_hash,hash_arquivo_analise(fitpath))&&
  identical(initial_hash,hash_arquivo_analise(file.path(initial,"estado.rds"))))
# Medição de desempenho na população real com o snapshot publicado no momento.
# Grava apenas em diretório temporário; não substitui os testes integrados pendentes.
real_state <- file.path(root,"data","processed","estado_inicial_v2")
real_snapshot <- file.path(root,"data","live","tse_export")
if(dir.exists(real_state)&&file.exists(file.path(real_snapshot,"manifest.json"))) {
  rs_state <- carregar_ponto_partida_analise(real_state)
  real_out <- file.path(tmp,"real")
  elapsed <- system.time(real <- avancar_previsao_analise(rs_state,real_snapshot,real_out))[["elapsed"]]
  reload <- system.time(real_cp <- carregar_checkpoint_previsao(real_out,rs_state))[["elapsed"]]
  s <- real$resultados$resumo
  check("População real: pesos T1 e rótulos de aproximação preservados",s$secoes==nrow(rs_state$population)&&
    near(sum(real$resultados$secoes$votos_a_projetados+real$resultados$secoes$votos_b_projetados),
      s$validos_pendentes_projetados+sum(real$checkpoint$observed$validos))&&
    s$fallback_t1==sum(rs_state$population$fallback!="nenhum")&&identical(real_cp$id,real$checkpoint$id))
  jsonlite::write_json(list(scope="performance smoke run on the real frozen population; not the pending integrated tests",
    measured_utc=agora_analise(),snapshot_id=real$checkpoint$snapshot_id,observed_sections=nrow(real$checkpoint$observed),
    sections=s$secoes,approximated_sections=s$fallback_t1,draws=s$sorteios,
    cycle_seconds=round(elapsed,2),checkpoint_load_seconds=round(reload,2),
    secoes_csv_mb=round(file.info(file.path(real$caminho,"secoes.csv"))$size/1e6,1),
    checkpoint_rds_mb=round(file.info(file.path(real$caminho,"checkpoint.rds"))$size/1e6,2),
    pct_a_projetado=s$pct_a_projetado,pct_a_q025=s$pct_a_q025,pct_a_q975=s$pct_a_q975,
    official_source=s$fonte_oficial,anchored=s$ancora_oficial,machine=Sys.info()[["machine"]],R=R.version.string),
    file.path(out,"desempenho_populacao_real.json"),pretty=TRUE,auto_unbox=TRUE,digits=NA)
}
jsonlite::write_json(list(status="passou",tests_passed=length(checks),
  fixture="40 synthetic sections in AC/AL; full saved historical fit and V2 central scales",
  scope="items 3 and 4: section/UF/total forecasts with joint posterior draws, official anchoring, checkpoint, recovery and CLI",
  pending="integrated tests listed in STATUS.md were not executed here",
  source_sha256=hashes_codigo_previsao()[c("previsao_execucao.R","ancorar.R","analise_execucao.R","online_conjugado.R")]),
  file.path(out,"verificacao_testes.json"),pretty=TRUE,auto_unbox=TRUE)
print(rbindlist(checks))
unlink(tmp,recursive=TRUE)
