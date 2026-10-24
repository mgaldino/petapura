import test from 'node:test';
import assert from 'node:assert/strict';
import {attachAnalytics} from '../web/assets/analytics.js';

function page(t,hostname='site.workers.dev',search='') {
  const saved={location:globalThis.location,document:globalThis.document},scripts=[];
  globalThis.location={hostname,search};
  globalThis.document={querySelector:()=>scripts[0]||null,createElement:()=>({dataset:{}}),head:{append:s=>scripts.push(s)}};
  t.after(()=>{for(const [key,value] of Object.entries(saved)){if(value===undefined)delete globalThis[key];else globalThis[key]=value;}});
  return scripts;
}
const config={cloudflare_web_analytics_token:'a'.repeat(32)};
test('beacon oficial é incluído uma única vez com token público',t=>{
  const scripts=page(t);attachAnalytics(config);attachAnalytics(config);
  assert.equal(scripts.length,1);assert.equal(scripts[0].src,'https://static.cloudflareinsights.com/beacon.min.js');
  assert.equal(scripts[0].type,'module');
  assert.equal(JSON.parse(scripts[0].dataset.cfBeacon).token,config.cloudflare_web_analytics_token);
});
test('localhost e demonstração não geram tracking',t=>{
  const scripts=page(t,'localhost');attachAnalytics(config);assert.equal(scripts.length,0);
  globalThis.location={hostname:'site.workers.dev',search:'?demo=1'};attachAnalytics(config);assert.equal(scripts.length,0);
});
test('token ausente ou inválido mantém analytics desativado',t=>{
  const scripts=page(t);attachAnalytics({});attachAnalytics({cloudflare_web_analytics_token:'inválido'});assert.equal(scripts.length,0);
});
