// A configuração precede o MathJax 4.1.3, carregado somente na página do modelo.
window.MathJax = {
  tex: {
    inlineMath: [['\\(', '\\)']],
    displayMath: [['\\[', '\\]']],
  },
  output: {
    displayAlign: 'left',
    displayOverflow: 'linebreak',
    linebreaks: {inline:true, width:'100%'},
  },
  startup: {typeset:false},
};

const mathjaxReady = new Promise((resolve,reject) => {
  const script = document.getElementById('mathjax-script');
  script.addEventListener('load', () => window.MathJax.startup.promise.then(resolve,reject), {once:true});
  script.addEventListener('error', reject, {once:true});
});
// A falha do CDN também pode ocorrer antes de alguém abrir um bloco.
mathjaxReady.catch(() => {});

// As equações precisam da largura real de cada bloco, depois de ele ser aberto.
const blocks = [...document.querySelectorAll('#modelo .pres-technical')].map(details => {
  const content = details.querySelector('.pres-technical-content');
  return {details, content, source:content.innerHTML, width:0};
});
let pending = Promise.resolve();
function typeset(block) {
  pending = pending.then(async () => {
    await mathjaxReady;
    if (!block.details.open) return;
    const width = block.content.getBoundingClientRect().width;
    if (!width || Math.abs(width-block.width)<1) return;
    if (block.width) {
      window.MathJax.typesetClear([block.content]);
      block.content.innerHTML = block.source;
    }
    await window.MathJax.typesetPromise([block.content]);
    block.width = width;
  }).catch(error => console.warn('Não foi possível renderizar as equações com MathJax.',error));
}
for (const block of blocks) {
  block.details.addEventListener('toggle', () => {if (block.details.open) typeset(block);});
  new ResizeObserver(() => {if (block.details.open) typeset(block);}).observe(block.content);
  if (block.details.open) typeset(block);
}
