import {readJSON} from './data.js';

// Carregado somente quando o servidor local declara a simulação explicitamente.
export function attachSimulation({refresh}) {
  const label=document.getElementById('simulation-status');
  let lastSnapshot=null,stopped=false,timer=null;
  label.hidden=false;
  function render(s){
    label.textContent=s.error?'A atualização da simulação foi interrompida. Exibindo os últimos dados recebidos.':s.complete?'Simulação concluída.':'Simulação em andamento · atualização automática.';
    if(s.snapshot_id&&s.snapshot_id!==lastSnapshot){lastSnapshot=s.snapshot_id;refresh();}
  }
  async function poll(){
    if(stopped)return;
    try{render(await readJSON('./api/status',{signal:AbortSignal.timeout(10000)}));}
    catch{label.textContent='Sem conexão com o servidor local. Mantenha o comando da simulação em execução.';}
    if(!stopped)timer=setTimeout(poll,1000);
  }
  function stop(){stopped=true;clearTimeout(timer);}
  window.addEventListener('pagehide',stop);
  window.addEventListener('pageshow',event=>{if(event.persisted){stopped=false;poll();}});
  poll();
}
