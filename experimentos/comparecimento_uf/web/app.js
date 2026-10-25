const $=id=>document.getElementById(id);
const pct=value=>Number.isFinite(value)?`${value.toLocaleString('pt-BR',{minimumFractionDigits:2,maximumFractionDigits:2})}%`:'—';
const date=value=>new Date(value).toLocaleString('pt-BR',{timeZone:'America/Sao_Paulo'});
function rows(id,items,label,observed){
  const body=$(id);body.replaceChildren();
  for(const row of items){const tr=document.createElement('tr');
    for(const value of [row[label],row[observed],pct(row.learning),pct(row.historical)]){
      const td=document.createElement('td');td.textContent=String(value);tr.append(td);
    }body.append(tr);
  }
}
async function refresh(){
  try{
    const [reportResponse,statusResponse]=await Promise.all([fetch('/api/report',{cache:'no-store'}),fetch('/api/status',{cache:'no-store'})]);
    if(!reportResponse.ok||!statusResponse.ok)throw new Error('Relatório local indisponível; nova tentativa em 5 segundos.');
    const report=await reportResponse.json(),status=await statusResponse.json();
    for(const key of ['learning','historical']){
      const f=report.national[key];$(key).textContent=pct(f.share);
      $(`${key}-range`).textContent=`Faixa de 95%: ${pct(f.lower)} a ${pct(f.upper)}`;
    }
    const prior=report.observed_sections===0;
    $('state').className=status.error?'error':'';
    $('state').textContent=status.error?`Falha na atualização: ${status.error}. Última projeção preservada.`:
      `${report.synthetic?'TESTE SINTÉTICO · ':''}${prior?'Previsão inicial, aguardando boletins. ':''}${report.observed_sections.toLocaleString('pt-BR')} BUs incorporados de ${report.sections.toLocaleString('pt-BR')} seções.`;
    $('time').textContent=`Cálculo: ${date(report.generated_at_utc)} · Última consulta: ${date(report.checked_at_utc)} · Brasília`;
    $('comparison').textContent=report.public_same_source?
      `Modelo público, com os mesmos dados: ${pct(report.public_national.learning)} com aprendizado e ${pct(report.public_national.historical)} na relação de 2022.`:
      'A comparação com o modelo público aguarda que as duas execuções processem o mesmo snapshot.';
    rows('countries',report.countries,'pais','apuradas');rows('ufs',report.ufs,'uf','observed');
  }catch(error){$('state').className='error';$('state').textContent=error.message;}
}
refresh();setInterval(refresh,5000);
