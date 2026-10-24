import {validateSnapshot} from '../web/assets/data.js';

const identity = {
  expected_election: {year:2026,round:2,office:'president',election_id:'6258',pleito_id:'3221'},
  expected_candidates: {a:'13',b:'22'}
};

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname !== '/data/latest.json') return env.ASSETS.fetch(request);
    if (!['GET','HEAD'].includes(request.method)) return new Response(null,{status:405,headers:{Allow:'GET, HEAD'}});
    try {
      // Um único escritor autenticado pelo Wrangler. Nenhum endpoint público de escrita.
      const stored = await env.SNAPSHOTS.get('latest', {type:'text',cacheTtl:30});
      const raw = stored ?? await (await env.ASSETS.fetch(new Request(new URL('/data/latest.json',url)))).text();
      if (raw.length > 2_000_000) throw new Error('Snapshot excede o contrato');
      const snapshot = validateSnapshot(JSON.parse(raw),identity);
      if (snapshot.mode !== 'live' || !snapshot.forecast || !snapshot.forecast_2022) throw new Error('Produção exige dois cenários reais');
      return new Response(request.method==='HEAD'?null:JSON.stringify(snapshot),{headers:{
        'Content-Type':'application/json; charset=utf-8',
        'Cache-Control':'no-store',
        'X-Content-Type-Options':'nosniff'
      }});
    } catch {
      // Em falha de leitura, o navegador conserva o último resultado válido.
      return new Response(JSON.stringify({error:'Resultados temporariamente indisponíveis'}),{
        status:503,headers:{'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store'}
      });
    }
  }
};
