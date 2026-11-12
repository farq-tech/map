/* Review mode: card stack (✓ صح / ✗ خطأ / تخطّى / ✎ عدّل), swipe, in-card edit tools. Phone first. */
'use strict';
(() => {
  const $ = s => document.querySelector(s);
  const NS = 'http://www.w3.org/2000/svg';
  const R = {cards: [], i: 0, show: true, t0: 0, editing: false, pts: [], hist: [], tool: 'drag', before: null, busy: false,
             done: [], reasons: {}, edits: [], splitAt: null, progress: null};
  const api = async (u, o) => { const r = await fetch(u, o); if (!r.ok) { let d = r.statusText; try { d = (await r.json()).detail || d; } catch (e) {} throw new Error(d); } return r.json(); };
  const post = (u, b) => api(u, {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(b || {})});
  const cur = () => R.cards[R.i];
  const msg = t => { const m = $('#rv-msg'); m.textContent = t || ''; m.hidden = !t; if (t) { clearTimeout(msg.t); msg.t = setTimeout(() => { m.hidden = true; }, 3500); } };
  const svg = $('#rv-svg');
  const pt = e => { const r = svg.getBoundingClientRect(); return [(e.clientX - r.left) / r.width * 512, (e.clientY - r.top) / r.height * 512]; };

  // ---------------------------------------------------------------- rendering
  function mk(tag, attrs) { const e = document.createElementNS(NS, tag); for (const k in attrs) e.setAttribute(k, attrs[k]); return e; }
  function poly(points, col, w, dash, extra) { return mk('polyline', {points: points.map(p => p.join(',')).join(' '), fill: 'none', stroke: col, 'stroke-width': w, 'stroke-linecap': 'round', 'stroke-linejoin': 'round', ...(dash ? {'stroke-dasharray': dash} : {}), ...(extra || {})}); }
  function draw() {
    svg.innerHTML = '';
    const c = cur(); if (!c) return;
    const pts = R.editing ? R.pts : c.line_px;
    if (R.editing && R.before) svg.appendChild(poly(R.before, '#ffffff', 3, '6 6', {opacity: .8}));
    if (R.show || R.editing) {
      if (R.editing && R.splitAt) {
        svg.appendChild(poly(R.splitAt.a, '#000', 8)); svg.appendChild(poly(R.splitAt.a, '#ff9f1c', 4));
        svg.appendChild(poly(R.splitAt.b, '#000', 8)); svg.appendChild(poly(R.splitAt.b, '#2ec4ff', 4));
      } else { svg.appendChild(poly(pts, '#000', 8, null, {opacity: .55})); svg.appendChild(poly(pts, '#ffee00', 4)); }
    }
    if (R.editing) handles();
  }
  function handles() {
    const idx = R.tool === 'trim' ? [0, R.pts.length - 1] : R.tool === 'drag' ? R.pts.map((_, i) => i) : [];
    idx.forEach(i => {
      const g = mk('g', {});
      g.appendChild(mk('circle', {cx: R.pts[i][0], cy: R.pts[i][1], r: 26, fill: 'transparent'}));            // big hit area (≈ 40 px on a phone)
      g.appendChild(mk('circle', {cx: R.pts[i][0], cy: R.pts[i][1], r: R.tool === 'trim' ? 13 : 9, class: 'rv-handle', fill: R.tool === 'trim' ? '#ff9f1c' : '#fff'}));
      g.addEventListener('pointerdown', e => startDrag(e, i)); svg.appendChild(g);
    });
  }
  function badge(c) {
    $('#rv-badge').innerHTML = `<span>${c.source_label}</span>` + (c.conf != null ? `<span>ثقة ${c.conf}</span>` : '') + `<span>${Math.round(c.length_m)} م</span>` + (c.control ? '' : '');
  }
  function show() {
    const c = cur();
    $('#rv-reasons').hidden = true; $('#rv-actions').hidden = false; $('#rv-edit').hidden = true; R.editing = false; R.before = null; R.splitAt = null; R.show = true;
    $('#rv-toggle').textContent = 'إخفاء الخط';
    if (!c) { finish(); return; }
    $('#rv-img').src = c.img; badge(c); draw();
    $('#rv-why').textContent = c.detail + ((c.why || []).length ? ' · ' + c.why.slice(0, 2).join(' · ') : '');
    R.t0 = performance.now(); prog();
    // preload the next 3 cards
    R.cards.slice(R.i + 1, R.i + 4).forEach(n => { const im = new Image(); im.src = n.img; });
  }
  function prog() {
    const p = R.progress || {total: R.cards.length, done: 0, minutes_left: 0};
    $('#rv-prog').innerHTML = `${p.batch > 1 ? 'دفعة ' + p.batch + ' · ' : ''}${p.done}/${p.total} بطاقة<small>≈ ${p.minutes_left} دقيقة متبقية</small>`;
  }
  function finish() {
    $('#rv-img').removeAttribute('src'); svg.innerHTML = ''; $('#rv-badge').innerHTML = ''; $('#rv-actions').hidden = true;
    $('#rv-why').innerHTML = 'انتهت البطاقات الحالية. شكرًا — راجع «المصادر» لترى دقة كل مصدر.';
    $('#rv-prog').innerHTML = 'اكتملت الدفعة ✓';
  }

  // ---------------------------------------------------------------- verdicts
  async function send(v, reason, extra) {
    const c = cur(); if (!c || R.busy) return; R.busy = true;
    try {
      const body = {pid: c.pid, verdict: v, reason: reason || null, ms: Math.round(performance.now() - R.t0), ...(extra || {})};
      const r = await post('/api/review/verdict', body);
      R.progress = r.progress; R.done.push(c); R.i++; show();
    } catch (e) { msg('تعذر: ' + e.message); }
    R.busy = false;
  }
  function openReasons() {
    $('#rv-reasons').innerHTML = Object.entries(R.reasons).map(([k, v]) => `<button data-r="${k}" class="no">${v}</button>`).join('');
    $('#rv-reasons').hidden = false; $('#rv-actions').hidden = true;
    document.querySelectorAll('#rv-reasons button').forEach(b => b.onclick = () => send('wrong', b.dataset.r));
  }
  async function undo() {
    if (R.busy) return; R.busy = true;
    try {
      const r = await post('/api/review/undo');
      if (!r.undone) { msg('لا شيء للتراجع'); R.busy = false; return; }
      const back = R.done.pop();
      if (back) { R.i--; R.cards[R.i] = back; R.progress = r.progress; show(); msg('أُلغي آخر حكم'); }
      else { await load(); msg('أُلغي آخر حكم'); }
    } catch (e) { msg('تعذر: ' + e.message); }
    R.busy = false;
  }

  // ---------------------------------------------------------------- swipe
  const st = $('#rv-stage'); let sw = null;
  st.addEventListener('pointerdown', e => { if (R.editing) return; sw = {x: e.clientX, y: e.clientY, t: performance.now(), hide: setTimeout(() => { if (sw) { R.show = false; draw(); sw.held = true; } }, 280)}; });
  st.addEventListener('pointermove', e => { if (!sw || R.editing) return; const dx = e.clientX - sw.x; $('#rv-swipe-r').style.opacity = Math.max(0, Math.min(1, dx / 120)); $('#rv-swipe-l').style.opacity = Math.max(0, Math.min(1, -dx / 120)); if (Math.abs(dx) > 12) clearTimeout(sw.hide); });
  const end = e => { if (!sw) return; const dx = e.clientX - sw.x; clearTimeout(sw.hide); const held = sw.held; sw = null;
    $('#rv-swipe-r').style.opacity = 0; $('#rv-swipe-l').style.opacity = 0;
    if (held) { R.show = $('#rv-toggle').textContent === 'إخفاء الخط'; draw(); }
    if (R.editing) return;
    if (dx > 90) send('correct_clear'); else if (dx < -90) openReasons(); };
  st.addEventListener('pointerup', end); st.addEventListener('pointercancel', () => { sw = null; });

  // ---------------------------------------------------------------- in-card editing
  function snap() { R.hist.push(JSON.stringify({p: R.pts, b: R.before})); }
  function nearest(p, pts) {   // nearest point on polyline: {d, s (segment idx), t, q}
    let best = {d: 1e9};
    for (let i = 0; i < pts.length - 1; i++) {
      const [ax, ay] = pts[i], [bx, by] = pts[i + 1]; const vx = bx - ax, vy = by - ay; const L2 = vx * vx + vy * vy || 1;
      const t = Math.max(0, Math.min(1, ((p[0] - ax) * vx + (p[1] - ay) * vy) / L2)); const q = [ax + t * vx, ay + t * vy];
      const d = Math.hypot(p[0] - q[0], p[1] - q[1]); if (d < best.d) best = {d, s: i, t, q};
    }
    return best;
  }
  function startDrag(e, i) {
    e.preventDefault(); e.stopPropagation(); snap(); const tool = R.tool;
    const move = ev => {
      const p = pt(ev);
      if (tool === 'drag') R.pts[i] = p;
      else if (tool === 'trim') trimTo(i === 0, p);
      draw();
    };
    const up = () => { window.removeEventListener('pointermove', move); window.removeEventListener('pointerup', up); R.edits.push(tool); };
    window.addEventListener('pointermove', move); window.addEventListener('pointerup', up);
  }
  function trimTo(isStart, p) {
    const pts = isStart ? R.pts.slice().reverse() : R.pts.slice();     // work on the END of the line
    const n = nearest(p, pts); const last = pts[pts.length - 1], prev = pts[pts.length - 2];
    const dx = last[0] - prev[0], dy = last[1] - prev[1], L = Math.hypot(dx, dy) || 1, ux = dx / L, uy = dy / L;
    const along = (p[0] - last[0]) * ux + (p[1] - last[1]) * uy, perp = Math.abs(-(p[0] - last[0]) * uy + (p[1] - last[1]) * ux);
    let out;
    if (along > 0 && perp < n.d + 6) out = pts.slice(0, -1).concat([[last[0] + ux * along, last[1] + uy * along]]);   // extend along the end direction
    else { out = pts.slice(0, n.s + 1).concat([n.q]); }                                                            // trim inward
    if (out.length < 2) return;
    R.pts = isStart ? out.reverse() : out;
  }
  async function doSnap() {
    const c = cur(); snap(); R.before = R.pts.map(p => p.slice()); R.snapN = (R.snapN || 0) + 1; $('#rv-ehint').textContent = 'جارٍ الانطباق على مركز الدرب…';
    try { const r = await api('/api/review/snap/' + c.pid + (R.snapN > 1 ? '?wide=true' : '')); R.pts = r.line_px; R.edits.push('snap');
      $('#rv-ehint').textContent = `انطبق: إزاحة متوسطة ${(r.mean_shift_px * r.metres_per_px).toFixed(1)} م (الأقصى ${(r.max_shift_px * r.metres_per_px).toFixed(1)} م) — الأبيض المتقطّع = قبل. ${R.snapN < 2 ? 'لم ينطبق؟ اضغط «انطباق» مرة أخرى لبحث أوسع. ' : ''}«تراجع التعديل» يعيده.`; draw(); }
    catch (e) { $('#rv-ehint').textContent = 'تعذر: ' + e.message; R.before = null; R.hist.pop(); }
  }
  svg.addEventListener('pointerdown', e => {
    if (!R.editing) return; const p = pt(e);
    if (R.tool === 'extend') {
      snap(); const a = R.pts[0], b = R.pts[R.pts.length - 1];
      if (Math.hypot(p[0] - a[0], p[1] - a[1]) < Math.hypot(p[0] - b[0], p[1] - b[1])) R.pts.unshift(p); else R.pts.push(p);
      R.edits.push('extend'); draw();
    } else if (R.tool === 'split') {
      if (!R.splitAt) { const n = nearest(p, R.pts); if (n.d > 40) return; snap();
        R.splitAt = {a: R.pts.slice(0, n.s + 1).concat([n.q]), b: [n.q].concat(R.pts.slice(n.s + 1))}; $('#rv-ehint').textContent = 'المس النصف الذي تريد حذفه (البرتقالي أو الأزرق).'; draw(); }
      else { const da = nearest(p, R.splitAt.a).d, db = nearest(p, R.splitAt.b).d; R.pts = da < db ? R.splitAt.b : R.splitAt.a; R.splitAt = null; R.edits.push('split'); $('#rv-ehint').textContent = ''; draw(); }
    }
  });
  const HINTS = {drag: 'اسحب أي نقطة بيضاء.', trim: 'اسحب أحد الطرفين البرتقاليين للداخل (قصّ) أو للخارج (مدّ).', extend: 'المس الصورة عند النقطة التالية لمدّ أقرب طرف.', snap: '', split: 'المس الخط عند نقطة التقسيم.'};
  function setEt(t) {
    R.tool = t; R.splitAt = null; document.querySelectorAll('[data-et]').forEach(b => b.classList.toggle('on', b.dataset.et === t));
    $('#rv-ehint').textContent = HINTS[t]; if (t === 'snap') doSnap(); else draw();
  }
  function startEdit() { const c = cur(); if (!c) return; R.snapN = 0; R.editing = true; R.pts = c.line_px.map(p => p.slice()); R.hist = []; R.edits = []; R.before = null;
    $('#rv-edit').hidden = false; $('#rv-actions').hidden = true; R.show = true; setEt('drag'); }
  function eUndo() { const h = R.hist.pop(); if (!h) return; const s = JSON.parse(h); R.pts = s.p; R.before = s.b; R.splitAt = null; R.edits.pop(); draw(); }

  // ---------------------------------------------------------------- stats panel
  async function showStats() {
    const s = await api('/api/review/stats'); const pct = x => x == null ? '—' : Math.round(x * 100) + '%';
    const rate = r => `<td class="rate"><b>${pct(r.p)}</b><small>${r.wilson95 ? pct(Math.max(0, r.wilson95[0])) + '–' + pct(r.wilson95[1]) : '—'}</small><small>${r.k}/${r.n}</small></td>`;
    const rows = Object.values(s.sources).map(v => `<tr><td>${v.label}<small class="muted" style="display:block">${v.n} حكم · ${v.wrong + v.offset} خطأ</small></td><td>${v.clear}</td><td>${v.faint}</td><td>${v.unspecified}</td>${rate(v.strict)}${rate(v.lenient)}</tr>`).join('');
    $('#rv-stats').innerHTML = `<button class="x" onclick="document.querySelector('#rv-stats').hidden=true">إغلاق</button><h3>دقة كل مصدر — بتعريفين</h3>
      <table><tr><th>المصدر</th><th>واضح</th><th>ضعيف</th><th>قديم</th><th>صارم</th><th>متساهل</th></tr>${rows}</table>
      <p class="muted"><b>صارم</b> = «✓ واضح» فقط (درب واضح والخط ضمن ≈15 م). <b>متساهل</b> = واضح + ضعيف (يوجد أثر ظاهر ولو خافت/مُزاح). النسبة تحت كل رقم: مجال Wilson 95% ثم عدد الأحكام ذات المستويين؛ «قديم» = أحكام «صح» المفردة من الدفعة الأولى (لا تُحتسب في أي تعريف)، ومجال Wilson 95% يتّسع مع قلة العيّنات.</p>
      <h3>الاتساق والسرعة</h3><div class="muted">أخطاء مُزاحة رُفضت: ${s.controls.shifted_wrong_rejected} · مطابقة OSM قُبلت: ${s.controls.likely_right_accepted}<br>تكرار متّسق (قبول/رفض): ${s.controls.repeat_consistent} · بنفس المستوى: ${s.controls.repeat_consistent_level}<br>
      وسيط الزمن لكل بطاقة: ${s.median_seconds_per_card ?? '—'} ث · نسبة التعديل: ${pct(s.edit_rate)} · أحكام: ${s.n_verdicts}</div>`;
    $('#rv-stats').hidden = false;
  }

  // ---------------------------------------------------------------- load / wiring
  async function load() {
    const d = await api('/api/review/deck'); R.reasons = d.reasons; R.progress = d.progress; R.done = [];
    if (!d.ready) { $('#rv-why').innerHTML = 'لا يوجد طابور مراجعة بعد. <button id="rv-build" class="primary">ابنِ الطابور (≈ دقيقة)</button>'; $('#rv-build').onclick = async () => { await post('/api/review/build'); $('#rv-why').textContent = 'جارٍ البناء…'; const t = setInterval(async () => { const x = await api('/api/review/deck'); if (x.ready) { clearInterval(t); load(); } }, 4000); }; $('#rv-actions').hidden = true; return false; }
    R.cards = d.cards; R.i = 0; show(); return true;
  }
  window.RV = {open: async () => { $('#review').hidden = false; document.body.classList.add('rv-open'); await load(); }, close: () => { $('#review').hidden = true; document.body.classList.remove('rv-open'); }, R};
  $('#rv-right').onclick = () => send('correct_clear'); $('#rv-faint').onclick = () => send('correct_faint'); $('#rv-more').onclick = () => send('correct_clear', null, {more_tracks: true}); $('#rv-wrong').onclick = openReasons;
  $('#rv-skip').onclick = () => send('skip'); $('#rv-undo').onclick = undo; $('#rv-editbtn').onclick = startEdit; $('#rv-statsbtn').onclick = showStats;
  $('#rv-toggle').onclick = () => { R.show = !R.show; $('#rv-toggle').textContent = R.show ? 'إخفاء الخط' : 'إظهار الخط'; draw(); };
  $('#rv-exit').onclick = () => window.RV.close(); $('#to-review').onclick = () => window.RV.open();
  document.querySelectorAll('[data-et]').forEach(b => b.onclick = () => setEt(b.dataset.et));
  $('[data-et=snap]').onclick = () => { R.tool = 'snap'; document.querySelectorAll('[data-et]').forEach(x => x.classList.toggle('on', x.dataset.et === 'snap')); doSnap(); };
  $('#rv-eundo').onclick = eUndo; $('#rv-ecancel').onclick = () => show();
  $('#rv-edone').onclick = () => send('correct_clear', null, {line_px: R.pts, edits: R.edits});
  document.addEventListener('keydown', e => { if ($('#review').hidden || R.editing) return; if (e.key === 'ArrowRight' || e.key === 'y') send('correct_clear'); else if (e.key === 'f') send('correct_faint'); else if (e.key === 'ArrowLeft' || e.key === 'n') openReasons(); else if (e.key === 's') send('skip'); else if (e.key === 'z') undo(); });
  if (!new URLSearchParams(location.search).has('draw')) window.RV.open();
})();
