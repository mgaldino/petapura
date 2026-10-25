import {validateSnapshot,validateConfig,readJSON,createPoller,share,progress,isComplete,freshness,isPrior,isAwaitingCount} from './data.js';
import {renderChart} from './chart.js';
import {attachSimulation} from './simulation.js';
import {attachAnalytics} from './analytics.js';
const root=document.getElementById('presidencia-2026-preview'),$=id=>document.getElementById(id);
const fmt=(v,d=1)=>v.toLocaleString('pt-BR',{minimumFractionDigits:d,maximumFractionDigits:d});
const time=v=>new Intl.DateTimeFormat('pt-BR',{timeZone:'America/Sao_Paulo',hour:'2-digit',minute:'2-digit',second:'2-digit'}).format(new Date(v));
const state={snapshot:null,config:null,visible:[true,true],error:false,demo:new URLSearchParams(location.search).get('demo')==='1',demoSnapshots:[],chartScenario:'learning'};
function connection(){
  const el=$('connection-status'),s=state.snapshot;let text='';
  if(state.error)text=s&&!isAwaitingCount(s)?'Não foi possível atualizar. Exibindo os últimos dados recebidos.':'Não foi possível carregar os dados. A consulta será refeita automaticamente.';
  else if(s&&freshness(s,Date.now(),state.config.stale_after_ms,state.config.counting_starts_at)==='stale')text=isAwaitingCount(s)?'Ainda não recebemos resultados recentes da apuração. A consulta será refeita automaticamente.':'Os dados estão sem atualização recente. A previsão abaixo pode estar desatualizada.';
  el.hidden=!text;if(el.textContent!==text)el.textContent=text;
}
function draw(){if(state.snapshot){const s=state.snapshot,f=state.chartScenario==='2022'?s.forecast_2022:s.forecast;renderChart(root.querySelector('svg'),root.querySelector('.pres-chart-tooltip'),{...s,forecast:f||s.forecast},state.visible,f?state.chartScenario:'learning');}}
function result(s,boxId='result',prefix='',f=s.forecast){
  const box=document.getElementById(boxId),$=id=>document.getElementById(prefix+id),complete=isComplete(s),value=complete?share(s.counting):f?.share_a;
  if(isAwaitingCount(s)){
    box.innerHTML='<div class="pres-result"><div class="pres-name"><i class="pres-dot" aria-hidden="true"></i><span id="candidate-name"></span></div><div class="pres-number"><span id="projected-share" class="pres-number-value">ND</span></div><p class="pres-denominator">Não disponível</p><p class="pres-status">Aguardando urnas serem apuradas.</p></div><div class="pres-uncertainty"><h2>Faixa da projeção</h2><p class="pres-range-value">ND</p><p class="pres-range-caption">Disponível após os primeiros boletins de urna.</p></div>'.replaceAll('id="',`id="${prefix}`);
    $('candidate-name').textContent=s.candidates.a.name;return;
  }
  if(value===undefined||value===null){box.innerHTML='<div class="pres-empty"><h2>Aguardando previsão</h2><p>As estimativas serão apresentadas aqui quando estiverem disponíveis.</p></div>';return;}
  box.innerHTML='<div class="pres-result"><div class="pres-name"><i class="pres-dot" aria-hidden="true"></i><span id="candidate-name"></span></div><div class="pres-number"><span id="projected-share" class="pres-number-value"></span><span>%</span></div><p class="pres-denominator" id="result-denominator"></p><p class="pres-status" id="result-status"></p></div><div class="pres-uncertainty" id="uncertainty"></div>'.replaceAll('id="',`id="${prefix}`);
  $('candidate-name').textContent=s.candidates.a.name;$('projected-share').textContent=fmt(value);$('result-denominator').textContent=complete?'dos votos válidos apurados':'dos votos válidos no resultado final';
  $('result-status').textContent=complete?'Apuração concluída.':Math.abs(value-50)<.05?'Em torno de 50% na projeção atual.':value>50?'Acima de 50% na projeção atual.':'Abaixo de 50% na projeção atual.';
  if(complete){$('uncertainty').innerHTML='<h2>Resultado final apurado</h2><p>Os boletins de urna de todas as seções já foram incorporados. A projeção dá lugar ao resultado apurado.</p>';return;}
  const b=f.interval,precision=b.upper-b.lower<.2?2:1;
  const low=Math.max(0,Math.min(40,Math.floor((Math.min(b.lower,value,50)-2)/5)*5)),high=Math.min(100,Math.max(60,Math.ceil((Math.max(b.upper,value,50)+2)/5)*5)),pct=v=>(v-low)/(high-low)*100;
  $('uncertainty').innerHTML='<h2>Faixa da projeção</h2><p class="pres-range-value" id="range-value"></p><p class="pres-range-caption" id="range-caption"></p><div class="pres-interval" role="img" id="range-image"><i class="pres-axis-track"></i><i class="pres-range-band" id="range-band"></i><i class="pres-threshold" id="range-threshold"></i><i class="pres-estimate" id="range-estimate"></i></div><div class="pres-range-ticks"><span id="range-min"></span><span id="range-majority"></span><span id="range-max"></span></div><div class="pres-threshold-label">50% · limiar de vitória</div><p class="pres-risk" id="range-risk"></p>'.replaceAll('id="',`id="${prefix}`);
  $('range-value').textContent=`${fmt(b.lower,precision)}% a ${fmt(b.upper,precision)}%`;$('range-caption').textContent=`${fmt(b.level*100,0)}% das simulações deste cenário`;
  $('range-image').setAttribute('aria-label',`Projeção de ${fmt(value)}%, faixa de ${fmt(b.level*100,0)}% entre ${fmt(b.lower,precision)}% e ${fmt(b.upper,precision)}%. Referência de vitória acima de 50%.`);
  $('range-band').style.left=`${pct(b.lower)}%`;$('range-band').style.width=`${pct(b.upper)-pct(b.lower)}%`;$('range-threshold').style.left=`${pct(50)}%`;$('range-estimate').style.left=`${pct(value)}%`;
  $('range-min').textContent=`${low}%`;$('range-majority').textContent='50%';$('range-majority').style.left=`${pct(50)}%`;$('range-max').textContent=`${high}%`;
  $('range-risk').textContent=b.lower<50&&b.upper>50?'A vitória ainda está em aberto. A faixa inclui resultados abaixo e acima de 50%.':b.lower>=50?'A faixa está acima de 50%. Cenários fora dela ainda podem incluir uma derrota.':'A faixa está abaixo de 50%. Cenários fora dela ainda podem incluir uma vitória.';
}
function render(s){
  state.snapshot=s;const complete=isComplete(s),f=s.forecast,partial=share(s.counting),demo=s.mode==='demo',prior=isPrior(s),awaiting=isAwaitingCount(s),dual=Boolean(s.forecast_2022)&&!complete;
  $('mode-label').textContent=demo?'DEMONSTRAÇÃO · CANDIDATOS E DADOS FICTÍCIOS':s.mode==='waiting'?'PRESIDENTE DA REPÚBLICA · AGUARDANDO DADOS':'PRESIDENTE DA REPÚBLICA · SEGUNDO TURNO';
  $('update-time').textContent=awaiting?'Aguardando apuração':s.generated_at?`${demo?(state.config.local_simulation?'Simulação atualizada':'Cenário ilustrativo'):'Dados atualizados'} · ${time(s.generated_at)} (Brasília)`:'Aguardando dados';
  $('main-title').textContent=complete?'Resultado final apurado':prior&&!awaiting?'Previsão inicial do modelo':'Projeção do resultado final';
  $('intro-description').hidden=awaiting;
  $('intro-description').textContent=complete?'Votação com os boletins de urna de todas as seções.':prior?`Previsão a priori, antes de incorporar votos do segundo turno.${dual?' Os dois cenários coincidem neste ponto.':''}`:`Estimativa atualizada da votação de ${s.candidates.a.name} ao fim da apuração.`;
  $('learning-intro').hidden=!dual;$('historical-scenario').hidden=!dual;$('scenarios-note').hidden=!dual||awaiting;$('scenario-switch').hidden=!dual||awaiting;
  $('chart-section').hidden=false;
  for(const id of ['counted','uncertainty-details'])$(id).hidden=awaiting;
  if(awaiting){
    $('result').setAttribute('aria-label','Projeção não disponível. Aguardando apuração');result(s);
    if(dual)result(s,'result-2022','historical-',s.forecast_2022);else $('result-2022').replaceChildren();
    $('chart-title').textContent='Aguardando urnas serem apuradas';
    $('legend-a').textContent=s.candidates.a.name;$('legend-b').textContent=s.candidates.b.name;
    root.querySelector('.pres-legend').hidden=true;
    $('chart-note').textContent='50% / 50% é apenas uma posição visual de espera. As projeções aparecerão após os primeiros boletins de urna.';
    for(const id of ['win-probability','model-notes','model-notes-2022','source-details'])$(id).textContent='';
    $('live-summary').textContent='Projeções ND: não disponíveis. Aguardando urnas serem apuradas. O gráfico em 50% para cada candidatura é apenas uma posição visual de espera.';
    state.chartScenario='learning';draw();connection();return;
  }
  root.querySelector('.pres-legend').hidden=false;
  $('result').setAttribute('aria-label','Resultado final e incerteza');
  result(s);
  if(dual)result(s,'result-2022','historical-',s.forecast_2022);
  if(!dual)state.chartScenario='learning';
  root.querySelectorAll('[data-scenario]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.scenario===state.chartScenario)));
  $('chart-title').textContent=dual?`Da apuração ao resultado final · ${state.chartScenario==='2022'?'relação de 2022':'com aprendizado'}`:'Da apuração ao resultado final';
  $('legend-a').textContent=s.candidates.a.name;$('legend-b').textContent=s.candidates.b.name;
  $('chart-interval-label').textContent=f&&!complete?`Faixa de ${fmt(f.interval.level*100,0)}%`:'Faixa da projeção';
  $('projection-legend').hidden=!f||complete;$('interval-legend').hidden=!f||complete;
  $('chart-note').textContent=complete?'Apuração concluída. As linhas mostram a projeção ao longo da apuração até o resultado apurado.':f?'A linha contínua mostra a projeção do resultado final a cada atualização, a partir da previsão inicial do modelo. Depois de “Agora”, a linha tracejada repete a projeção atual, sem prever o ritmo da apuração.':'Ainda não há projeção final disponível.';
  $('counted').innerHTML='<h2>Apurado até agora</h2><div class="pres-counted-results"><p id="partial-votes"></p><p id="partial-sections"></p></div>';
  if(partial===null)$('partial-votes').textContent='Ainda não há votos válidos apurados.';else{const b=document.createElement('b');b.textContent=`${fmt(partial)}%`;$('partial-votes').append(b,document.createTextNode(` dos votos válidos para ${s.candidates.a.name}`));}
  if(s.counting){const p=progress(s.counting),b=document.createElement('b');b.textContent=`${fmt(p,p>0&&p<1?2:1)}%`;$('partial-sections').append(b,document.createTextNode(` das seções apuradas (${fmt(s.counting.reported_sections,0)} de ${fmt(s.counting.total_sections,0)})`));}else $('partial-sections').textContent='Avanço da apuração ainda indisponível.';
  $('win-probability').textContent=complete?'A apuração está concluída.':f?.win_probability_a!=null?`Chance de vitória de ${s.candidates.a.name}: ${fmt(f.win_probability_a*100,0)}%.`:'O modelo ainda não informou uma chance de vitória.';
  $('interval-explanation').textContent=complete?'A apuração foi concluída. O resultado observado substitui a projeção.':f?`A faixa de ${fmt(f.interval.level*100,0)}% reúne os resultados centrais das simulações sob as hipóteses de cada cenário; ${fmt((1-f.interval.level)*100,0)}% ficam fora dela. Ela pode mudar durante a apuração.`:'A faixa será apresentada com o nível informado pelo modelo. Ela depende das hipóteses adotadas.';
  $('model-notes-2022').hidden=!dual;$('model-notes-2022').textContent=dual?`Relação de 2022. ${s.forecast_2022.notes.join(' ')}`:'';
  $('model-notes').textContent=f?`Modelo: ${f.model_version}. Previsão calculada às ${time(f.generated_at)} (Brasília). ${f.notes.join(' ')}`:'';
  $('source-details').textContent=s.counting?`Apurado: ${demo?'boletins de urna fictícios':'boletins de urna publicados pelo TSE, com status Recebido ou Totalizado'}; ${fmt(s.counting.reported_sections,0)} de ${fmt(s.counting.total_sections,0)} seções.`:'';
  $('source-label').textContent=demo?'Demonstração com dados sintéticos. Sem conexão com a apuração do TSE.':'Dados: boletins de urna publicados pelo TSE. As estimativas são produzidas pelo modelo do projeto.';
  $('demo-link').textContent=state.config.local_simulation?(state.demo?'Voltar à simulação integrada':'Ver mockup com dados ilustrativos'):demo?'Voltar à apuração':'Ver demonstração com dados fictícios';$('demo-link').href=state.config.local_simulation?(state.demo?'./':'?demo=1'):demo?'./':'?demo=1';
  root.querySelectorAll('[data-series]').forEach(b=>b.setAttribute('aria-pressed',state.visible[Number(b.dataset.series)]?'true':'false'));
  $('live-summary').textContent=complete?`Apuração concluída. ${s.candidates.a.name}: ${fmt(partial)}% dos votos válidos.`:f?`${s.candidates.a.name}: projeção de ${fmt(f.share_a)}% dos votos válidos, faixa de ${fmt(f.interval.level*100,0)}% entre ${fmt(f.interval.lower)}% e ${fmt(f.interval.upper)}%.${dual?` Cenário relação de 2022: ${fmt(s.forecast_2022.share_a)}%, faixa entre ${fmt(s.forecast_2022.interval.lower)}% e ${fmt(s.forecast_2022.interval.upper)}%.`:''}`:'Aguardando previsão.';
  draw();connection();
}
root.querySelectorAll('[data-scenario]').forEach(button=>button.addEventListener('click',()=>{state.chartScenario=button.dataset.scenario;render(state.snapshot);}));
root.querySelectorAll('[data-series]').forEach(button=>button.addEventListener('click',()=>{const i=Number(button.dataset.series);state.visible[i]=!state.visible[i];button.setAttribute('aria-pressed',String(state.visible[i]));draw();}));
new ResizeObserver(()=>requestAnimationFrame(draw)).observe(root);
async function start(){
  state.config=validateConfig(await readJSON('./config.json',{signal:AbortSignal.timeout(10000)}));
  attachAnalytics(state.config);
  if(state.demo){
    const list=await readJSON(state.config.demo_endpoint);if(!Array.isArray(list)||!list.length)throw new Error('Demonstração vazia');state.demoSnapshots=list.map(s=>validateSnapshot(s,state.config));
    if(list.some(s=>s.mode!=='demo'))throw new Error('Modo incorreto na demonstração');
    const control=$('demo-control'),slider=control.querySelector('input');control.hidden=false;slider.max=list.length-1;slider.value=Math.min(1,list.length-1);
    $('demo-start').textContent=time(list[0].generated_at).slice(0,5);$('demo-end').textContent=time(list.at(-1).generated_at).slice(0,5);
    slider.addEventListener('input',()=>render(state.demoSnapshots[Number(slider.value)]));render(list[Number(slider.value)]);return;
  }
  const poller=createPoller({url:state.config.endpoint,config:state.config,onLoading:connection,onData:s=>{state.error=false;if(state.snapshot?.snapshot_id===s.snapshot_id){connection();return;}render(s);},onError:()=>{state.error=true;connection();}});
  if(state.config.local_simulation)attachSimulation({refresh:()=>poller.refresh()});
  poller.start();document.addEventListener('visibilitychange',()=>{if(!document.hidden)poller.refresh();});window.addEventListener('online',()=>poller.refresh());window.addEventListener('offline',()=>{state.error=true;connection();});window.addEventListener('pagehide',()=>poller.stop());window.addEventListener('pageshow',event=>{if(event.persisted)poller.start();});
}
start().catch(()=>{state.error=true;state.config ||= {stale_after_ms:180000};connection();$('connection-status').textContent='Não foi possível iniciar a página. Recarregue para tentar novamente.';});
