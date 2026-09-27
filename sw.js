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

  let readingHref = new URL('./index.html', self.location.origin).href;
  try {
    const target = new URL(originalHref, self.location.origin);
    if (target.pathname.endsWith('/ludo.html')) {
      readingHref = new URL('./ludo.html', self.location.origin).href;
    }
  } catch {}

  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const client of windows) {
      if (!client.url.startsWith(self.location.origin)) continue;
      try {
        client.postMessage({
          type: 'jl-notification-open',
          id: String(data.id || ''),
          href: readingHref
        });
        await client.focus();
        if ('navigate' in client && new URL(client.url).pathname !== new URL(readingHref).pathname) {
          await client.navigate(readingHref);
        }
        return;
      } catch {}
    }
    await self.clients.openWindow(readingHref);
  })());
});
