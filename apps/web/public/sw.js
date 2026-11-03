/* سَرى البارق — service worker. Push notifications only: no fetch handler and
 * no caching, so it never serves a stale app. Positions are never pushed; a
 * push carries a note or an SOS for an outing the person is a member of. */

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));

self.addEventListener('push', (event) => {
  let data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch {
    data = { body: event.data ? event.data.text() : '' };
  }
  const sos = data.type === 'sos';
  const url = typeof data.url === 'string' && data.url.startsWith('/') ? data.url : '/outings';
  /* iOS requires every push to show a notification, so there is always one. */
  event.waitUntil(
    self.registration.showNotification(data.title || 'سَرى البارق', {
      body: data.body || '',
      tag: data.tag || (sos ? 'sary-sos' : 'sary-note'),
      renotify: true,
      requireInteraction: sos,
      lang: 'ar',
      dir: 'rtl',
      icon: '/icons/icon-192.png',
      badge: '/icons/icon-192.png',
      vibrate: sos ? [300, 120, 300, 120, 600] : [140, 70, 140],
      data: { url, type: data.type || null, outing_id: data.outing_id || null },
    }),
  );
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const url = new URL((event.notification.data && event.notification.data.url) || '/outings', self.location.origin);
  event.waitUntil(
    (async () => {
      const wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
      /* Prefer a window already on that outing, then any window of the app. */
      const exact = wins.find((w) => new URL(w.url).pathname === url.pathname);
      if (exact) return exact.focus();
      const any = wins.find((w) => new URL(w.url).origin === url.origin);
      if (any && any.navigate) {
        try {
          await any.focus();
          return await any.navigate(url.href);
        } catch {
          /* an uncontrolled window cannot be navigated from here: open a new one */
        }
      }
      return self.clients.openWindow(url.href);
    })(),
  );
});
