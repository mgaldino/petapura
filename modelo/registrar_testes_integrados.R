# Gera o registro em markdown a partir das evidências dos testes integrados.
# Tabelas são transcritas dos CSV/JSON; nenhum número é digitado à mão.
args_all <- commandArgs(FALSE)
root <- dirname(normalizePath(sub("^--file=","",args_all[grepl("^--file=",args_all)])[1]))
suppressPackageStartupMessages(library(data.table))
out <- file.path(root,"output","testes_integrados_20261020")
br <- function(x,d=2)formatC(x,format="f",digits=d,big.mark=".",decimal.mark=",")
pct <- function(x)paste0(br(100*x,1),"%")
tabela <- function(d,header,align) {d <- as.data.frame(lapply(d,as.character));c(paste0("| ",paste(header,collapse=" | ")," |"),
  paste0("|",paste(align,collapse="|"),"|"),apply(d,1,function(r)paste0("| ",paste(r,collapse=" | ")," |")))}
reg <- fread(file.path(out,"registro_fluxo.csv"),colClasses="character")
flow <- jsonlite::read_json(file.path(out,"verificacao_fluxo.json"))
times <- fread(file.path(out,"tempos_fluxo.csv"))
# Intervalo degenerado com 100% dos votos conhecidos: comparar com tolerância numérica.
times[,`:=`(cobre=pct_a_q025-1e-9<=pct_verdade_final&pct_verdade_final<=pct_a_q975+1e-9,
  erro_pp=fifelse(abs(erro_pp)<5e-4,0,erro_pp))]
lines <- c("# Registro dos testes integrados do executor completo","",
  sprintf("Gerado por `registrar_testes_integrados.R` em %s, a partir de `output/testes_integrados_20261020/`.",
    format(Sys.time(),"%d/%m/%Y %H:%M",tz="America/Sao_Paulo")),"",
  "## Fluxo completo: coletor, publicação, leitor e executor","",
  sprintf("População real congelada (499.248 seções); BUs e totais oficiais **sintéticos**, cenário `%s`, chegada `%s`, semente %s. Componentes locais: `%s`. Resultado final sintético: %s%%. Verificações: **%s aprovadas e %s reprovadas**.",
    flow$truth$scenario,flow$truth$arrival,flow$truth$seed,if(is.null(flow$local_components))"nenhum (protótipo)" else flow$local_components$version,br(flow$truth$pct_final,4),flow$passed,flow$failed),"",
  "Versão D (21/10/2026): cada previsão traz o cenário com aprendizado, que é a versão C sem alteração, e o cenário 2022, que projeta as pendentes com a relação de 2022 sem aprender com os BUs. O fluxo da Tabela 1 é da versão D; as simulações de chegada e o replay das Tabelas 3 a 6 foram executados na versão C e valem para o cenário com aprendizado. Registro da versão C em `versao_c/`.","",
  "Tabela 1. Verificações por teste, com entrada, esperado e obtido.","")
reg[,n:=seq_len(.N)]
lines <- c(lines,tabela(reg[,.(n,teste,verificacao,entrada,esperado,obtido,ifelse(passou=="TRUE","sim","**não**"))],
  c("#","Teste","Verificação","Entrada","Esperado","Obtido","Passou"),c("---:","---","---","---","---","---","---")),"")
lines <- c(lines,"Tabela 2. Tempos e saídas por snapshot da execução contínua. Exportação e publicação usam o código do coletor; o ciclo é o tempo informado por `executar_previsao.R`; a latência vai da publicação ao ponteiro novo.","",
  tabela(times[,.(snapshot,br(pct_bus,1),fonte,ifelse(ancora,"sim","não"),br(exportacao_coletor_s,1),br(publicacao_s,1),
    br(ciclo_previsao_s,1),br(latencia_ate_publicar_s,1),br(pacote_mb,0),br(pct_a_projetado,3),
    paste0("[",br(pct_a_q025,2),"; ",br(pct_a_q975,2),"]"),br(erro_pp,3),ifelse(cobre,"sim","não"))],
  c("Snapshot","BUs (%)","Fonte","Âncora","Exportação (s)","Publicação (s)","Ciclo (s)","Latência (s)","Pacote (MB)",
    "Projeção (%)","Intervalo 95%","Erro (p.p.)","Cobre"),c("---","---:","---","---","---:","---:","---:","---:","---:","---:","---","---:","---")),"")
if(file.exists(file.path(out,"chegada_simulacao_2026_resumo.csv"))) {
  sim <- fread(file.path(out,"chegada_simulacao_2026_resumo.csv"))
  chegada <- jsonlite::read_json(file.path(out,"verificacao_chegada.json"))
  fmt_sim <- function(d)d[,.(ordem,pct(fracao),repeticoes,br(vies_pp,3),br(rmse_pp,3),pct(cobertura),br(100*ep_cobertura,1),
    br(amplitude_media_pp,2),pct(cobertura_uf),br(rmse_uf_pp,2))]
  hdr <- c("Ordem","BUs","Rep.","Viés (p.p.)","REQM (p.p.)","Cobertura","EP (p.p.)","Amplitude (p.p.)","Cobertura UF","REQM UF (p.p.)")
  al <- c("---","---:","---:","---:","---:","---:","---:","---:","---:","---:")
  for(cen in c("correto","realista")) {
    lines <- c(lines,sprintf("Tabela %s. Simulação na população real de 2026, cenário `%s`: erro do total nacional projetado em relação ao resultado final sintético e cobertura do intervalo de 95%%, em %s repetições de %s sorteios. REQM: raiz do erro quadrático médio; EP: erro-padrão de Monte Carlo da cobertura; UF: média das 28 UFs.",
      if(cen=="correto")3 else 4,cen,chegada$repetitions,chegada$draws),"",
      tabela(fmt_sim(sim[cenario==cen]),hdr,al),"")
  }
  rp <- fread(file.path(out,"replay_2022_reserva_resumo.csv"))
  lines <- c(lines,sprintf("Tabela 5. Replay de 2022 fora da amostra: %s seções reais de %s municípios reservados, BUs T2 reais, ajuste de treino com %s seções. Resultado real da reserva: %s%%. Ordens aleatórias em %s repetições; ordens determinísticas uma vez.",
      br(chegada$reserve_sections,0),br(chegada$reserve_municipalities,0),br(chegada$train_fit_n,0),br(chegada$replay_truth_pct,4),chegada$repetitions),"",
    tabela(rp[,.(ordem,pct(fracao),repeticoes,br(vies_pp,3),br(rmse_pp,3),pct(cobertura),br(amplitude_media_pp,2),pct(cobertura_uf),br(rmse_uf_pp,2))],
      c("Ordem","BUs","Rep.","Viés (p.p.)","REQM (p.p.)","Cobertura","Amplitude (p.p.)","Cobertura UF","REQM UF (p.p.)"),
      c("---","---:","---:","---:","---:","---:","---:","---:","---:")),"")
}
proto <- file.path(out,"prototipo");mid <- file.path(out,"correcoes_2_3")
ler_resumos <- function(d)if(file.exists(file.path(d,"chegada_simulacao_2026_resumo.csv")))rbind(
  fread(file.path(d,"chegada_simulacao_2026_resumo.csv")),
  fread(file.path(d,"replay_2022_reserva_resumo.csv"))[,cenario:="replay_2022"],fill=TRUE) else NULL
old <- ler_resumos(proto);m23 <- ler_resumos(mid);new <- ler_resumos(out)
if(!is.null(old)&&!is.null(new)) {
  key <- c("cenario","ordem","fracao")
  cmp <- merge(old[,.(cenario,ordem,fracao,cob_a=cobertura,vies_a=vies_pp)],
    new[,.(cenario,ordem,fracao,cob_c=cobertura,vies_c=vies_pp,mud_c=if("mudanca_abs_media_pp"%in%names(new))mudanca_abs_media_pp else NA_real_,rep=repeticoes)],by=key)
  if(!is.null(m23))cmp <- merge(cmp,m23[,.(cenario,ordem,fracao,cob_b=cobertura,vies_b=vies_pp)],by=key,all.x=TRUE) else cmp[,`:=`(cob_b=NA_real_,vies_b=NA_real_)]
  cmp <- cmp[ordem!="nenhuma"][order(cenario,ordem,fracao)]
  lines <- c(lines,"Tabela 6. Três versões com as mesmas verdades, ordens e sementes: protótipo (A); correções 2 e 3, choque municipal, razão de válidos e inversa do logit (B); versão de 20/10, que acrescenta a âncora pela soma estadual e a atualização gradual até 15% dos válidos T1 (C, igual ao cenário com aprendizado da versão D). Cobertura do intervalo de 95%, viés do total nacional e, para C, mudança absoluta média da projeção em relação a 0% dos BUs.","",
    tabela(cmp[,.(cenario,ordem,pct(fracao),rep,pct(cob_a),ifelse(is.na(cob_b),"—",pct(cob_b)),pct(cob_c),br(vies_a,3),
      ifelse(is.na(vies_b),"—",br(vies_b,3)),br(vies_c,3),ifelse(is.na(mud_c),"—",br(mud_c,3)))],
      c("Cenário","Ordem","BUs","Rep.","Cobertura A","Cobertura B","Cobertura C","Viés A (p.p.)","Viés B (p.p.)","Viés C (p.p.)",
        "Mudança C (p.p.)"),c("---","---","---:","---:","---:","---:","---:","---:","---:","---:","---:")),"")
}
writeLines(lines,file.path(out,"REGISTRO.md"),useBytes=TRUE)
cat("REGISTRO.md com",length(lines),"linhas\n")
