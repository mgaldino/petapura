export class DataError extends Error {}
const fail = path => { throw new DataError(`Dado inválido: ${path}`); };
const object = (v, p) => { if (!v || typeof v !== 'object' || Array.isArray(v)) fail(p); };
const number = (v, p, min=0, max=100) => { if (typeof v !== 'number' || !Number.isFinite(v) || v<min || v>max) fail(p); };
const count = (v,p) => { if (!Number.isSafeInteger(v) || v<0) fail(p); };
const string = (v,p,max=120) => { if (typeof v!=='string' || !v.trim() || v.length>max) fail(p); };
const keys=(v,allowed,p,optional=[])=>{object(v,p);if(Object.keys(v).some(k=>!allowed.includes(k))||allowed.some(k=>!optional.includes(k)&&!Object.hasOwn(v,k)))fail(`${p}.campos`);};
const stable=v=>JSON.stringify(v,(_,x)=>x&&typeof x==='object'&&!Array.isArray(x)?Object.fromEntries(Object.entries(x).sort(([a],[b])=>a.localeCompare(b))):x);
export function timestamp(v,p='generated_at') {
  if (typeof v!=='string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$/.test(v)) fail(p);
  const t=Date.parse(v); if (!Number.isFinite(t) || new Date(t).toISOString().slice(0,19)!==v.slice(0,19)) fail(p);
  return t;
}
function counts(c,p) {
  object(c,p);
  for (const key of ['total_sections','reported_sections','votes_a','votes_b','valid_votes']) count(c[key],`${p}.${key}`);
  if (c.total_sections<1 || c.reported_sections>c.total_sections || c.votes_a+c.votes_b!==c.valid_votes || (!c.reported_sections && c.valid_votes)) fail(p);
  if (c.collected_sections!=null) {count(c.collected_sections,`${p}.collected_sections`);if(c.collected_sections>c.total_sections)fail(p);}
}
export function validateSnapshot(s,config={}) {
  object(s,'snapshot'); if(s.version!==1) fail('version');
  keys(s,['version','snapshot_id','source_snapshot_id','generated_at','mode','election','candidates','counting','forecast','history'],'snapshot');
  string(s.snapshot_id,'snapshot_id');
  if(!['waiting','live','demo'].includes(s.mode))fail('mode');
  if(s.generated_at!==null)timestamp(s.generated_at);else if(s.mode!=='waiting')fail('generated_at');
  if(s.mode!=='waiting')string(s.source_snapshot_id,'source_snapshot_id');
  object(s.election,'election');
  keys(s.election,['year','round','office','election_id','pleito_id'],'election');string(s.election.election_id,'election.election_id');string(s.election.pleito_id,'election.pleito_id');
  if(s.election.year!==2026 || s.election.round!==2 || s.election.office!=='president')fail('election');
  for(const [key,value] of Object.entries(config.expected_election||{}))if(s.election[key]!==value)fail(`election.${key}`);
  object(s.candidates,'candidates');
  keys(s.candidates,['a','b'],'candidates');for(const slot of ['a','b'])keys(s.candidates[slot],['id','name'],`candidates.${slot}`);
  for(const key of ['a','b']){object(s.candidates[key],`candidates.${key}`);string(s.candidates[key].id,`candidates.${key}.id`);string(s.candidates[key].name,`candidates.${key}.name`,80);if(config.expected_candidates?.[key] && config.expected_candidates[key]!==s.candidates[key].id)fail(`candidates.${key}.id`);}
  if(s.candidates.a.id===s.candidates.b.id)fail('candidates');
  if(s.counting!==null){keys(s.counting,['total_sections','reported_sections','collected_sections','votes_a','votes_b','valid_votes','generated_at','source'],'counting',['collected_sections']);counts(s.counting,'counting');timestamp(s.counting.generated_at,'counting.generated_at');if(timestamp(s.counting.generated_at)>timestamp(s.generated_at))fail('counting.generated_at');keys(s.counting.source,['name','area','generated_raw'],'counting.source',['generated_raw']);string(s.counting.source.name,'counting.source.name');if(!(s.mode==='demo'?['DEMO']:['BR','SOMA_UFS']).includes(s.counting.source.area))fail('counting.source.area');if(s.counting.source.generated_raw!=null)string(s.counting.source.generated_raw,'counting.source.generated_raw');}
  if(s.forecast!==null){
    const f=s.forecast;object(f,'forecast');number(f.share_a,'forecast.share_a');string(f.model_version,'forecast.model_version');timestamp(f.generated_at,'forecast.generated_at');string(f.source_snapshot_id,'forecast.source_snapshot_id');
    keys(f,['model_version','source_snapshot_id','generated_at','share_a','interval','win_probability_a','notes'],'forecast');keys(f.interval,['level','lower','upper'],'forecast.interval');
    if(f.source_snapshot_id!==s.source_snapshot_id)fail('forecast.source_snapshot_id');
    object(f.interval,'forecast.interval');number(f.interval.level,'forecast.interval.level',0.01,.999);number(f.interval.lower,'forecast.interval.lower');number(f.interval.upper,'forecast.interval.upper');if(f.interval.lower>f.interval.upper)fail('forecast.interval');
    if(f.win_probability_a!==null)number(f.win_probability_a,'forecast.win_probability_a',0,1);
    if(!Array.isArray(f.notes) || f.notes.length>10 || f.notes.some(x=>typeof x!=='string'||x.length>1000))fail('forecast.notes');
    if(timestamp(f.generated_at)>timestamp(s.generated_at))fail('forecast.generated_at');
  }
  if(!Array.isArray(s.history)||s.history.length>4000)fail('history');
  let last=-Infinity;const ids=new Set();
  for(const [i,h] of s.history.entries()){keys(h,['snapshot_id','generated_at','total_sections','reported_sections','votes_a','votes_b','valid_votes'],`history[${i}]`);counts(h,`history[${i}]`);string(h.snapshot_id,`history[${i}].snapshot_id`);const t=timestamp(h.generated_at,`history[${i}].generated_at`);if(t<last||ids.has(h.snapshot_id)||s.generated_at===null||t>timestamp(s.generated_at))fail(`history[${i}]`);last=t;ids.add(h.snapshot_id);}
  if(s.mode==='waiting' && (s.source_snapshot_id!==null||s.forecast!==null||s.counting!==null||s.history.length))fail('waiting');
  return s;
}
export const share = c => c?.valid_votes>0 ? 100*c.votes_a/c.valid_votes : null;
export const progress = c => c ? 100*c.reported_sections/c.total_sections : 0;
export const isComplete = s => Boolean(s.counting?.valid_votes>0 && s.counting.reported_sections===s.counting.total_sections);
export function freshness(s,now,staleAfter) {
  if(s.mode!=='live'||!s.generated_at)return 'current';
  const times=[s.generated_at,s.counting?.generated_at,s.forecast?.generated_at].filter(Boolean).map(v=>timestamp(v));
  return times.some(t=>now-t>staleAfter) ? 'stale' : 'current';
}
export async function readJSON(url,{signal,fetcher=fetch}={}) {
  const response=await fetcher(url,{cache:'no-store',signal,headers:{Accept:'application/json'}});
  if(!response.ok)throw new DataError(`Resposta HTTP ${response.status}`);
  const text=await response.text();if(text.length>2_000_000)throw new DataError('Resposta excede 2 MB');
  try{return JSON.parse(text);}catch{throw new DataError('Resposta JSON inválida');}
}
export function validateConfig(c){
  object(c,'config');for(const key of ['endpoint','demo_endpoint']){string(c[key],key,2048);const u=new URL(c[key],globalThis.location?.href||'http://localhost/');if(!['http:','https:'].includes(u.protocol)||u.username||u.password)fail(key);}
  number(c.poll_interval_ms,'poll_interval_ms',5000,600000);number(c.request_timeout_ms,'request_timeout_ms',1000,60000);number(c.stale_after_ms,'stale_after_ms',c.poll_interval_ms,86400000);
  object(c.expected_election,'expected_election');object(c.expected_candidates,'expected_candidates');for(const k of ['a','b'])string(c.expected_candidates[k],`expected_candidates.${k}`);return c;
}
export function createPoller({url,config,onData,onError,onLoading=()=>{},fetcher=fetch,schedule=setTimeout,cancel=clearTimeout}) {
  let stopped=true,timer=null,controller=null,busy=false,last=null;
  async function refresh(){
    if(stopped||busy)return;busy=true;onLoading();controller=new AbortController();
    const timeout=schedule(()=>controller?.abort(),config.request_timeout_ms);
    try{const data=validateSnapshot(await readJSON(url,{signal:controller.signal,fetcher}),config);if(!stopped){if(data.mode==='demo')throw new DataError('Endpoint real recebeu dados de demonstração');if(last?.generated_at&&(!data.generated_at||timestamp(data.generated_at)<timestamp(last.generated_at)))throw new DataError('Snapshot anterior ao último recebido');if(last?.snapshot_id===data.snapshot_id&&stable(last)!==stable(data))throw new DataError('Snapshot alterado sem nova identidade');last=data;onData(data);}}
    catch(error){if(!stopped)onError(error);}
    finally{cancel(timeout);busy=false;controller=null;if(!stopped)timer=schedule(refresh,config.poll_interval_ms);}
  }
  return {start(){if(!stopped)return;stopped=false;return refresh();},refresh(){if(timer!==null){cancel(timer);timer=null;}return refresh();},stop(){stopped=true;cancel(timer);controller?.abort();}};
}
