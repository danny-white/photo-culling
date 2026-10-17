/* Timing from the phone, for review/perf.py. Two kinds of measurement go to /m/api/perf:
   - every request to /m/api/: how long it took as seen from the phone, split into waiting
     (queued in the browser, which opens only about 6 connections to one server), first byte
     (the server's work plus the round trip over Tailscale) and download; its size, whether the
     browser answered it from its own cache, and the server's own time from Server-Timing;
   - moments you feel, marked by the pages with cbPerf.mark(type, ms, extra): a photo
     appearing after a decision, a swipe in the viewer, a day opening.
   Sent in batches every 15 s and when the page is hidden. Never blocks the page; if sending
   fails the batch is dropped. */
'use strict';
(function () {
  const queue = [];
  const MAX = 400;
  const add = item => { if (queue.length < MAX) queue.push(item); };

  function mark(type, ms, extra) {
    if (!(ms >= 0)) return;
    add(Object.assign({ type, ms: Math.round(ms * 10) / 10 }, extra || {}));
  }

  function fromEntry(e) {
    let u;
    try { u = new URL(e.name); } catch { return; }
    if (u.origin !== location.origin || !u.pathname.startsWith('/m/api/') || u.pathname === '/m/api/perf') return;
    const total = (e.serverTiming || []).find(t => t.name === 'total');
    // Safari gives no detail (responseStart 0) for a picture it already holds in memory
    const hidden = !(e.responseStart > 0);
    const cached = (e.transferSize === 0 && e.decodedBodySize > 0) || (hidden && e.duration < 5);
    const item = { type: 'fetch', name: (u.pathname + u.search).slice(0, 300), ms: e.duration,
                   bytes: e.encodedBodySize || 0, detail: cached ? 'browser-cache' : 'network' };
    if (total) item.server_ms = total.duration;
    if (!hidden && e.requestStart > 0) {   // detailed timing, when the browser exposes it
      item.wait_ms = e.requestStart - e.startTime;
      item.ttfb_ms = e.responseStart - e.requestStart;
      item.dl_ms = e.responseEnd - e.responseStart;
    }
    mark('fetch', e.duration, item);
  }

  try {
    performance.setResourceTimingBufferSize(1000);
    performance.addEventListener('resourcetimingbufferfull', () => performance.clearResourceTimings());
    new PerformanceObserver(list => list.getEntries().forEach(fromEntry)).observe({ type: 'resource', buffered: true });
  } catch { /* an old browser: only the page's own marks are sent */ }

  function flush() {
    if (!queue.length) return;
    const items = queue.splice(0, queue.length);
    fetch('/m/api/perf', { method: 'POST', keepalive: true,
      headers: { 'Content-Type': 'application/json', 'X-Culling-Bay': '1' },
      body: JSON.stringify({ items: items.slice(0, 300) }) }).catch(() => {});
  }
  setInterval(flush, 15000);
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'hidden') flush(); });

  window.cbPerf = { mark, flush };
})();
