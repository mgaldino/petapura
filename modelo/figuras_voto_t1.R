# Cálculos e gráficos ficam em R; o Rmd apenas importa estes resultados.
args_all <- commandArgs(FALSE)
root <- dirname(normalizePath(sub("^--file=","",args_all[grepl("^--file=",args_all)])[1]))
suppressPackageStartupMessages(library(data.table))
out <- file.path(root,"output","comparecimento_preditor_20261020")
effects <- fread(file.path(out,"associacao_final_por_uf.csv"))
common <- effects[estrutura=="voto_t1"][1]
varied <- effects[estrutura=="ambos"][order(mediana_mudanca_voto_pp_em_p50)]
scores <- fread(file.path(out,"comparacao.csv"))
gates <- fread(file.path(out,"diagnosticos_finais.csv"))
replay <- fread(file.path(out,"ensaio_sequencial_2022.csv"))
summary <- list(associacao_comum=as.list(common),
  ufs_positivas_95=varied[q025_mudanca_pp>0,.N],ufs_negativas_95=varied[q975_mudanca_pp<0,.N],
  ufs_intervalo_cruza_zero=varied[q025_mudanca_pp<=0&q975_mudanca_pp>=0,.N],
  melhora_rmse_ambos=scores[estrutura=="voto_t1",rmse_pp]-scores[estrutura=="ambos",rmse_pp],
  erro_maximo_ensaio=max(abs(replay$erro_pp)),max_rhat=max(gates$max_rhat),min_ess=min(gates$min_ess_bulk))
jsonlite::write_json(summary,file.path(out,"resumo_material.json"),pretty=TRUE,auto_unbox=TRUE,digits=12)
grDevices::pdf(file.path(out,"figura_1_comparecimento_uf.pdf"),width=7.8,height=7.2)
par(mar=c(4,3.5,1,1),cex=.95)
y <- seq_len(nrow(varied))
range_x <- range(c(varied$q025_mudanca_pp,varied$q975_mudanca_pp,0))
plot(varied$mediana_mudanca_voto_pp_em_p50,y,xlim=range_x,ylim=c(.5,nrow(varied)+.5),
  xlab="Mudança prevista na votação de Lula (p.p.) por +1 p.p. de comparecimento T1",
  ylab="",yaxt="n",pch=19,col="#1d4ed8",cex=.8,bty="n")
axis(2,at=y,labels=varied$uf,las=1,tick=FALSE)
abline(v=0,col="#64748b",lty=3)
abline(v=common$mediana_mudanca_voto_pp_em_p50,col="#b45309",lty=2)
segments(varied$q025_mudanca_pp,y,varied$q975_mudanca_pp,y,col="#1d4ed8",lwd=1.5)
legend("bottomright",c("Mediana e intervalo posterior de 95% por UF","Coeficiente comum da versão operacional"),
  col=c("#1d4ed8","#b45309"),pch=c(19,NA),lty=c(1,2),bty="n",cex=.8)
dev.off()
grDevices::pdf(file.path(out,"figura_2_ensaio_voto_t1.pdf"),width=9,height=6.3)
par(mfrow=c(3,1),mar=c(3,4,1.5,1),cex=.9)
names_order <- c(aleatoria="Ordem aleatória",menor_lula_primeiro="Menor votação prevista de Lula primeiro",maior_lula_primeiro="Maior votação prevista de Lula primeiro")
for(name in names(names_order)) {
  r <- replay[ordem_simulada==name]
  plot(100*r$fracao,r$pct_previsao,type="l",col="#1d4ed8",lwd=2,
    ylim=range(c(r$pct_previsao,r$pct_apurado,r$pct_real),na.rm=TRUE),
    xlab="Seções recebidas (%; ordem simulada)",ylab="Lula (% dos válidos)",main=names_order[[name]])
  lines(100*r$fracao,r$pct_apurado,col="#b45309",lty=2)
  abline(h=r$pct_real[1],col="#047857",lty=3)
  if(name=="aleatoria") legend("topright",c("Previsão","Apurado","Final"),
    col=c("#1d4ed8","#b45309","#047857"),lty=c(1,2,3),bty="n",cex=.8)
}
dev.off()
