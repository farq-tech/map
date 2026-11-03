/**
 * Outing safety in real browsers against a running stack — no mocks of our
 * code: rally point, SOS (long-press, alert, late joiner, «أنا بخير»),
 * battery warning and the gap alert.
 *
 *   NODE_PATH=<dir with playwright> node scripts/e2e-outings-safety.cjs [--base http://127.0.0.1:5173]
 *
 * Geolocation goes through the browser's own Geolocation API. B's phone is
 * given a low battery by replacing navigator.getBattery in B's test browser
 * only — the app's real Battery Status API path then runs.
 */

'use strict';

const { chromium } = require('playwright');

const arg = (name, dflt) => {
  const i = process.argv.indexOf(name);
  return i > 0 ? process.argv[i + 1] : dflt;
};
const BASE = arg('--base', 'http://127.0.0.1:5173');
const SHOTS = arg('--shots', null);
const path = require('path');
if (SHOTS) require('fs').mkdirSync(SHOTS, { recursive: true });
const shot = (d, name) => (SHOTS ? d.page.screenshot({ path: path.join(SHOTS, `${name}.png`) }) : null);

const START = { latitude: 25.2105, longitude: 46.6201 };
const north = (p, m) => ({ ...p, latitude: p.latitude + m / 111_195 });
const east = (p, m) => ({ ...p, longitude: p.longitude + m / (111_195 * Math.cos((p.latitude * Math.PI) / 180)) });

const results = [];
async function check(name, fn) {
  try {
    await fn();
    results.push({ name, ok: true });
    console.log(`  ✔ ${name}`);
  } catch (e) {
    results.push({ name, ok: false });
    console.log(`  ✖ ${name}\n      ${e.message.split('\n')[0]}`);
  }
}

async function waitFor(fn, ms = 15_000, step = 250) {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    try {
      const v = await fn();
      if (v) return v;
    } catch (e) {
      last = e;
    }
    await new Promise((r) => setTimeout(r, step));
  }
  throw last || new Error('timed out');
}

async function device(browser, pos, label, { lowBattery = false } = {}) {
  const ctx = await browser.newContext({
    viewport: { width: 390, height: 844 },
    locale: 'ar-SA',
    geolocation: { ...pos, accuracy: 8 },
    permissions: ['geolocation'],
  });
  if (lowBattery) {
    await ctx.addInitScript(() => {
      const mgr = Object.assign(new EventTarget(), { level: 0.1, charging: false });
      Object.defineProperty(navigator, 'getBattery', { value: () => Promise.resolve(mgr), configurable: true });
    });
  } else {
    await ctx.addInitScript(() => Object.defineProperty(navigator, 'getBattery', { value: undefined, configurable: true }));
  }
  const page = await ctx.newPage();
  page.on('pageerror', (e) => console.log(`  [${label} pageerror] ${e.message}`));
  return { ctx, page, label, pos };
}

const text = (page, id) => page.getByTestId(id).innerText();
const visible = (page, id) => page.getByTestId(id).isVisible().catch(() => false);

async function members(page) {
  if (!(await visible(page, 'outing-members'))) await page.getByTestId('outing-tab-members').click();
  await page.getByTestId('outing-members').waitFor({ timeout: 5_000 });
}

async function holdSos(page, ms) {
  const box = await page.getByTestId('outing-sos').boundingBox();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.down();
  await page.waitForTimeout(ms);
  await page.mouse.up();
}

(async () => {
  const browser = await chromium.launch();
  const A = await device(browser, START, 'A');
  const B = await device(browser, east(START, 1200), 'B', { lowBattery: true });
  const C = await device(browser, north(START, 5000), 'C');
  let invite = '';
  let outingId = '';
  console.log(`safety e2e against ${BASE}`);

  await check('A creates and starts an outing; B joins', async () => {
    await A.page.goto(`${BASE}/outings`);
    await A.page.getByTestId('outing-name-input').fill('أبو فهد');
    await A.page.getByTestId('outing-profile-submit').click();
    await A.page.getByTestId('outing-create-name').fill('طلعة الأمان');
    await A.page.getByTestId('outing-create-submit').click();
    await A.page.waitForURL(/\/outings\/[0-9a-f-]{36}/);
    outingId = A.page.url().match(/outings\/([0-9a-f-]{36})/)[1];
    invite = await A.page.getByTestId('outing-invite-link').inputValue();
    await A.page.getByTestId('outing-start').click();
    await B.page.goto(invite.replace(/^https?:\/\/[^/]+/, BASE));
    await B.page.getByTestId('outing-name-input').fill('سعد');
    await B.page.getByTestId('outing-join-submit').click();
    await B.page.waitForURL(new RegExp(`/outings/${outingId}`));
    for (const d of [A, B]) await waitFor(async () => (await d.page.getByTestId('outing-link-state').getAttribute('data-state')) === 'live');
    await members(A.page);
    await waitFor(async () => /مباشر/.test(await A.page.getByTestId('outing-members').innerText()));
  });

  await check('battery: A sees B at 10 % with a warning; A (no Battery API) shows none', async () => {
    await members(A.page);
    const badge = await waitFor(async () => {
      const t = await A.page.locator('[data-testid="outing-member-battery"]').first().innerText();
      return /١٠٪/.test(t) && /ضعيفة/.test(t) ? t : null;
    }, 25_000);
    await A.page.getByTestId('outing-tab-members').click();
    await shot(A, 'safety-00-battery-A');
    if (!badge) throw new Error('no badge');
    await waitFor(async () => /بطارية سعد ضعيفة/.test(await text(A.page, 'outing-gap-alert')), 20_000);
    await members(B.page);
    if ((await B.page.locator('[data-testid="outing-member-battery"]').count()) !== 0) throw new Error('B shows a battery for A, which has none');
  });

  await check('rally: only the owner can set it; «عند موقعي» drops it; B sees distance and who arrived', async () => {
    await members(B.page);
    if (await visible(B.page, 'outing-rally-set')) throw new Error('member sees the set button');
    await members(A.page);
    await A.page.getByTestId('outing-rally-set').click();
    await A.page.getByTestId('outing-rally-placer').waitFor();
    await A.page.getByTestId('outing-rally-here').click();
    await A.page.getByTestId('outing-rally-placer').waitFor({ state: 'detached' });
    await members(B.page);
    await waitFor(async () => (await B.page.getByTestId('outing-rally-card').getAttribute('data-set')) === '1');
    const d = await text(B.page, 'outing-rally-distance');
    if (!/١٫٢ كم/.test(d) || !/غرب/.test(d)) throw new Error(`B sees: ${d}`);
    const arr = await text(B.page, 'outing-rally-arrived');
    if (!/وصل ١ من ٢/.test(arr) || !/أبو فهد/.test(arr)) throw new Error(arr);
    await B.page.getByTestId('outing-rally-pin').waitFor();
    await shot(B, 'safety-01-rally-B');
  });

  await check('rally: B drives to it and counts as arrived (≤150 m)', async () => {
    let p;
    /* 57 m every 1.5 s ≈ 137 km/h — faster is held back as a GPS glitch. */
    for (let i = 1; i <= 20; i += 1) {
      p = east(START, 1200 - i * 57);
      await B.ctx.setGeolocation({ ...p, accuracy: 8 });
      await new Promise((r) => setTimeout(r, 1500));
    }
    await waitFor(async () => /وصل ٢ من ٢/.test(await text(B.page, 'outing-rally-arrived')), 20_000);
    await waitFor(async () => /وصل ٢ من ٢/.test(await text(A.page, 'outing-rally-arrived')), 20_000);
  });

  await check('rally: owner moves it with the crosshair, then clears it; B follows', async () => {
    const before = await text(B.page, 'outing-rally-distance');
    await members(A.page);
    await A.page.getByTestId('outing-rally-move').click();
    await A.page.getByTestId('outing-rally-cross').waitFor();
    /* Drag the map a good way so the centre is somewhere else. */
    await A.page.mouse.move(195, 300);
    await A.page.mouse.down();
    await A.page.mouse.move(60, 150, { steps: 12 });
    await A.page.mouse.up();
    await A.page.waitForTimeout(600);
    await A.page.getByTestId('outing-rally-confirm').click();
    await waitFor(async () => (await text(B.page, 'outing-rally-distance')) !== before, 10_000);
    await members(A.page);
    await A.page.getByTestId('outing-rally-clear').click();
    await waitFor(async () => !(await visible(B.page, 'outing-rally-card')), 10_000);
    if ((await B.page.locator('[data-testid="outing-rally-pin"]').count()) !== 0) throw new Error('pin left on the map');
  });

  await check('SOS: a short tap does nothing but explain', async () => {
    await holdSos(B.page, 150);
    await waitFor(async () => /مطولًا/.test(await text(B.page, 'outing-toast')));
    await A.page.waitForTimeout(800);
    if (await visible(A.page, 'outing-sos-alert')) throw new Error('a tap raised an SOS');
  });

  await check('SOS: a 1 s hold reaches A as a full-screen alert with distance', async () => {
    await B.ctx.setGeolocation({ ...east(START, 600), accuracy: 8 });
    await B.page.waitForTimeout(1500);
    await holdSos(B.page, 1200);
    await B.page.getByTestId('outing-sos-mine').waitFor();
    await A.page.getByTestId('outing-sos-alert').waitFor({ timeout: 10_000 });
    const t = await text(A.page, 'outing-sos-alert');
    if (!/سعد يطلب المساعدة/.test(t)) throw new Error(t);
    const where = await text(A.page, 'outing-sos-where');
    if (!/م|كم/.test(where) || !/شرق/.test(where)) throw new Error(where);
    if (!(await visible(A.page, 'outing-sos-show'))) throw new Error('no «أظهره على الخريطة»');
    await shot(A, 'safety-02-sos-A');
    await shot(B, 'safety-03-sos-B');
  });

  await check('SOS: a late joiner (C) sees it straight away', async () => {
    const fresh = await A.page.evaluate(async (id) => {
      const t = JSON.parse(localStorage.getItem('sary.outings.identity.v1')).token;
      const r = await fetch(`/api/outings/${id}/invites`, { method: 'POST', headers: { authorization: `Bearer ${t}`, 'content-type': 'application/json' }, body: '{}' });
      return (await r.json()).invite.token;
    }, outingId);
    await C.page.goto(`${BASE}/outings/join#${fresh}`);
    await C.page.getByTestId('outing-name-input').fill('غريب');
    await C.page.getByTestId('outing-join-submit').click();
    await C.page.waitForURL(new RegExp(`/outings/${outingId}`));
    await C.page.getByTestId('outing-sos-alert').waitFor({ timeout: 10_000 });
    if (!/سعد/.test(await text(C.page, 'outing-sos-alert'))) throw new Error('wrong name');
  });

  await check('gap: C, ~5 km from the group, triggers one «متأخر» alert on A', async () => {
    await waitFor(async () => /غريب متأخر/.test(await text(A.page, 'outing-gap-alert')), 25_000);
  });

  await check('SOS: «أظهره على الخريطة» closes the alert, a red strip stays', async () => {
    await A.page.getByTestId('outing-sos-show').click();
    await A.page.getByTestId('outing-sos-alert').waitFor({ state: 'detached' });
    await A.page.getByTestId('outing-sos-strip').waitFor();
    await A.page.getByTestId('outing-sos-pin').waitFor();
    await shot(A, 'safety-04-sos-strip-A');
  });

  await check('SOS: «أنا بخير» clears it for everyone', async () => {
    await B.page.getByTestId('outing-sos-cancel').click();
    await B.page.getByTestId('outing-sos-mine').waitFor({ state: 'detached' });
    await A.page.getByTestId('outing-sos-strip').waitFor({ state: 'detached', timeout: 10_000 });
    await C.page.getByTestId('outing-sos-alert').waitFor({ state: 'detached', timeout: 10_000 });
    await waitFor(async () => /سعد بخير/.test(await text(A.page, 'outing-toast')), 5_000);
    if ((await A.page.locator('[data-testid="outing-sos-pin"]').count()) !== 0) throw new Error('SOS pin left on the map');
  });

  await browser.close();
  const failed = results.filter((r) => !r.ok);
  console.log(`\n${results.length - failed.length}/${results.length} passed`);
  process.exit(failed.length ? 1 : 0);
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
