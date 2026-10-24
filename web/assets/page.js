import {attachAnalytics} from './analytics.js';

// As páginas de conteúdo usam o mesmo analytics, sem consultar a apuração.
try {
  const response = await fetch('/config.json', {signal:AbortSignal.timeout(10000)});
  if (response.ok) attachAnalytics(await response.json());
} catch {
  // A leitura do conteúdo continua disponível se o analytics não carregar.
}
