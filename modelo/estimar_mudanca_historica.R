# Quanto a relação entre 1º e 2º turno muda de uma eleição para outra, e quanto essa
# mudança é comum ao país (correlação entre UFs). Base empírica para a escala V2 de Q.
# Unidade: município x zona (arquivos de dados abertos do TSE de 2010, 2014 e 2018;
# 2022 agregado das seções). Mesma especificação do modelo: logit suavizado do candidato
# do PT no 2º turno, com intercepto e inclinação do voto PT no 1º turno por UF e
# comparecimento, demais candidatos e válidos como coeficientes nacionais.
args_all <- commandArgs(FALSE)
root <- dirname(normalizePath(sub("^--file=","",args_all[grepl("^--file=",args_all)])[1]))
source(file.path(root,"previsao_execucao.R"),encoding="UTF-8")
out <- file.path(root,"output","mudanca_historica_20261020")
dir.create(out,recursive=TRUE,showWarnings=FALSE)
safe_logit <- .analise_componentes$safe_logit
state <- carregar_ponto_partida_analise(file.path(root,"data","processed","estado_inicial_v2"))
scale <- state$prior$spec$scale               # escalas das seções de 2022: mesmas unidades de Q
opponent <- c(`2010`=45L,`2014`=45L,`2018`=17L,`2022`=22L)
regions <- data.table(uf=c("AC","AM","AP","PA","RO","RR","TO","AL","BA","CE","MA","PB","PE","PI","RN","SE",
  "DF","GO","MS","MT","ES","MG","RJ","SP","PR","RS","SC"),
  regiao=c(rep("Norte",7),rep("Nordeste",9),rep("Centro-Oeste",4),rep("Sudeste",4),rep("Sul",3)))

munzona_tse <- function(year) {
  cand <- fread(file.path(root,"data","historico_tse",sprintf("presidente_candidato_munzona_%d.csv",year)))
  det <- fread(file.path(root,"data","historico_tse",sprintf("presidente_detalhe_munzona_%d.csv",year)))
  key <- c("uf","cd_municipio","zona")
  votes <- cand[,.(pt=sum(votos[nr_candidato==13]),opp=sum(votos[nr_candidato==opponent[[as.character(year)]]])),by=c(key,"turno")]
  det <- det[,lapply(.SD,sum),by=c(key,"turno"),.SDcols=c("secoes","aptos","comparecimento","validos","brancos","nulos")]
  z <- merge(det,votes,by=c(key,"turno"))
  t1 <- z[turno==1];t2 <- z[turno==2]
  merge(t1[,.(uf,cd_municipio,zona,aptos,comparecimento,validos,pt1=pt,opp1=opp)],
    t2[,.(uf,cd_municipio,zona,secoes,pt2=pt,opp2=opp)],by=key)
}
munzona_2022 <- function() {
  raw <- file.path(root,"..","data","eleicoes_2022_2026","raw")
  agg <- function(f)as.data.table(arrow::read_parquet(file.path(raw,f)))[,.(secoes=.N,aptos=sum(aptos),
    comparecimento=sum(comparecimento),validos=sum(validos),pt=sum(c13),opp=sum(c22)),by=.(uf,cd_municipio=cd_mun,zona)]
  t1 <- agg("section_votes_2022_T1.parquet");t2 <- agg("section_votes_2022_T2.parquet")
  merge(t1[,.(uf,cd_municipio,zona,aptos,comparecimento,validos,pt1=pt,opp1=opp)],
    t2[,.(uf,cd_municipio,zona,secoes,pt2=pt,opp2=opp)],by=c("uf","cd_municipio","zona"))
}

preparar_eleicao <- function(d) {
  d <- d[aptos>0&comparecimento>0&validos>0&pt2+opp2>0&uf%in%regions$uf]
  d[,`:=`(x_pt=pt1/validos,x_outros=(validos-pt1-opp1)/validos,comp=comparecimento/aptos,
    x_validos=safe_logit(validos,comparecimento),y=safe_logit(pt2,pt2+opp2),w=secoes)]
  d[]
}
centros <- function(d)list(uf=d[,.(xpt=weighted.mean(x_pt,w),comp=weighted.mean(comp,w)),keyby=uf],
  outros=weighted.mean(d$x_outros,d$w),validos=weighted.mean(d$x_validos,d$w))

# Os dois anos de cada par são centrados no MESMO ponto (média dos centros das duas eleições):
# o intercepto compara o 2º turno esperado para o mesmo perfil de 1º turno, sem confundir a
# mudança da relação com a mudança do nível do PT no 1º turno. Escalas das seções de 2022.
ajustar_eleicao <- function(d,year,cen,par) {
  d <- merge(copy(d),cen$uf,by="uf",suffixes=c("","_c"))
  d[,`:=`(xpt_s=(x_pt-xpt_c)/scale[["x_lula"]],comp_s=(comp-comp_c)/scale[["taxa_comparecimento"]],
    outros_s=(x_outros-cen$outros)/scale[["x_outros"]],validos_s=(x_validos-cen$validos)/scale[["x_validos"]])]
  d[,uf:=factor(uf,levels=sort(regions$uf))]
  fit <- lm(y~0+uf+uf:xpt_s+comp_s+outros_s+validos_s,data=d,weights=w)
  b <- coef(fit);V <- vcov(fit)
  ufs <- levels(d$uf)
  rbind(data.table(ano=year,tipo="intercepto",uf=ufs,valor=b[paste0("uf",ufs)],ep=sqrt(diag(V)[paste0("uf",ufs)])),
    data.table(ano=year,tipo="inclinacao_voto_t1",uf=ufs,valor=b[paste0("uf",ufs,":xpt_s")],ep=sqrt(diag(V)[paste0("uf",ufs,":xpt_s")])),
    data.table(ano=year,tipo=c("comparecimento","outros","validos"),uf="BR",valor=b[c("comp_s","outros_s","validos_s")],
      ep=sqrt(diag(V)[c("comp_s","outros_s","validos_s")])))[,`:=`(unidades=nrow(d),par=par)]
}

dados <- lapply(list(`2010`=munzona_tse(2010),`2014`=munzona_tse(2014),`2018`=munzona_tse(2018),`2022`=munzona_2022()),preparar_eleicao)
pairs <- list(c(2010,2014),c(2014,2018),c(2018,2022))
coefs <- rbindlist(lapply(pairs,function(p) {
  c0 <- centros(dados[[as.character(p[1])]]);c1 <- centros(dados[[as.character(p[2])]])
  cen <- list(uf=c0$uf[c1$uf,on="uf",.(uf,xpt_c=(xpt+i.xpt)/2,comp_c=(comp+i.comp)/2)],
    outros=(c0$outros+c1$outros)/2,validos=(c0$validos+c1$validos)/2)
  label <- paste0(p[1],"→",p[2])
  rbind(ajustar_eleicao(dados[[as.character(p[1])]],p[1],cen,label),ajustar_eleicao(dados[[as.character(p[2])]],p[2],cen,label))
}))
fwrite(coefs,file.path(out,"coeficientes_por_eleicao.csv"))
changes <- rbindlist(lapply(pairs,function(p) {
  label <- paste0(p[1],"→",p[2])
  a <- coefs[par==label&ano==p[1]];b <- coefs[par==label&ano==p[2]]
  m <- merge(a[,.(tipo,uf,v0=valor,e0=ep)],b[,.(tipo,uf,v1=valor,e1=ep)],by=c("tipo","uf"))
  m[,.(par=label,tipo,uf,mudanca=v1-v0,var_amostral=e0^2+e1^2)]
}))
fwrite(changes,file.path(out,"mudancas_por_par.csv"))

# Decomposição: mudança da UF = parte nacional (comum) + parte da UF; média zero, como em Q.
componentes <- function(tp) {
  d <- merge(changes[tipo==tp],regions,by="uf")
  G <- uniqueN(d$uf)
  per <- d[,.(nacional=mean(mudanca),entre_ufs=var(mudanca),amostral=mean(var_amostral)),by=par]
  var_uf <- max(0,mean(per$entre_ufs-per$amostral))
  # Média das UFs carrega var_uf/G e o erro amostral médio/G além da parte nacional.
  var_nat <- max(0,mean(per$nacional^2)-var_uf/G-mean(per$amostral)/G)
  k <- nrow(per);m2 <- mean(per$nacional^2)
  nat_ic <- c(k*m2/qchisq(.975,k),k*m2/qchisq(.025,k))
  # Parte regional: UFs da mesma região se movem juntas além da parte nacional?
  d[,desvio:=mudanca-mean(mudanca),by=par]
  reg <- d[,{a <- .SD[,.(n=.N,m=mean(desvio),ss=sum((desvio-mean(desvio))^2)),by=regiao]
    within <- sum(a$ss)/(.N-nrow(a));between <- sum(a$n*a$m^2)/(nrow(a)-1)
    n0 <- (.N-sum(a$n^2)/.N)/(nrow(a)-1)
    .(regional=(between-within)/n0,uf_dentro_regiao=within)},by=par]
  data.table(coeficiente=tp,pares=k,ufs=G,dp_nacional=sqrt(var_nat),
    dp_nacional_ic95_inf=sqrt(max(0,nat_ic[1]-var_uf/G)),dp_nacional_ic95_sup=sqrt(nat_ic[2]),
    dp_uf=sqrt(var_uf),correlacao_entre_ufs=var_nat/(var_nat+var_uf),
    correlacao_ic95_inf=max(0,nat_ic[1]-var_uf/G)/(max(0,nat_ic[1]-var_uf/G)+var_uf),
    correlacao_ic95_sup=nat_ic[2]/(nat_ic[2]+var_uf),
    dp_regional=sqrt(max(0,mean(reg$regional))),dp_uf_dentro_regiao=sqrt(max(0,mean(reg$uf_dentro_regiao)-mean(per$amostral))))
}
comp <- rbind(componentes("intercepto"),componentes("inclinacao_voto_t1"))
comp[,`:=`(v2_dp_nacional=c(.10,.03),v2_dp_uf=c(.05,.02),v2_correlacao=c(.8,.03^2/(.03^2+.02^2)))]
fwrite(comp,file.path(out,"componentes_mudanca.csv"))
regional <- merge(changes[tipo%in%c("intercepto","inclinacao_voto_t1")],regions,by="uf")[,
  .(mudanca_media=mean(mudanca),ufs=.N),by=.(tipo,par,regiao)][order(tipo,par,regiao)]
fwrite(regional,file.path(out,"mudanca_por_regiao.csv"))
commons <- changes[tipo%in%c("comparecimento","outros","validos"),.(mudanca_rms=sqrt(mean(mudanca^2)),
  mudancas=paste(round(mudanca,3),collapse=" / ")),by=tipo][,v2_dp:=c(.02,.03,.03)]
fwrite(commons,file.path(out,"mudanca_coeficientes_nacionais.csv"))
jsonlite::write_json(list(scope="Changes of the T1->T2 relationship between elections, municipality x zone level, 27 UFs (exterior excluded)",
  elections=names(dados),pairs=sapply(pairs,paste,collapse="->"),units=coefs[,.(unidades=unidades[1]),by=.(par,ano)],
  centering="both elections of each pair centered at the average of their UF means (x_pt, turnout) and national means (others, valid)",
  source=c("TSE dados abertos votacao_candidato_munzona and detalhe_votacao_munzona 2010, 2014, 2018 (SHA256 in data/historico_tse/raw/manifesto_downloads.txt)",
    "2022 sections aggregated to municipality x zone"),measured_utc=agora_analise()),
  file.path(out,"proveniencia.json"),pretty=TRUE,auto_unbox=TRUE,digits=NA)
print(coefs[tipo!="intercepto"&tipo!="inclinacao_voto_t1"])
print(comp);print(commons);print(dcast(regional[tipo=="intercepto"],regiao~par,value.var="mudanca_media"))
