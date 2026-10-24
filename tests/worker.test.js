import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import worker from '../worker/index.js';

function snapshot() {
  const s=JSON.parse(readFileSync(new URL('fixtures/live-95.json',import.meta.url)));
  s.forecast_2022=structuredClone(s.forecast);
  s.forecast_2022.share_a=48;
  return s;
}
const request=()=>new Request('https://example.workers.dev/data/latest.json');
const assets=s=>({fetch:async()=>new Response(JSON.stringify(s))});

test('Workers entrega dois cenários sem cache HTTP',async()=>{
  const s=snapshot(),env={SNAPSHOTS:{get:async()=>JSON.stringify(s)},ASSETS:assets({})};
  const result=await worker.fetch(request(),env);
  assert.equal(result.status,200);assert.equal(result.headers.get('Cache-Control'),'no-store');
  assert.deepEqual(await result.json(),s);
});
test('Workers começa com a prior publicada nos assets quando KV ainda está vazio',async()=>{
  const s=snapshot(),env={SNAPSHOTS:{get:async()=>null},ASSETS:assets(s)};
  assert.deepEqual(await (await worker.fetch(request(),env)).json(),s);
});
test('falha do KV e snapshot inválido devolvem 503 sem trocar por uma prior antiga',async()=>{
  for(const read of [async()=>{throw new Error('rede');},async()=>JSON.stringify({}),async()=>JSON.stringify({...snapshot(),mode:'demo'})]){
    const result=await worker.fetch(request(),{SNAPSHOTS:{get:read},ASSETS:assets(snapshot())});
    assert.equal(result.status,503);
  }
});
test('snapshot sem segundo cenário ou de outra eleição é recusado',async()=>{
  const missing=snapshot();delete missing.forecast_2022;
  const foreign=snapshot();foreign.election.election_id='outra';
  for(const s of [missing,foreign])assert.equal((await worker.fetch(request(),{SNAPSHOTS:{get:async()=>JSON.stringify(s)},ASSETS:assets({})})).status,503);
});
test('endpoint é somente leitura e HEAD não contém corpo',async()=>{
  const env={SNAPSHOTS:{get:async()=>JSON.stringify(snapshot())},ASSETS:assets({})};
  assert.equal((await worker.fetch(new Request(request(),{method:'POST'}),env)).status,405);
  const head=await worker.fetch(new Request(request(),{method:'HEAD'}),env);
  assert.equal(head.status,200);assert.equal(await head.text(),'');
});
test('demais endereços continuam servidos pelos assets',async()=>{
  const response=new Response('site');
  const result=await worker.fetch(new Request('https://example.workers.dev/'),{ASSETS:{fetch:async()=>response}});
  assert.equal(result,response);
});
