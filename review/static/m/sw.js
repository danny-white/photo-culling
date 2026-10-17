/* Culling Bay Mobile service worker: keeps the app shell available offline. Photos and API
   calls always go to the server (the app's own queue handles saving while offline). Browsers
   only run service workers over HTTPS, so this does nothing on plain http. */
const SHELL = 'cbm-shell-v2';
const FILES = ['/m/', '/m/app.css', '/m/app.js', '/m/perf-client.js', '/m/manifest.webmanifest', '/m/icon-192.png', '/m/apple-touch-icon.png'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(SHELL).then(c => c.addAll(FILES)));
  self.skipWaiting();
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== SHELL).map(k => caches.delete(k)))));
  self.clients.claim();
});
self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);
  if (e.request.method !== 'GET' || url.pathname.startsWith('/m/api/')) return;
  // Network first, so a new build shows up on the next open; the cached shell when offline.
  e.respondWith(fetch(e.request).then(r => {
    if (r.ok) { const copy = r.clone(); caches.open(SHELL).then(c => c.put(e.request, copy)); }
    return r;
  }).catch(() => caches.match(e.request, { ignoreSearch: true })));
});
