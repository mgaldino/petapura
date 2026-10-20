import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {validateSnapshot,validateConfig,share,progress,isComplete,freshness,createPoller,readJSON,timestamp} from '../web/assets/data.js';
import {chartPoints,separateLabelBaselines} from '../web/assets/chart.js';
const load=name=>JSON.parse(readFileSync(new URL(`fixtures/${name}.json`,import.meta.url)));
const config=JSON.parse(readFileSync(new URL('../web/config.json',import.meta.url)));
const demo=JSON.parse(readFileSync(new URL('../web/demo/snapshots.json',import.meta.url)));
for(const name of ['waiting','live-95','prior','complete'])test(`contrato aceita ${name}`,()=>validateSnapshot(load(name),config));
test('demonstração tem três momentos coerentes',()=>{for(const s of demo)validateSnapshot(s,config);assert.equal(progress(demo[1].counting),65.2);assert.equal(share(demo[1].counting),49.6);});
test('95% permanece 95%; probabilidade ausente permanece nula',()=>{const s=validateSnapshot(load('live-95'),config);assert.equal(s.forecast.interval.level,.95);assert.equal(s.forecast.win_probability_a,null);});
test('previsão existe antes do primeiro BU',()=>{const s=load('prior');assert.equal(progress(s.counting),0);assert.equal(share(s.counting),null);assert.ok(s.forecast);});
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
test('rótulos finais não se sobrepõem no empate ou em uma disputa muito próxima',()=>{for(const [a,b] of [[100,100],[100,101],[101,100]]){const [x,y]=separateLabelBaselines(a,b);assert.ok(Math.abs(x-y)>=22);}assert.deepEqual(separateLabelBaselines(80,120),[80,120]);});
const response=data=>({ok:true,status:200,text:async()=>JSON.stringify(data)});
function poller(fetcher){const received=[],errors=[],timers=new Map();let id=0;const p=createPoller({url:'/data/latest.json',config,onData:s=>received.push(s),onError:e=>errors.push(e),fetcher,schedule:f=>{timers.set(++id,f);return id;},cancel:i=>timers.delete(i)});return {p,received,errors,timers};}
test('não substitui dado válido por resposta inválida',async()=>{let i=0;const q=poller(async()=>response(i++?{}:load('live-95')));await q.p.start();await q.p.refresh();q.p.stop();assert.equal(q.received.length,1);assert.equal(q.errors.length,1);});
test('recusa demonstração no endpoint real',async()=>{const q=poller(async()=>response(demo[1]));await q.p.start();q.p.stop();assert.equal(q.received.length,0);assert.equal(q.errors.length,1);});
test('recusa regressão temporal sem bloquear correção mais recente',async()=>{const old=load('live-95'),fresh=structuredClone(old);fresh.snapshot_id='novo';fresh.generated_at='2026-10-25T23:31:00Z';let i=0;const q=poller(async()=>response(i++?old:fresh));await q.p.start();await q.p.refresh();q.p.stop();assert.equal(q.received.length,1);assert.equal(q.errors.length,1);});
test('não faz consultas simultâneas',async()=>{let resolve,calls=0;const q=poller(()=>{calls++;return new Promise(r=>{resolve=r;});});const pending=q.p.start();await q.p.refresh();assert.equal(calls,1);resolve(response(load('waiting')));await pending;q.p.stop();});
test('timeout aborta e permite agendar nova tentativa',async()=>{const q=poller((url,{signal})=>new Promise((resolve,reject)=>signal.addEventListener('abort',()=>reject(new Error('timeout')))));const pending=q.p.start();[...q.timers.values()][0]();await pending;assert.equal(q.errors.length,1);assert.equal(q.timers.size,1);q.p.stop();});
test('ordem das chaves não altera identidade do conteúdo',async()=>{const s=load('live-95');let i=0;const q=poller(async()=>response(i++?Object.fromEntries(Object.entries(s).reverse()):s));await q.p.start();await q.p.refresh();q.p.stop();assert.equal(q.errors.length,0);});
test('falha HTTP não é interpretada como snapshot vazio',async()=>{await assert.rejects(()=>readJSON('/data/latest.json',{fetcher:async()=>({ok:false,status:503})}));});
