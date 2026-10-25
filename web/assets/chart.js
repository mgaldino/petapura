import {share,progress,isComplete,isAwaitingCount} from './data.js';
const ns='http://www.w3.org/2000/svg';
const fmt=(v,d=1)=>v.toLocaleString('pt-BR',{minimumFractionDigits:d,maximumFractionDigits:d});
const fmtSections=v=>fmt(v,v>0&&v<1?2:1);
function add(parent,tag,attrs={},value){const n=document.createElementNS(ns,tag);for(const[k,v]of Object.entries(attrs))n.setAttribute(k,v);if(value!==undefined)n.textContent=value;parent.append(n);return n;}
const path=points=>points.map((p,i)=>`${i?'L':'M'}${p[0].toFixed(2)},${p[1].toFixed(2)}`).join(' ');
const label=(svg,x,y,value,anchor='middle',attrs={})=>add(svg,'text',{x,y,'text-anchor':anchor,...attrs},value);
export function separateLabelBaselines(a,b,gap=22){
  if(Math.abs(a-b)>=gap)return [a,b];const center=(a+b)/2;
  return a<=b?[center-gap/2,center+gap/2]:[center+gap/2,center-gap/2];
}
export function chartPoints(s){
  const current=progress(s.counting),points=new Map();
  for(const h of s.history){const a=share(h),x=progress(h);if(a!==null&&x<=current)points.set(x,{x,a});}
  if(share(s.counting)!==null)points.set(current,{x:current,a:share(s.counting)});
  return [...points.values()].sort((a,b)=>a.x-b.x);
}
// Projeção do resultado final em cada atualização, desde a previsão inicial (x = 0).
// Em x = 0 fica a primeira entrada, a priori; nas demais posições, a última revisão.
export function projectionPoints(s,scenario='learning'){
  const key=scenario==='2022'?'forecast_2022':'forecast',current=progress(s.counting),points=new Map();
  for(const h of s.history){
    const a=h[`${key}_a`],x=progress(h);
    if(a===undefined||x>current||(x===0&&points.has(0)))continue;
    points.set(x,{x,a,lower:h[`${key}_lower`],upper:h[`${key}_upper`]});
  }
  if(isComplete(s)){const a=share(s.counting);points.set(100,{x:100,a,lower:a,upper:a});}
  else if(s.forecast)points.set(current,{x:current,a:s.forecast.share_a,lower:s.forecast.interval.lower,upper:s.forecast.interval.upper});
  return [...points.values()].sort((a,b)=>a.x-b.x);
}
export function renderChart(svg,tooltip,s,visible=[true,true],scenario='learning'){
  const w=Math.floor(svg.getBoundingClientRect().width);if(w<1)return;
  const compact=w<500,h=compact?310:350,L=64,T=33,B=58,names=[s.candidates.a.name,s.candidates.b.name];
  svg.setAttribute('viewBox',`0 0 ${w} ${h}`);svg.replaceChildren();tooltip.hidden=true;
  const awaiting=isAwaitingCount(s),complete=isComplete(s),forecast=complete||awaiting?null:s.forecast,observed=awaiting?[]:chartPoints(s),projected=awaiting?[]:projectionPoints(s,scenario),current=awaiting?0:progress(s.counting);
  const finalA=awaiting?50:complete?share(s.counting):forecast?.share_a??null;
  const endText=i=>`${names[i]} ${fmt(i===0?finalA:100-finalA,awaiting?0:1)}%`;
  // A margem direita acompanha o rótulo final mais longo, medido com as duas séries para não deslocar o gráfico ao ocultar uma delas.
  let R=compact?12:84;if(!compact&&finalA!==null)for(const i of [0,1]){const n=label(svg,0,0,endText(i),'start');n.style.fontWeight='500';R=Math.max(R,Math.ceil(n.getComputedTextLength())+21);n.remove();}
  add(svg,'title',{id:'chart-svg-title'},awaiting?'Aguardando apuração: referência visual de 50% para cada candidatura':`Apuração e resultado final: ${names[0]} em vermelho e ${names[1]} em azul`);
  add(svg,'desc',{},awaiting?`As projeções ainda estão indisponíveis. A posição de 50% para ${names[0]} e 50% para ${names[1]} é apenas uma referência visual enquanto aguardamos urnas apuradas.`:complete?`Apuração concluída. ${names[0]}: ${fmt(finalA)}% e ${names[1]}: ${fmt(100-finalA)}% dos votos válidos.`:`Linhas contínuas mostram a projeção do resultado final ao longo da apuração, a partir da previsão inicial do modelo. ${forecast?`A projeção atual de ${names[0]} é ${fmt(finalA)}%, com faixa de ${fmt(forecast.interval.level*100,0)}%.`:'Ainda não há projeção disponível.'} A linha tracejada repete a projeção atual até o fim da apuração, sem prever o ritmo dos boletins.`);
  const all=[40,60,...projected.flatMap(p=>[p.lower,p.upper,100-p.lower,100-p.upper])];
  if(finalA!==null)all.push(finalA,100-finalA);
  const lo=Math.max(0,Math.floor(Math.min(...all)/5)*5),hi=Math.min(100,Math.ceil(Math.max(...all)/5)*5);
  const x=v=>L+v/100*(w-L-R),y=v=>T+(hi-v)/(hi-lo)*(h-T-B),end=x(100);
  const plot=add(svg,'g');add(plot,'rect',{'data-chart-frame':'',x:L,y:T,width:end-L,height:h-T-B,fill:'none',stroke:'var(--pres-rule)','stroke-width':.8});
  if(current<100)add(plot,'rect',{x:x(current),y:T,width:end-x(current),height:h-T-B,fill:'var(--pres-surface)',opacity:.65});
  label(svg,L,16,'Votos válidos (%)','start',{'class':'axis-title','data-axis':'y'});
  const ystep=hi-lo>35?10:5;
  for(let v=lo;v<=hi;v+=ystep){add(plot,'line',{x1:L,x2:end,y1:y(v),y2:y(v),stroke:v===50?'var(--pres-muted)':'var(--pres-rule)','stroke-width':v===50?1:.7});label(svg,L-9,y(v)+4,`${v}%`,'end');}
  for(const v of compact?[0,50,100]:[0,20,40,60,80,100])label(svg,x(v),h-B+23,`${v}%`,v===0?'start':v===100?'end':'middle');
  label(svg,(L+end)/2,h-8,'Seções apuradas (%)','middle',{'class':'axis-title','data-axis':'x'});
  if(!awaiting&&s.counting&&current<100){
    const now=x(current);add(plot,'line',{'data-now-guide':'',x1:now,x2:now,y1:T,y2:h-B,stroke:'var(--pres-muted)','stroke-width':1,'stroke-dasharray':'3 4'});
    const n=label(svg,now+8,T+15,'Agora','start',{'data-now-label':''});if(end-now<n.getComputedTextLength()+12){n.setAttribute('x',now-8);n.setAttribute('text-anchor','end');}
  }
  const colors=['var(--pres-a)','var(--pres-b)'];
  // Valores da candidatura i em um ponto da projeção; para B, a faixa é o complemento da de A.
  const seriesValue=(p,i)=>i===0?p.a:100-p.a,seriesLow=(p,i)=>i===0?p.lower:100-p.upper,seriesHigh=(p,i)=>i===0?p.upper:100-p.lower;
  for(let i=0;i<2;i++){
    if(!visible[i])continue;const c=colors[i],last=projected.at(-1),target=finalA==null?null:i===0?finalA:100-finalA;
    if(awaiting)add(plot,'path',{'data-waiting-reference':i,d:path([[L,y(50)],[end,y(50)]]),fill:'none',stroke:c,'stroke-width':2,'stroke-dasharray':'6 6','stroke-dashoffset':i*6});
    if(last){
      // A faixa acompanha o intervalo publicado em cada atualização e segue constante depois de "Agora".
      const band=[...projected,...(last.x<100?[{...last,x:100}]:[])];
      add(plot,'path',{'data-series-band':i,d:path([...band.map(p=>[x(p.x),y(seriesHigh(p,i))]),...band.slice().reverse().map(p=>[x(p.x),y(seriesLow(p,i))])])+' Z',fill:c,opacity:.13});
      if(projected.length>1)add(plot,'path',{'data-series-line':i,d:path(projected.map(p=>[x(p.x),y(seriesValue(p,i))])),fill:'none',stroke:c,'stroke-width':2.2});
      if(last.x<100)add(plot,'path',{'data-series-projection':i,d:path([[x(last.x),y(seriesValue(last,i))],[end,y(seriesValue(last,i))]]),fill:'none',stroke:c,'stroke-width':2.2,'stroke-dasharray':'4 4'});
      add(plot,'circle',{cx:x(last.x),cy:y(seriesValue(last,i)),r:3.2,fill:c});
      if(forecast)add(plot,'line',{x1:end,x2:end,y1:y(seriesLow(last,i)),y2:y(seriesHigh(last,i)),stroke:c,'stroke-width':2,opacity:.55});
    }
    if(target!==null){add(svg,'circle',{'data-series-end':i,cx:end,cy:y(target),r:3.6,fill:c});const n=label(svg,end+(compact?-7:9),y(target)+(compact?(i===0?-11:19):4),endText(i),compact?'end':'start',{'data-end-label':i});n.style.fill='var(--pres-ink)';n.style.fontWeight='500';}
  }
  if(!projected.length&&!awaiting)label(svg,(L+end)/2,(T+h-B)/2,'Aguardando projeção');
  const endLabels=[...svg.querySelectorAll('[data-end-label]')];
  if(!compact&&endLabels.length===2){const gap=Math.max(...endLabels.map(n=>n.getBBox().height))+4;const ys=separateLabelBaselines(...endLabels.map(n=>Number(n.getAttribute('y'))),gap);endLabels.forEach((n,i)=>n.setAttribute('y',ys[i]));}
  if(awaiting){svg.onkeydown=null;return;}
  const guide=add(plot,'line',{'data-chart-hover-guide':'',x1:L,x2:L,y1:T,y2:h-B,stroke:'var(--pres-muted)','stroke-width':1,visibility:'hidden'});
  const dots=colors.map(c=>add(plot,'circle',{'data-chart-hover-marker':'',r:3.5,fill:c,visibility:'hidden'}));
  const overlay=add(plot,'rect',{'data-chart-hit':'','data-chart-hover-overlay':'cross-series',x:L,y:T,width:end-L,height:h-T-B,fill:'transparent'});
  let pinned=false;
  const hide=()=>{tooltip.hidden=true;guide.setAttribute('visibility','hidden');dots.forEach(n=>n.setAttribute('visibility','hidden'));};
  function show(event){
    const r=svg.getBoundingClientRect(),px=Math.max(L,Math.min(end,(event.clientX-r.left)*w/r.width)),count=(px-L)/(end-L)*100;
    guide.setAttribute('x1',px);guide.setAttribute('x2',px);guide.setAttribute('visibility','visible');tooltip.replaceChildren();
    const heading=document.createElement('div');heading.className='pres-tooltip-heading';tooltip.append(heading);
    let a=null,future=count>current,counted=null;
    // Posição registrada mais próxima à esquerda do cursor; não interpola entre atualizações.
    const at=points=>points.filter(p=>p.x<=count).at(-1);
    if(future&&forecast){heading.textContent='Projeção atual do resultado final';a=forecast.share_a;}
    else if(projected.length&&count>=projected[0].x){const p=at(projected);a=p.a;counted=at(observed)?.a??null;heading.textContent=`${fmtSections(p.x)}% das seções · projeção`;}
    else heading.textContent='Sem projeção neste ponto.';
    visible.forEach((on,i)=>{
      dots[i].setAttribute('visibility',on&&a!==null&&!future?'visible':'hidden');if(!on||a===null)return;
      const value=i===0?a:100-a;if(!future){dots[i].setAttribute('cx',px);dots[i].setAttribute('cy',y(value));}
      const row=document.createElement('div');row.className='pres-tooltip-row';const name=document.createElement('span');const swatch=document.createElement('i');swatch.style.setProperty('--pres-series',colors[i]);name.append(swatch,document.createTextNode(names[i]));const val=document.createElement('b');val.textContent=`${fmt(value)}%`;row.append(name,val);tooltip.append(row);
    });
    if(counted!==null){const row=document.createElement('div');row.className='pres-tooltip-row';const name=document.createElement('span');name.textContent=`Apurado até aqui: ${names[0]}`;const val=document.createElement('b');val.textContent=`${fmt(counted)}%`;row.append(name,val);tooltip.append(row);}
    tooltip.hidden=false;tooltip.style.left=`${Math.max(4,Math.min(w-tooltip.offsetWidth-4,px+10))}px`;tooltip.style.top='35px';
  }
  overlay.onpointermove=e=>{if(!pinned)show(e);};overlay.onpointerleave=()=>{if(!pinned)hide();};overlay.onclick=e=>{pinned=!pinned;if(pinned)show(e);else hide();};
  svg.onkeydown=e=>{if(e.key==='Escape'){pinned=false;hide();}};
}
