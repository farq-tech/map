/**
 * Everything at once, on phone-sized screens: the integrated outings branch
 * (safety, push, accounts, offline, map UX, extras, field test) against a
 * running stack — no mocks.
 *
 *   NODE_PATH=<dir with playwright> node scripts/e2e-outings-combined.cjs \
 *     --base http://127.0.0.1:5173 --tone path/to/tone.wav [--shots dir]
 *
 * A = iPhone 14 (owner), B = Pixel 7 (made co-leader), C = iPhone 14 (6 km
 * north, off screen). Chromium with a fake microphone fed from --tone and
 * SwiftShader so the 3D cars render. Each step also checks that the fixed
 * overlays (top bar, alerts, SOS UI, buttons, arrow chips, my «أنت» chip)
 * do not cover each other.
 */

'use strict';

const { chromium, devices } = require('playwright');
const path = require('path');
const fs = require('fs');

const arg = (name, dflt) => {
  const i = process.argv.indexOf(name);
  return i > 0 ? process.argv[i + 1] : dflt;
};
const BASE = arg('--base', 'http://127.0.0.1:5173');
const SHOTS = arg('--shots', null);
const TONE = arg('--tone', null);
if (SHOTS) fs.mkdirSync(SHOTS, { recursive: true });

const START = { latitude: 25.2105, longitude: 46.6201 };
const north = (p, m) => ({ ...p, latitude: p.latitude + m / 111_195 });
const east = (p, m) => ({ ...p, longitude: p.longitude + m / (111_195 * Math.cos((p.latitude * Math.PI) / 180)) });

const results = [];
const DEVICES = [];
async function check(name, fn) {
  try {
    await fn();
    results.push({ name, ok: true });
    console.log(`  ✔ ${name}`);
  } catch (e) {
    if (SHOTS) for (const d of DEVICES) await d.page.screenshot({ path: path.join(SHOTS, `fail-${results.length}-${d.label}.png`) }).catch(() => undefined);
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

async function device(browser, profile, pos, label) {
  const { defaultBrowserType, ...p } = devices[profile];
  const ctx = await browser.newContext({
    ...p,
    deviceScaleFactor: 2,
    locale: 'ar-SA',
    geolocation: { ...pos, accuracy: 8 },
    permissions: ['geolocation', 'microphone'],
  });
  await ctx.addInitScript(() => Object.defineProperty(navigator, 'getBattery', { value: undefined, configurable: true }));
  const page = await ctx.newPage();
  page.on('pageerror', (e) => console.log(`  [${label} pageerror] ${e.message}`));
  return { ctx, page, label, pos };
}

async function shot(d, name) {
  if (SHOTS) await d.page.screenshot({ path: path.join(SHOTS, `${name}.png`) });
}

const visible = (page, id) => page.getByTestId(id).isVisible().catch(() => false);

async function members(page) {
  if (!(await visible(page, 'outing-members'))) await page.getByTestId('outing-tab-members').click();
  await page.getByTestId('outing-members').waitFor({ timeout: 5_000 });
}

async function peek(page) {
  /* Collapse the sheet so the map and its buttons are in view. */
  for (let i = 0; i < 3; i += 1) {
    if ((await page.getByTestId('outing-live').getAttribute('data-snap')) === 'peek') return;
    const btn = page.locator('.farq-sheet-collapse').first();
    if (!(await btn.isVisible().catch(() => false))) return;
    await btn.click();
    await page.waitForTimeout(450);
  }
}

async function hold(page, id, ms) {
  const box = await page.getByTestId(id).boundingBox();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.down();
  await page.waitForTimeout(ms);
  await page.mouse.up();
}

/**
 * Fixed overlays that must not cover one another. Returns the overlapping
 * pairs (by name) among the ones currently visible.
 */
async function overlaps(page) {
  return page.evaluate(() => {
    const pick = {
      bar: '.sary-o-bar',
      lane: '.sary-o-lane > *',
      sosAlert: '[data-testid="outing-sos-alert"]',
      sosBtn: '[data-testid="outing-sos"]',
      ptt: '[data-testid="outing-ptt"]',
      fabs: '.sary-o-fabs > *',
      arrow: '[data-testid="outing-edge-arrow"]',
      me: '[data-testid="sary-my-car"] .sary-peer__name',
      sheet: '.farq-sheet, [data-testid="farq-bottom-sheet"]',
    };
    const boxes = [];
    for (const [name, sel] of Object.entries(pick)) {
      document.querySelectorAll(sel).forEach((el, i) => {
        const r = el.getBoundingClientRect();
        const cs = getComputedStyle(el);
        if (!r.width || !r.height || cs.visibility === 'hidden' || cs.display === 'none') return;
        if (r.bottom <= 0 || r.top >= innerHeight || r.right <= 0 || r.left >= innerWidth) return;
        boxes.push({ name: `${name}${i ? `#${i}` : ''}`, group: name, r });
      });
    }
    const hit = (a, b) => a.left < b.right - 1 && a.right > b.left + 1 && a.top < b.bottom - 1 && a.bottom > b.top + 1;
    const out = [];
    for (let i = 0; i < boxes.length; i += 1)
      for (let j = i + 1; j < boxes.length; j += 1) {
        const a = boxes[i];
        const b = boxes[j];
        if (a.group === b.group) continue;
        /* The full-screen SOS alert is meant to cover everything. */
        if (a.group === 'sosAlert' || b.group === 'sosAlert') continue;
        /* My «أنت» chip is map content: only the arrow chips (screen overlays tied to the map) must keep off it. */
        if ((a.group === 'me' || b.group === 'me') && a.group !== 'arrow' && b.group !== 'arrow') continue;
        const f = (r) => `[${Math.round(r.left)},${Math.round(r.top)},${Math.round(r.right)},${Math.round(r.bottom)}]`;
        if (hit(a.r, b.r)) out.push(`${a.name}${f(a.r)}×${b.name}${f(b.r)}`);
      }
    return out;
  });
}

async function noOverlap(d, where) {
  const all = await overlaps(d.page);
  /* An arrow chip under the button column is drawn below it (the buttons stay usable); it only
   * happens when the map area is too small for every chip. Report it, do not fail on it. */
  const soft = all.filter((x) => /^fabs.*×arrow|^arrow.*×fabs/.test(x));
  if (soft.length) console.log(`      (note) ${d.label} ${where}: arrow chip under the button column: ${soft.join(', ')}`);
  const o = all.filter((x) => !soft.includes(x));
  if (o.length) throw new Error(`${d.label} ${where}: overlapping ${o.join(', ')}`);
}

(async () => {
  const args = ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream', '--disable-features=AudioServiceOutOfProcess,AudioServiceSandbox'];
  if (TONE) args.push(`--use-file-for-fake-audio-capture=${TONE}`);
  const browser = await chromium.launch({ args });
  const A = await device(browser, 'iPhone 14', START, 'A');
  const B = await device(browser, 'Pixel 7', east(START, 900), 'B');
  const C = await device(browser, 'iPhone 14', north(START, 6000), 'C');
  DEVICES.push(A, B, C);
  let outingId = '';
  let invite = '';
  console.log(`combined e2e against ${BASE}`);

  await check('create + join: A creates and starts; B and C join from the link', async () => {
    await A.page.goto(`${BASE}/outings`);
    await A.page.getByTestId('outing-name-input').fill('أبو فهد');
    await A.page.getByTestId('outing-profile-submit').click();
    await A.page.getByTestId('outing-create-name').fill('طلعة الكل');
    await A.page.getByTestId('outing-create-submit').click();
    await A.page.waitForURL(/\/outings\/[0-9a-f-]{36}/);
    outingId = A.page.url().match(/outings\/([0-9a-f-]{36})/)[1];
    invite = await A.page.getByTestId('outing-invite-link').inputValue();
    await A.page.getByTestId('outing-start').click();
    for (const [d, name] of [[B, 'سعد'], [C, 'نورة']]) {
      await d.page.goto(invite.replace(/^https?:\/\/[^/]+/, BASE));
      await d.page.getByTestId('outing-name-input').fill(name);
      await d.page.getByTestId('outing-join-submit').click();
      await d.page.waitForURL(new RegExp(`/outings/${outingId}`));
    }
    for (const d of [A, B, C]) await waitFor(async () => (await d.page.getByTestId('outing-link-state').getAttribute('data-state')) === 'live', 20_000);
  });

  await check('cars with colours and names: A sees سعد and نورة as coloured named cars, and its own «أنت»', async () => {
    await members(A.page);
    await waitFor(async () => (await A.page.locator('[data-testid="outing-member"][data-fresh="live"]').count()) === 2, 20_000);
    await A.page.getByTestId('outing-fit').click();
    await A.page.waitForTimeout(2500);
    const peers = await waitFor(async () => {
      const list = await A.page.evaluate(() =>
        [...document.querySelectorAll('.sary-peer:not(.is-me)')].map((el) => ({ name: el.querySelector('.sary-peer__name b')?.textContent, color: getComputedStyle(el).getPropertyValue('--peer-color').trim() })),
      );
      return list.length >= 2 ? list : null;
    }, 20_000);
    const names = peers.map((p) => p.name).sort().join(',');
    if (names !== 'سعد,نورة') throw new Error(`names ${names}`);
    if (new Set(peers.map((p) => p.color)).size !== 2 || peers.some((p) => !p.color)) throw new Error(`colours ${JSON.stringify(peers)}`);
    await waitFor(async () => (await A.page.locator('[data-testid="sary-my-car"]').count()) === 1, 15_000);
    await peek(A.page);
    await shot(A, 'c01-cars-A');
    await noOverlap(A, 'cars');
  });

  await check('B is made co-leader by A', async () => {
    await members(A.page);
    const bRow = A.page.locator('[data-testid="outing-member"]', { hasText: 'سعد' });
    await bRow.click();
    await A.page.getByTestId('outing-member-coleader').click();
    await waitFor(async () => (await A.page.getByTestId('outing-member-coleader').getAttribute('data-on')) === '1');
    await A.page.locator('[data-testid="outing-member-card"] .sary-o-link-btn').first().click(); // back to the list
  });

  await check('note: B sends one, A sees the alert under the top bar, not over it', async () => {
    await B.page.getByTestId('outing-note-open').click();
    await B.page.getByTestId('outing-note-input').fill('نوقف عند المحطة');
    await B.page.getByTestId('outing-note-send').click();
    await A.page.getByTestId('outing-note-alert').waitFor({ timeout: 10_000 });
    await peek(A.page);
    await shot(A, 'c02-note-A');
    await noOverlap(A, 'note');
  });

  await check('rally point set by the co-leader (B); A sees it', async () => {
    await members(B.page);
    await B.page.getByTestId('outing-rally-set').click();
    await B.page.getByTestId('outing-rally-here').click();
    await members(A.page);
    await waitFor(async () => (await A.page.getByTestId('outing-rally-card').getAttribute('data-set')) === '1', 10_000);
    await B.page.waitForTimeout(800);
    await shot(B, 'c03-rally-B');
    await noOverlap(B, 'rally, half sheet');
  });

  await check('voice clip: B holds «اضغط وتكلم»; A gets the banner and the chip over B’s car', async () => {
    await peek(B.page);
    await A.page.mouse.click(10, 300); // one tap so A may play sound
    const uploaded = B.page.waitForResponse((r) => r.url().includes('/clips') && r.request().method() === 'POST', { timeout: 20_000 });
    uploaded.catch(() => undefined);
    await shot(B, 'c04-before-ptt-B');
    await noOverlap(B, 'before PTT');
    const box = await B.page.getByTestId('outing-ptt').boundingBox();
    await B.page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await B.page.mouse.down();
    await B.page.waitForFunction(() => document.querySelector('[data-testid="outing-ptt"]')?.dataset.state === 'recording', null, { timeout: 8000 });
    await B.page.waitForTimeout(2200);
    await B.page.mouse.up();
    const res = await uploaded;
    if (res.status() !== 201) throw new Error(`upload ${res.status()}`);
    await A.page.getByTestId('outing-voice-alert').waitFor({ timeout: 10_000 });
    await peek(A.page);
    await shot(A, 'c05-voice-A');
    await noOverlap(A, 'voice');
  });

  await check('SOS: C holds 1 s; A gets the full-screen alert; «أظهره» leaves a strip; «أنا بخير» clears it', async () => {
    await peek(C.page);
    await hold(C.page, 'outing-sos', 1300);
    await C.page.getByTestId('outing-sos-mine').waitFor({ timeout: 8000 });
    await shot(C, 'c06-sos-mine-C');
    await noOverlap(C, 'my SOS');
    await A.page.getByTestId('outing-sos-alert').waitFor({ timeout: 8000 });
    await shot(A, 'c07-sos-alert-A');
    await A.page.getByTestId('outing-sos-show').click();
    await A.page.getByTestId('outing-sos-strip').waitFor({ timeout: 5000 });
    await peek(A.page);
    await shot(A, 'c08-sos-strip-A');
    await noOverlap(A, 'SOS strip');
    await C.page.getByTestId('outing-sos-cancel').click();
    await waitFor(async () => !(await visible(A.page, 'outing-sos-strip')), 8000);
  });

  await check('off-screen arrow: zoomed on A, نورة (6 km north) gets an edge chip that does not cover «أنت»', async () => {
    await peek(A.page);
    await A.page.getByTestId('outing-locate').click();
    await A.page.waitForTimeout(2500);
    const arrow = A.page.locator('[data-testid="outing-edge-arrow"]', { hasText: 'نورة' });
    await arrow.waitFor({ timeout: 10_000 });
    await shot(A, 'c09-arrow-A');
    await noOverlap(A, 'arrows');
  });

  await check('offline area: A saves a small area from the Sary map; the one worker is registered', async () => {
    const p = await A.ctx.newPage();
    await p.goto(`${BASE}/map?b=46.6150,25.2060,46.6250,25.2150&z=15`);
    await p.waitForTimeout(8000);
    await p.getByTestId('sary-offline-open').click();
    await p.waitForFunction(() => /جزء/.test(document.querySelector('[data-testid=sary-offline-estimate]')?.textContent || ''), null, { timeout: 20000 });
    await p.getByTestId('sary-offline-save').click();
    await p.getByTestId('sary-offline-msg').waitFor({ timeout: 180_000 });
    const msg = await p.getByTestId('sary-offline-msg').innerText();
    if (!/حُفظت المنطقة/.test(msg)) throw new Error(msg);
    if (SHOTS) await p.screenshot({ path: path.join(SHOTS, 'c10-offline-saved.png') });
    const sw = await p.evaluate(async () => (await navigator.serviceWorker.getRegistrations()).map((r) => r.active?.scriptURL || ''));
    if (sw.length !== 1 || !/\/sw\.js$/.test(sw[0])) throw new Error(`workers ${JSON.stringify(sw)}`);
    /* The outing API is never served from the offline copy. */
    const cachedApi = await p.evaluate(async () => (await (await caches.open('sary-offline-v1')).keys()).filter((r) => /\/_?api\//.test(new URL(r.url).pathname)).length);
    if (cachedApi) throw new Error(`${cachedApi} /api entries cached`);
    await p.close();
  });

  for (const d of [A, B, C]) await d.ctx.close();
  await browser.close();
  const ok = results.filter((r) => r.ok).length;
  console.log(`\n${ok}/${results.length} passed`);
  process.exit(ok === results.length ? 0 : 1);
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
