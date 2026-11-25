/* Culling Bay on a computer. Every page (/m/, the gallery, Practice) loads this first, in <head>.
   - A phone or tablet gets a short page that points to the iPhone app and its builds (/m/ios/),
     not the app: the web pages are for a computer beside Lightroom. Touch-first means no hover
     and a coarse pointer, or a phone or tablet in the user agent. The pages' own scripts see
     window.cbPhone and do nothing.
   - Anything else gets the desktop layout (html.wide, desktop.css).
   - A service worker from an older version (it could only register on localhost or https) is
     taken away, with its caches. */
(() => {
  'use strict';
  const sw = navigator.serviceWorker;
  if (sw) sw.getRegistrations().then(rs => rs.forEach(r => { if (/\/m\/$/.test(r.scope)) r.unregister(); })).catch(() => {});
  if (window.caches) caches.keys().then(ks => ks.forEach(k => { if (k.startsWith('cbm-shell')) caches.delete(k); })).catch(() => {});

  const touchFirst = matchMedia('(hover: none) and (pointer: coarse)').matches ||
    /iPhone|iPad|iPod|Android|Mobile/i.test(navigator.userAgent);
  const root = document.documentElement;
  if (!touchFirst) {
    root.classList.add('wide');
    return;
  }
  window.cbPhone = true;
  root.classList.add('phone');
  const style = document.createElement('style');
  style.textContent =
    'html.phone,html.phone body{height:auto;min-height:100%;min-width:0;margin:0;background:#0C0D0E;color:#F2F3F4;overflow:auto}' +
    'html.phone body>:not(.cb-phone){display:none!important}' +
    '.cb-phone{box-sizing:border-box;max-width:30rem;margin:0 auto;padding:max(48px,env(safe-area-inset-top)) 24px 32px;' +
    'font:400 17px/1.5 system-ui,-apple-system,sans-serif;display:grid;gap:14px;justify-items:start}' +
    '.cb-phone img{width:72px;height:72px;border-radius:16px}' +
    '.cb-phone h1{margin:6px 0 0;font:800 28px/1.15 system-ui,-apple-system,sans-serif}' +
    '.cb-phone p{margin:0;color:#C9CDD2}' +
    '.cb-phone .cb-get{justify-self:stretch;margin-top:8px;padding:16px;border-radius:14px;background:#93B4FF;color:#0B1020;' +
    'font-weight:700;text-align:center;text-decoration:none}' +
    '.cb-phone .cb-small{font-size:14px;color:#9BA1A8}';
  document.head.append(style);
  const show = () => {
    document.title = 'Culling Bay';
    document.body.innerHTML = '<main class="cb-phone">' +
      '<img src="/m/apple-touch-icon.png" alt="">' +
      '<h1>On the iPhone, Culling Bay is the app</h1>' +
      '<p>These pages are for a computer, beside Lightroom. On the phone, cull, search and practise in the Culling Bay app.</p>' +
      '<a class="cb-get" href="/m/ios/">Install or update the app</a>' +
      '<p class="cb-small">The builds page has the newest build: download it, then Share → SideStore.</p></main>';
  };
  if (document.body) show(); else document.addEventListener('DOMContentLoaded', show);
})();
