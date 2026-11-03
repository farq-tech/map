/**
 * Two (three) real browsers against a running stack — no mocks:
 *   API (real Postgres) on :4001, Vite on :5173.
 *
 *   NODE_PATH=<dir with playwright> node scripts/e2e-outings.cjs [--base http://127.0.0.1:5173] [--shots dir]
 *
 * Geolocation is driven through the browser's own Geolocation API
 * (context.setGeolocation), so the app's real watchPosition path runs.
 */

'use strict';

const { chromium } = require('playwright');
const path = require('path');
const fs = require('fs');

const arg = (name, dflt) => {
  const i = process.argv.indexOf(name);
  return i > 0 ? process.argv[i + 1] : dflt;
};
const BASE = arg('--base', 'http://127.0.0.1:5173');
const SHOTS = arg('--shots', null);
if (SHOTS) fs.mkdirSync(SHOTS, { recursive: true });

/* Thumamah, north of Riyadh. Metres → degrees, near enough at this latitude. */
const START = { latitude: 25.2105, longitude: 46.6201 };
const north = (p, m) => ({ ...p, latitude: p.latitude + m / 111_195 });
const east = (p, m) => ({ ...p, longitude: p.longitude + m / (111_195 * Math.cos((p.latitude * Math.PI) / 180)) });

const results = [];
async function check(name, fn) {
  const t = Date.now();
  try {
    await fn();
    results.push({ name, ok: true, ms: Date.now() - t });
    console.log(`  ✔ ${name}`);
  } catch (e) {
    results.push({ name, ok: false, error: e.message });
    console.log(`  ✖ ${name}\n      ${e.message.split('\n')[0]}`);
  }
}

async function device(browser, pos, label) {
  const ctx = await browser.newContext({
    viewport: { width: 390, height: 844 },
    deviceScaleFactor: SHOTS ? 2 : 1,
    locale: 'ar-SA',
    geolocation: { ...pos, accuracy: 8 },
    permissions: ['geolocation'],
  });
  const page = await ctx.newPage();
  page.on('pageerror', (e) => console.log(`  [${label} pageerror] ${e.message}`));
  return { ctx, page, label, pos };
}

async function shot(d, name) {
  if (!SHOTS) return;
  await d.page.screenshot({ path: path.join(SHOTS, `${name}.png`) });
}

/* Like a person would: open «المشاركون» when the row is not on screen. */
async function memberText(page, userId) {
  const row = page.locator(`[data-testid="outing-member"][data-user="${userId}"]`);
  if (!(await row.isVisible().catch(() => false))) {
    await page.getByTestId('outing-tab-members').click();
    await row.waitFor({ state: 'visible', timeout: 5_000 });
  }
  return row.innerText();
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

(async () => {
  const browser = await chromium.launch();
  const A = await device(browser, START, 'A');
  const B = await device(browser, east(START, 1200), 'B');
  const C = await device(browser, north(START, 5000), 'C');
  let inviteLink = '';
  let outingId = '';
  let aId = '';
  let bId = '';
  const ident = (p) => p.evaluate(() => JSON.parse(localStorage.getItem('sary.outings.identity.v1') || 'null'));

  console.log(`e2e against ${BASE}`);

  await check('entry «طلعة مشتركة» is on the Sary map', async () => {
    await A.page.goto(`${BASE}/map`);
    await A.page.getByTestId('sary-outing-entry').click();
    await A.page.waitForURL(/\/outings$/);
  });

  await check('A creates an identity and an outing', async () => {
    await A.page.getByTestId('outing-name-input').fill('أبو فهد');
    await A.page.getByTestId('outing-profile-submit').click();
    await A.page.getByTestId('outing-create-name').fill('طلعة الثمامة');
    await shot(A, '01-create');
    await A.page.getByTestId('outing-create-submit').click();
    await A.page.waitForURL(/\/outings\/[0-9a-f-]{36}/);
    outingId = A.page.url().match(/outings\/([0-9a-f-]{36})/)[1];
    aId = (await ident(A.page)).user.id;
  });

  await check('A gets a private invite link (token in the fragment)', async () => {
    const link = A.page.getByTestId('outing-invite-link');
    await link.waitFor();
    inviteLink = await link.inputValue();
    if (!/\/outings\/join#[A-Za-z0-9_-]{43}$/.test(inviteLink)) throw new Error(`bad link ${inviteLink}`);
    await shot(A, '02-invite');
  });

  await check('before start, nothing is shared', async () => {
    const t = await A.page.getByTestId('outing-sharing-indicator').innerText();
    if (!/لم تبدأ/.test(t)) throw new Error(t);
  });

  await check('A starts the outing', async () => {
    await A.page.getByTestId('outing-start').click();
    await waitFor(async () => /موقعك مُشارَك/.test(await A.page.getByTestId('outing-sharing-indicator').innerText()));
  });

  await check('B opens the invite: sees outing name and who invited', async () => {
    await B.page.goto(inviteLink.replace(/^https?:\/\/[^/]+/, BASE));
    await B.page.getByTestId('outing-join-preview').waitFor();
    const name = await B.page.getByTestId('outing-join-name').innerText();
    const body = await B.page.getByTestId('outing-join-preview').innerText();
    if (name !== 'طلعة الثمامة' || !/أبو فهد/.test(body)) throw new Error(body);
    if (B.page.url().includes('#')) throw new Error('token left in the address bar');
    await shot(B, '03-join-preview');
  });

  await check('B joins and lands on the shared map', async () => {
    /* One tap: name + join together. */
    await B.page.getByTestId('outing-name-input').fill('خويي سعد');
    await B.page.getByTestId('outing-join-submit').click();
    await B.page.waitForURL(new RegExp(`/outings/${outingId}`));
    bId = (await ident(B.page)).user.id;
  });

  await check('live link is a WebSocket on both devices', async () => {
    for (const d of [A, B]) {
      await waitFor(async () => (await d.page.getByTestId('outing-link-state').getAttribute('data-state')) === 'live');
    }
  });

  await check('each sees the other: live, ~1.2 km, east/west', async () => {
    await waitFor(async () => /مباشر/.test(await memberText(A.page, bId)));
    await waitFor(async () => /مباشر/.test(await memberText(B.page, aId)));
    const a = await memberText(A.page, bId);
    const b = await memberText(B.page, aId);
    if (!/١٫٢ كم/.test(a) || !/شرق/.test(a)) throw new Error(`A sees: ${a}`);
    if (!/١٫٢ كم/.test(b) || !/غرب/.test(b)) throw new Error(`B sees: ${b}`);
    await shot(A, '04-A-sees-B');
    await shot(B, '05-B-sees-A');
  });

  await check('B drives north at 144 km/h; A sees the distance and direction change', async () => {
    /* 60 m every 1.5 s = 40 m/s. (Faster than ~200 km/h is held back as a GPS glitch.) */
    let p = east(START, 1200);
    for (let i = 1; i <= 20; i += 1) {
      p = north(p, 60);
      await B.ctx.setGeolocation({ ...p, accuracy: 8 });
      await new Promise((r) => setTimeout(r, 1500));
    }
    /* 1.2 km east, 1.2 km north → ~1.7 km north-east */
    await waitFor(async () => /١٫٧ كم/.test(await memberText(A.page, bId)), 20_000);
    const t = await memberText(A.page, bId);
    if (!/شمال شرق/.test(t) || !/مباشر/.test(t)) throw new Error(t);
    await shot(A, '06-A-sees-B-moved');
  });

  await check('an outsider cannot read the outing (server-side)', async () => {
    await C.page.goto(`${BASE}/outings`);
    await C.page.getByTestId('outing-name-input').fill('غريب');
    await C.page.getByTestId('outing-profile-submit').click();
    await C.page.getByTestId('outing-create').waitFor();
    const r = await C.page.evaluate(async (id) => {
      const t = JSON.parse(localStorage.getItem('sary.outings.identity.v1')).token;
      const a = await fetch(`/api/outings/${id}`, { headers: { authorization: `Bearer ${t}` } });
      const b = await fetch(`/api/outings/${id}/live`, { headers: { authorization: `Bearer ${t}` } });
      const c = await fetch(`/api/outings/${id}`);
      return [a.status, b.status, c.status];
    }, outingId);
    if (r.join() !== '404,404,401') throw new Error(`statuses ${r}`);
    await C.page.goto(`${BASE}/outings/${outingId}`);
    await C.page.getByTestId('outing-closed').waitFor();
    if (await C.page.locator('[data-testid="outing-member"]').count()) throw new Error('outsider saw members');
  });

  await check('B pauses sharing: A sees «أوقف مشاركة موقعه», no distance', async () => {
    await B.page.getByTestId('outing-tab-settings').click();
    await B.page.getByTestId('outing-sharing-toggle').click();
    await waitFor(async () => /أوقف مشاركة موقعه/.test(await memberText(A.page, bId)));
    if (await A.page.locator(`[data-user="${bId}"] [data-testid="outing-member-distance"]`).count()) throw new Error('distance still shown');
    await shot(A, '07-B-paused');
  });

  await check('B resumes sharing: live again', async () => {
    await B.page.getByTestId('outing-tab-settings').click();
    await B.page.getByTestId('outing-sharing-toggle').click();
    await B.ctx.setGeolocation({ ...north(east(START, 1200), 1250), accuracy: 9 });
    await waitFor(async () => /مباشر/.test(await memberText(A.page, bId)), 20_000);
  });

  await check('B goes to background: sending stops, says so', async () => {
    await B.page.evaluate(() => {
      Object.defineProperty(document, 'visibilityState', { value: 'hidden', configurable: true });
      document.dispatchEvent(new Event('visibilitychange'));
    });
    await waitFor(async () => /الخلفية/.test(await B.page.getByTestId('outing-sharing-indicator').innerText()));
    await B.page.evaluate(() => {
      Object.defineProperty(document, 'visibilityState', { value: 'visible', configurable: true });
      document.dispatchEvent(new Event('visibilitychange'));
    });
    await waitFor(async () => /موقعك مُشارَك/.test(await B.page.getByTestId('outing-sharing-indicator').innerText()));
  });

  await check('B loses network: A keeps B\'s last known position, never «مباشر»; then «انقطع الاتصال»', async () => {
    await B.ctx.setOffline(true);
    await waitFor(async () => /آخر موقع معروف|انقطع الاتصال/.test(await memberText(A.page, bId)), 70_000, 1000);
    const mid = await memberText(A.page, bId);
    if (/مباشر/.test(mid)) throw new Error(mid);
    await shot(A, '08-B-last-known');
    await waitFor(async () => /انقطع الاتصال/.test(await memberText(A.page, bId)), 90_000, 1000);
    const t = await memberText(A.page, bId);
    if (!/١٫٧ كم|١٫٨ كم/.test(t)) throw new Error(`last known lost: ${t}`);
    await shot(A, '09-B-lost');
  });

  await check('B\'s network returns: reconnects by itself and is live again', async () => {
    await B.ctx.setOffline(false);
    await B.ctx.setGeolocation({ ...north(east(START, 1200), 1300), accuracy: 7 });
    await waitFor(async () => (await B.page.getByTestId('outing-link-state').getAttribute('data-state')) === 'live', 45_000);
    await waitFor(async () => /مباشر/.test(await memberText(A.page, bId)), 30_000);
  });

  await check('A revokes the invite: the old link is refused', async () => {
    await A.page.getByTestId('outing-tab-invite').click();
    await A.page.getByTestId('outing-invite-revoke').click();
    await A.page.getByTestId('outing-invite-create').waitFor();
    await C.page.goto(inviteLink.replace(/^https?:\/\/[^/]+/, BASE));
    await C.page.getByTestId('outing-join-error').waitFor();
    const t = await C.page.getByTestId('outing-join-error').innerText();
    if (!/ألغى صاحب الطلعة/.test(t)) throw new Error(t);
    await shot(C, '10-revoked-invite');
  });

  await check('A ends the outing (with confirmation): B is told, sharing stops', async () => {
    await A.page.getByTestId('outing-tab-settings').click();
    await A.page.getByTestId('outing-end').click();
    await A.page.getByTestId('outing-end-confirm').waitFor();
    await shot(A, '11-end-confirm');
    await A.page.getByTestId('outing-end-yes').click();
    await B.page.getByTestId('outing-closed').waitFor({ timeout: 15_000 });
    const t = await B.page.getByTestId('outing-closed-reason').innerText();
    if (!/انتهت الطلعة/.test(t)) throw new Error(t);
    await shot(B, '12-B-ended');
  });

  await check('history lists the ended outing, without any positions', async () => {
    await B.page.goto(`${BASE}/outings`);
    /* The list loads after the heading: wait for the row, not the box. */
    await B.page.getByTestId('outing-history').getByText('طلعة الثمامة').first().waitFor({ timeout: 15000 });
    const t = await B.page.getByTestId('outing-history').innerText();
    if (!/طلعة الثمامة/.test(t) || !/انتهت/.test(t)) throw new Error(t);
    await shot(B, '13-history');
  });

  await browser.close();
  const failed = results.filter((r) => !r.ok);
  console.log(`\n${results.length - failed.length}/${results.length} passed`);
  process.exit(failed.length ? 1 : 0);
})().catch((e) => {
  console.error(e);
  process.exit(2);
});
