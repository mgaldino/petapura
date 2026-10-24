// O token do beacon é público. Credenciais da conta nunca vão para o navegador.
export function attachAnalytics(config) {
  const token = config.cloudflare_web_analytics_token;
  if (!token || !/^[a-f0-9]{32}$/i.test(token)) return;
  if (['localhost', '127.0.0.1', '[::1]'].includes(location.hostname) ||
      new URLSearchParams(location.search).get('demo') === '1') return;
  if (document.querySelector('script[data-cf-beacon]')) return;
  const script = document.createElement('script');
  script.type = 'module';
  script.defer = true;
  script.src = 'https://static.cloudflareinsights.com/beacon.min.js';
  script.dataset.cfBeacon = JSON.stringify({token});
  document.head.append(script);
}
