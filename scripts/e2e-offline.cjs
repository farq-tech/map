/**
 * «حفظ المنطقة دون اتصال» end to end, with the network really gone.
 *
 *   npm run build && (cd apps/web && npx vite preview --port 5194)
 *   NODE_PATH=<dir with playwright> node scripts/e2e-offline.cjs [--base http://127.0.0.1:5194] [--shots dir]
 *
 * Run 1 (online): open the map on a small box, save it for offline.
 * Run 2 (same profile): every request except the app server goes to a dead
 * proxy — this cuts the service worker and the map's web workers too, which
 * Playwright's context.setOffline() does not. The saved area must render with
 * no failed tile request, a box elsewhere must show failures, and a blob
 * worker (how Mapbox GL fetches vector/terrain tiles) must get the saved copy.
 * Run 3 (online): deleting the last area removes the cache and the worker.
 */

'use strict';

const { chromium } = require('playwright');
const fs = require('fs');
const os = require('os');
const path = require('path');

const arg = (name, dflt) => {
  const i = process.argv.indexOf(name);
  return i > 0 ? process.argv[i + 1] : dflt;
};
const BASE = arg('--base', 'http://127.0.0.1:5194');
const SHOTS = arg('--shots', null);
const HOSTPORT = new URL(BASE).host;
const SAVED = `${BASE}/map?b=47.2700,25.3500,47.3100,25.3900&z=13`;
const ELSEWHERE = `${BASE}/map?b=45.0000,21.0000,45.0400,21.0400&z=13`;
const GL = ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'];
const OPTS = { viewport: { width: 400, height: 800 }, locale: 'ar-SA' };

let failed = false;
const check = (ok, what) => {
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${what}`);
  if (!ok) failed = true;
};
const shot = (p, name) => (SHOTS ? p.screenshot({ path: path.join(SHOTS, name) }) : null);
const isTile = (u) => /api\.mapbox\.com\/.*\/\d+\/\d+\/\d+\./.test(u);

(async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'sary-offline-'));
  try {
    /* 1 — online: save */
    let ctx = await chromium.launchPersistentContext(dir, { ...OPTS, args: GL });
    let p = await ctx.newPage();
    await p.goto(SAVED);
    await p.waitForTimeout(8000);
    await p.getByTestId('sary-offline-open').click();
    await p.waitForFunction(() => /جزء/.test(document.querySelector('[data-testid=sary-offline-estimate]')?.textContent || ''), null, { timeout: 20000 });
    console.log('     estimate:', await p.getByTestId('sary-offline-estimate').innerText());
    await p.getByTestId('sary-offline-save').click();
    await p.getByTestId('sary-offline-msg').waitFor({ timeout: 180000 });
    const msg = await p.getByTestId('sary-offline-msg').innerText();
    console.log('     saved:', msg);
    check(/حُفظت المنطقة/.test(msg), 'area saved');
    await shot(p, 'offline-sheet-saved.png');
    const cachedApi = await p.evaluate(async () => (await (await caches.open('sary-offline-v1')).keys()).filter((r) => /\/_?api\//.test(new URL(r.url).pathname)).length);
    check(cachedApi === 0, 'nothing under /api is kept');
    await ctx.close();

    /* 2 — no network at all */
    ctx = await chromium.launchPersistentContext(dir, { ...OPTS, args: [...GL, '--proxy-server=http://127.0.0.1:9', `--proxy-bypass-list=${HOSTPORT}`] });
    p = await ctx.newPage();
    const errs = [];
    p.on('pageerror', (e) => errs.push(e.message));
    const tileFails = [];
    p.on('console', (m) => {
      const u = (m.location() && m.location().url) || '';
      if (m.type() === 'error' && isTile(u)) tileFails.push(u);
    });
    await p.goto(SAVED);
    await p.waitForTimeout(10000);
    const reach = await p.evaluate(() => fetch('https://api.mapbox.com/?probe=' + Math.random(), { mode: 'no-cors' }).then(() => 'reachable', () => 'unreachable'));
    check(reach === 'unreachable', 'Mapbox is unreachable in run 2');
    check(tileFails.length === 0, `saved area: no failed tile requests (${tileFails.length})`);
    const probe = await p.evaluate(async () => {
      const keys = (await (await caches.open('sary-offline-v1')).keys()).map((r) => r.url);
      const urls = [keys.find((u) => /vector\.pbf/.test(u)), keys.find((u) => /terrain-dem-v1\/\d/.test(u))].filter(Boolean);
      const src = "onmessage = async (e) => { const out = []; for (const u of e.data) { try { const r = await fetch(u + (u.includes('?') ? '&' : '?') + 'sku=another-session'); out.push(r.status); } catch (err) { out.push('ERR'); } } postMessage(out); };";
      const w = new Worker(URL.createObjectURL(new Blob([src], { type: 'text/javascript' })));
      return new Promise((ok) => {
        w.onmessage = (e) => ok(e.data);
        w.postMessage(urls);
      });
    });
    check(probe.length === 2 && probe.every((s) => s === 200), `map web worker gets the saved vector and terrain tiles (${probe})`);
    await shot(p, 'offline-saved-area.png');
    tileFails.length = 0;
    await p.goto(ELSEWHERE);
    await p.waitForTimeout(8000);
    check(tileFails.length > 0, `unsaved area: tiles fail as expected (${tileFails.length})`);
    await shot(p, 'offline-unsaved-area.png');
    check(errs.length === 0, `no page errors (${errs.join(' | ')})`);
    await ctx.close();

    /* 3 — online again: delete */
    ctx = await chromium.launchPersistentContext(dir, { ...OPTS, args: GL });
    p = await ctx.newPage();
    await p.goto(SAVED);
    await p.waitForTimeout(4000);
    await p.getByTestId('sary-offline-open').click();
    await p.getByRole('button', { name: /^حذف/ }).click();
    await p.waitForTimeout(1500);
    const after = await p.evaluate(async () => ({ regs: (await navigator.serviceWorker.getRegistrations()).length, cache: await caches.has('sary-offline-v1') }));
    check(after.regs === 0 && !after.cache, 'deleting the last area removes the worker and the cache');
    await ctx.close();
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
  process.exit(failed ? 1 : 0);
})();
