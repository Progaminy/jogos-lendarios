self.addEventListener('install', (event) => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener('push', (event) => {
  let data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch {
    data = { message: event.data ? event.data.text() : '' };
  }

  const title = 'Jogos Lendários · ' + String(data.title || 'Notificação');
  const options = {
    body: String(data.message || ''),
    tag: String(data.id || ('notice:' + Date.now())),
    renotify: false,
    data: {
      id: String(data.id || ''),
      href: String(data.href || './index.html')
    }
  };

  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const data = event.notification.data || {};
  const originalHref = String(data.href || './index.html');

  const noticeId = String(data.id || '');
  let readingUrl = new URL('./index.html', self.location.origin);
  try {
    const target = new URL(originalHref, self.location.origin);
    if (target.origin === self.location.origin && target.pathname.endsWith('/ludo.html')) {
      readingUrl = new URL('./ludo.html', self.location.origin);
    }
  } catch {}

  // Abrir a notificação serve apenas para ler/destacar a mensagem.
  // O destino funcional (depósito, saque, jogo, suporte) continua separado
  // e só é aberto pelo botão explícito dentro do centro de notificações.
  if (noticeId) {
    readingUrl.searchParams.set('jl_notice', noticeId);
    readingUrl.hash = 'notifications';
  }

  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const client of windows) {
      if (!client.url.startsWith(self.location.origin)) continue;
      try {
        const clientUrl = new URL(client.url);
        if (clientUrl.pathname === readingUrl.pathname) {
          client.postMessage({
            type: 'jl-notification-open',
            id: noticeId,
            href: readingUrl.href
          });
          await client.focus();
          return;
        }

        if ('navigate' in client) {
          await client.navigate(readingUrl.href);
          await client.focus();
          return;
        }
      } catch {}
    }
    await self.clients.openWindow(readingUrl.href);
  })());
});
