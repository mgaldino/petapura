import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {validateSnapshot,validateConfig,share,progress,isComplete,freshness,createPoller,readJSON,timestamp,isAwaitingCount} from '../web/assets/data.js';
import {chartPoints,projectionPoints,separateLabelBaselines} from '../web/assets/chart.js';
const load=name=>JSON.parse(readFileSync(new URL(`fixtures/${name}.json`,import.meta.url)));
const config=JSON.parse(readFileSync(new URL('../web/config.json',import.meta.url)));
const demo=JSON.parse(readFileSync(new URL('../web/demo/snapshots.json',import.meta.url)));
for(const name of ['waiting','live-95','prior','complete'])test(`contrato aceita ${name}`,()=>validateSnapshot(load(name),config));
test('demonstração tem três momentos coerentes',()=>{for(const s of demo)validateSnapshot(s,config);assert.equal(progress(demo[1].counting),65.2);assert.equal(share(demo[1].counting),49.6);});
test('95% permanece 95%; probabilidade ausente permanece nula',()=>{const s=validateSnapshot(load('live-95'),config);assert.equal(s.forecast.interval.level,.95);assert.equal(s.forecast.win_probability_a,null);});
test('previsão existe antes do primeiro BU',()=>{const s=load('prior');assert.equal(progress(s.counting),0);assert.equal(share(s.counting),null);assert.ok(s.forecast);});
test('abertura aguarda urnas mesmo quando a prior já foi calculada',()=>{
  assert.equal(isAwaitingCount(load('waiting')),true);
  assert.equal(isAwaitingCount(load('prior')),true);
});
test('primeira urna totalizada ou primeiro BU incorporado libera a projeção',()=>{
  for(const field of ['reported_sections','collected_sections']){
    const s=load('prior');s.counting[field]=1;
    validateSnapshot(s,config);assert.equal(isAwaitingCount(s),false);
  }
});
test('apuração em curso e resultado concluído saem do estado de espera',()=>{
  assert.equal(isAwaitingCount(load('live-95')),false);
  assert.equal(isAwaitingCount(load('complete')),false);
});
test('demonstração continua explorável no momento anterior à apuração',()=>{
  const s=load('prior');s.mode='demo';s.counting.source.area='DEMO';
  validateSnapshot(s,config);assert.equal(isAwaitingCount(s),false);
});
test('somente apuração completa com votos é resultado final',()=>{assert.equal(isComplete(load('complete')),true);assert.equal(isComplete(load('prior')),false);});
test('configuração impede polling sem intervalo',()=>{assert.equal(validateConfig(config),config);assert.throws(()=>validateConfig({...config,poll_interval_ms:0}));});
const invalid=[
  ['turno incorreto',s=>s.election.round=1],
  ['eleição diferente',s=>s.election.election_id='outra'],
  ['candidaturas trocadas',s=>s.candidates.a.id='22'],
  ['percentual em vez de probabilidade',s=>s.forecast.win_probability_a=77],
  ['quantis invertidos',s=>s.forecast.interval.lower=99],
  ['votos não somam válidos',s=>s.counting.votes_a++],
  ['bool não é contagem',s=>s.counting.reported_sections=true],
  ['mais seções que o total',s=>s.counting.reported_sections=10001],
  ['fonte estadual isolada',s=>s.counting.source.area='SP'],
  ['previsão de outro snapshot',s=>s.forecast.source_snapshot_id='outro'],
  ['dados privados fora do contrato',s=>s.posterior_draws=[1,2,3]],
  ['parâmetros fora do contrato público',s=>s.forecast.coefficients=[1]],
  ['histórico duplicado',s=>s.history.push(s.history.at(-1))],
  ['hora sem fuso',s=>s.generated_at='2026-10-25T23:30:00'],
  ['data inexistente',s=>s.generated_at='2026-02-30T23:30:00Z']
];
for(const [name,mutate] of invalid)test(`rejeita ${name}`,()=>{const s=load('live-95');mutate(s);assert.throws(()=>validateSnapshot(s,config));});
test('identifica desatualização da fonte mesmo com modelo recente',()=>{const s=load('live-95');const now=timestamp(s.generated_at)+1000;s.counting.generated_at='2026-10-25T23:00:00Z';assert.equal(freshness(s,now,180000),'stale');});
test('demonstração nunca é apresentada como dado real desatualizado',()=>assert.equal(freshness(demo[0],Date.now()+1e12,1),'current'));
test('gráfico mantém só posições até o avanço corrente e corrige a última posição',()=>{const s=load('live-95');s.counting.reported_sections=5000;s.counting.votes_a=2500000;s.counting.votes_b=2500000;s.counting.valid_votes=5000000;const points=chartPoints(s);assert.ok(points.every(p=>p.x<=50));assert.deepEqual(points.at(-1),{x:50,a:50});});
test('histórico aceita projeção opcional e recusa faixa invertida ou incompleta',()=>{
  const s=load('live-95');Object.assign(s.history[0],{forecast_a:47.4,forecast_lower:42.9,forecast_upper:51.5});validateSnapshot(s,config);
  const inverted=load('live-95');Object.assign(inverted.history[0],{forecast_a:47.4,forecast_lower:51.5,forecast_upper:42.9});assert.throws(()=>validateSnapshot(inverted,config));
  const partial=load('live-95');Object.assign(partial.history[0],{forecast_a:47.4});assert.throws(()=>validateSnapshot(partial,config));
});
test('projeção do gráfico parte da priori e termina na previsão atual',()=>{
  const s=load('live-95');
  s.history.unshift({total_sections:10000,reported_sections:0,votes_a:0,votes_b:0,valid_votes:0,snapshot_id:'prior-1',generated_at:'2026-10-25T20:00:00Z',forecast_a:47.35,forecast_lower:43,forecast_upper:51.4},
    {total_sections:10000,reported_sections:0,votes_a:0,votes_b:0,valid_votes:0,snapshot_id:'prior-2',generated_at:'2026-10-25T20:01:00Z',forecast_a:47.36,forecast_lower:43,forecast_upper:51.4});
  Object.assign(s.history[2],{forecast_a:48,forecast_lower:44,forecast_upper:52});
  validateSnapshot(s,config);
  const points=projectionPoints(s);
  assert.deepEqual(points[0],{x:0,a:47.35,lower:43,upper:51.4});
  assert.deepEqual(points[1],{x:1,a:48,lower:44,upper:52});
  assert.deepEqual(points.at(-1),{x:65.2,a:51.4,lower:47.5,upper:55.3});
  assert.equal(points.length,3);
});
test('previsão sem aprendizado das seções apuradas é opcional e fica entre 0 e 100',()=>{
  const s=load('live-95');s.counting.prior_share_a=49.8;validateSnapshot(s,config);
  const bad=load('live-95');bad.counting.prior_share_a=120;assert.throws(()=>validateSnapshot(bad,config));
});
test('rótulos finais não se sobrepõem no empate ou em uma disputa muito próxima',()=>{for(const [a,b] of [[100,100],[100,101],[101,100]]){const [x,y]=separateLabelBaselines(a,b);assert.ok(Math.abs(x-y)>=22);}assert.deepEqual(separateLabelBaselines(80,120),[80,120]);});
const response=data=>({ok:true,status:200,text:async()=>JSON.stringify(data)});
function poller(fetcher,settings=config){const received=[],errors=[],timers=new Map();let id=0;const p=createPoller({url:'/data/latest.json',config:settings,onData:s=>received.push(s),onError:e=>errors.push(e),fetcher,schedule:f=>{timers.set(++id,f);return id;},cancel:i=>timers.delete(i)});return {p,received,errors,timers};}
test('não substitui dado válido por resposta inválida',async()=>{let i=0;const q=poller(async()=>response(i++?{}:load('live-95')));await q.p.start();await q.p.refresh();q.p.stop();assert.equal(q.received.length,1);assert.equal(q.errors.length,1);});
test('recusa demonstração no endpoint real',async()=>{const q=poller(async()=>response(demo[1]));await q.p.start();q.p.stop();assert.equal(q.received.length,0);assert.equal(q.errors.length,1);});
test('simulação integrada requer opção booleana explícita',()=>{validateConfig({...config,local_simulation:true});assert.throws(()=>validateConfig({...config,local_simulation:'true'}));});
test('consulta dados demo somente na simulação declarada',async()=>{const q=poller(async()=>response(demo[1]),{...config,local_simulation:true});await q.p.start();q.p.stop();assert.equal(q.received.length,1);assert.equal(q.errors.length,0);});
test('simulação não aceita dados reais',async()=>{const q=poller(async()=>response(load('live-95')),{...config,local_simulation:true});await q.p.start();q.p.stop();assert.equal(q.received.length,0);assert.equal(q.errors.length,1);});
test('recusa regressão temporal sem bloquear correção mais recente',async()=>{const old=load('live-95'),fresh=structuredClone(old);fresh.snapshot_id='novo';fresh.generated_at='2026-10-25T23:31:00Z';let i=0;const q=poller(async()=>response(i++?old:fresh));await q.p.start();await q.p.refresh();q.p.stop();assert.equal(q.received.length,1);assert.equal(q.errors.length,1);});
test('não faz consultas simultâneas',async()=>{let resolve,calls=0;const q=poller(()=>{calls++;return new Promise(r=>{resolve=r;});});const pending=q.p.start();await q.p.refresh();assert.equal(calls,1);resolve(response(load('waiting')));await pending;q.p.stop();});
test('timeout aborta e permite agendar nova tentativa',async()=>{const q=poller((url,{signal})=>new Promise((resolve,reject)=>signal.addEventListener('abort',()=>reject(new Error('timeout')))));const pending=q.p.start();[...q.timers.values()][0]();await pending;assert.equal(q.errors.length,1);assert.equal(q.timers.size,1);q.p.stop();});
test('ordem das chaves não altera identidade do conteúdo',async()=>{const s=load('live-95');let i=0;const q=poller(async()=>response(i++?Object.fromEntries(Object.entries(s).reverse()):s));await q.p.start();await q.p.refresh();q.p.stop();assert.equal(q.errors.length,0);});
test('falha HTTP não é interpretada como snapshot vazio',async()=>{await assert.rejects(()=>readJSON('/data/latest.json',{fetcher:async()=>({ok:false,status:503})}));});
test('dois cenários conservam previsões e faixas distintas',()=>{
  const s=load('live-95');s.forecast_2022=structuredClone(s.forecast);s.forecast_2022.share_a=48;
  s.forecast_2022.interval={level:.95,lower:45,upper:52};
  validateSnapshot(s,config);assert.equal(s.forecast_2022.share_a,48);assert.notEqual(s.forecast.share_a,48);
});
test('cenário 2022 rejeita origem, quantis e horário inconsistentes',()=>{
  for(const mutate of [f=>f.source_snapshot_id='outra',f=>f.interval.lower=99,f=>f.generated_at='2026-10-25T20:00:00Z',f=>f.posterior=[1]]){
    const s=load('live-95');s.forecast_2022=structuredClone(s.forecast);mutate(s.forecast_2022);
    assert.throws(()=>validateSnapshot(s,config));
  }
});
test('cenário 2022 requer previsão principal e não cabe no estado de espera',()=>{
  const s=load('waiting');s.forecast_2022=load('prior').forecast;
  assert.throws(()=>validateSnapshot(s,config));
});
test('priori antes da eleição permanece válida; após o início acusa atualização ausente',()=>{
  const s=load('prior'),start='2026-10-25T20:00:00Z';
  assert.equal(freshness(s,timestamp(start)-1,180000,start),'current');
  assert.equal(freshness(s,timestamp(start)+86400000,180000,start),'stale');
  assert.throws(()=>validateConfig({...config,counting_starts_at:'domingo'}));
});
