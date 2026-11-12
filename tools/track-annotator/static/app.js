/* Track annotator UI — Leaflet + plain JS. All geometry is stored in WGS84 lat/lng (no pixel rounding). */
'use strict';
const $ = (s, r = document) => r.querySelector(s);
const TYPE_COLORS = {sandy:'#ffc400', dirt:'#ff7828', rocky:'#aaaaaa', mixed:'#be5aff', winding:'#00dc78', faint:'#ff4678'};
let CFG = null;
const S = {sample:null, feats:[], sel:null, tool:'select', draft:null, history:[], dirty:false,
           type:'dirt', clarity:2, overlay:null, handles:[], winRect:null, pendingWin:null, batchLayer:null};

const api = async (url, opt) => {
  const r = await fetch(url, opt);
  if (!r.ok) { let d = r.statusText; try { d = (await r.json()).detail || d; } catch (e) {} throw new Error(d); }
  return r.json();
};
let hintTimer = null;
const hint = t => { $('#hint').textContent = t || ''; clearTimeout(hintTimer); if (t && matchMedia('(max-width: 900px)').matches) hintTimer = setTimeout(() => { $('#hint').textContent = ''; }, 5000); };
const uid = () => Math.random().toString(36).slice(2, 12);

// ------------------------------------------------------------------ map
const map = L.map('map', {zoomControl: true, doubleClickZoom: false, maxZoom: 21, minZoom: 11,
                          zoomSnap: 0.5, zoomDelta: 0.5, attributionControl: true}).setView([25.1558, 46.6563], 17);
L.tileLayer('/tiles/{z}/{x}/{y}.jpg', {tileSize: 512, zoomOffset: -1, minZoom: 11, maxNativeZoom: 18, maxZoom: 21,
  attribution: '© Mapbox © Maxar — الصور: ترخيص أعلنه المالك'}).addTo(map);
map.createPane('feat'); map.getPane('feat').style.zIndex = 450;
const cv = L.canvas({pane: 'feat', tolerance: 16});   // fat hit area so thin lines are tappable
const isMobile = () => matchMedia('(max-width: 900px)').matches;
const isLandscape = () => matchMedia('(orientation: landscape)').matches;
S.aim = isMobile();            // crosshair mode default on phones
S.vtx = null;                  // {id, i} active vertex
function freeRect() {          // part of the map not covered by toolbar / sheet
  const m = $('#map').getBoundingClientRect(); let l = 0, t = 0, r = m.width, b = m.height;
  if (isMobile()) for (const el of [$('#toolbar'), $('#sheet')]) {
    if (!el || el.hidden) continue; const e = el.getBoundingClientRect(); if (!e.width) continue;
    if (e.width > 0.6 * m.width) b = Math.min(b, e.top - m.top);
    else if (e.left > m.left + m.width / 2) r = Math.min(r, e.left - m.left);
    else l = Math.max(l, e.right - m.left);
  }
  t = isMobile() ? 36 : 0;
  return {l, t, r, b};
}
function aimPoint() { const f = freeRect(); return L.point((f.l + f.r) / 2, (f.t + f.b) / 2); }
function aimLatLng() { return map.containerPointToLatLng(aimPoint()); }
function updateAim() {
  const el = $('#crosshair'), show = S.aim && S.sample && (S.tool === 'centerline' || S.tool === 'edge');
  el.hidden = !show; if (show) { const p = aimPoint(); el.style.left = p.x + 'px'; el.style.top = p.y + 'px'; }
  $('#btn-aim').classList.toggle('on', S.aim);
  $('#fab-win').hidden = !!S.sample || !isMobile();
  const stack = $('#toolbar').hidden ? 0 : ($('#toolbar').getBoundingClientRect().height + $('#sheet').getBoundingClientRect().height);
  document.documentElement.style.setProperty('--stack-h', stack + 'px');
}
function fitTo(b) {
  const f = freeRect(), m = $('#map').getBoundingClientRect();
  map.fitBounds(b, {paddingTopLeft: [f.l + 8, f.t + 8], paddingBottomRight: [m.width - f.r + 8, m.height - f.b + 8]});
}
window.addEventListener('resize', () => { updateAim(); if (!S.pendingWin) drawWinRect(); });
document.addEventListener('gesturestart', e => e.preventDefault());
L.control.scale({imperial: false}).addTo(map);

function tileXY(lat, lng, z) {
  const n = 2 ** z, x = (lng + 180) / 360 * n;
  const y = (1 - Math.asinh(Math.tan(lat * Math.PI / 180)) / Math.PI) / 2 * n;
  return [x, y];
}
function tileLL(x, y, z) {
  const n = 2 ** z;
  return [Math.atan(Math.sinh(Math.PI * (1 - 2 * y / n))) * 180 / Math.PI, x / n * 360 - 180];
}
function winBounds(x0, y0, nx, ny) {
  const a = tileLL(x0, y0, 17), b = tileLL(x0 + nx, y0 + ny, 17);
  return L.latLngBounds([b[0], a[1]], [a[0], b[1]]);
}
function currentWin() {
  if (S.pendingWin) return S.pendingWin;
  const n = +$('#win-size').value, c = aimLatLng(), [fx, fy] = tileXY(c.lat, c.lng, 17);
  return {x0: Math.round(fx - n / 2), y0: Math.round(fy - n / 2), nx: n, ny: n};
}
function drawWinRect() {
  if (S.sample) { if (S.winRect) { map.removeLayer(S.winRect); S.winRect = null; } return; }
  const w = currentWin(), b = winBounds(w.x0, w.y0, w.nx, w.ny);
  if (!S.winRect) S.winRect = L.rectangle(b, {color: '#ffd400', weight: 2, dashArray: '6 4', fill: false, interactive: false}).addTo(map);
  else S.winRect.setBounds(b);
  if (map._winTimer) clearTimeout(map._winTimer);
  map._winTimer = setTimeout(async () => {
    try {
      const c = b.getCenter(), e = await api(`/api/samples/estimate?lon=${c.lng}&lat=${c.lat}&nx=${w.nx}&ny=${w.ny}`);
      $('#win-info').textContent = `طلبات Mapbox جديدة لهذه النافذة: ${e.new_tiles} (المتبقي اليوم ${e.budget.remaining}/${e.budget.limit})`;
    } catch (err) {}
  }, 250);
}
map.on('moveend zoomend', () => { if (!S.pendingWin) drawWinRect(); $('#zoomwarn').hidden = map.getZoom() <= 18; });

// ------------------------------------------------------------------ config / lists
async function init() {
  CFG = await api('/api/config');
  $('#imgnote').title = CFG.imagery_note;
  refreshBudget();
  const fill = (sel, obj, empty) => { const s = $(sel); s.innerHTML = (empty ? '<option value="">—</option>' : '') + Object.entries(obj).map(([k, v]) => `<option value="${k}">${v}</option>`).join(''); };
  fill('#m-terrain', CFG.terrain, true); fill('#m-clarity', CFG.clarity, true); fill('#t-clarity', CFG.clarity);
  $('#t-clarity').value = '2';
  $('#types').innerHTML = Object.entries(CFG.types).map(([k, v]) =>
    `<div class="tchip" data-type="${k}"><i style="background:${TYPE_COLORS[k]}"></i>${v}</div>`).join('');
  document.querySelectorAll('#types .tchip').forEach(el => el.onclick = () => setType(el.dataset.type));
  const SHORT = {faint: 'خافت'};
  $('#typebar').innerHTML = Object.entries(CFG.types).map(([k, v]) => `<div class="tchip" data-type="${k}"><i style="background:${TYPE_COLORS[k]}"></i>${SHORT[k] || v}</div>`).join('');
  document.querySelectorAll('#typebar .tchip').forEach(el => el.onclick = () => setType(el.dataset.type));
  setType('dirt'); updateAim();
  if (!CFG.has_token) hint('تنبيه: لا يوجد MAPBOX_ACCESS_TOKEN — لن تظهر صور جديدة (المخزنة فقط).');
  await loadSamples(); drawWinRect();
}
async function refreshBudget() {
  const b = (await api('/api/config')).budget;
  $('#budget').textContent = `طلبات اليوم: ${b.used}/${b.limit}`;
}
async function loadSamples() {
  const list = await api('/api/samples');
  $('#samples').innerHTML = list.map(s => `<li data-id="${s.sample_id}" class="${S.sample && S.sample.sample_id === s.sample_id ? 'cur' : ''}">
    <span><code>${s.sample_id}</code>${s.fixture ? ' <span class="pill">اختبار برمجي</span>' : ''}</span><span>${s.n_tracks} مسار</span></li>`).join('') || '<li class="muted">لا عينات بعد</li>';
  document.querySelectorAll('#samples li[data-id]').forEach(li => li.onclick = () => openSample(li.dataset.id));
}

// ------------------------------------------------------------------ sample create / open
async function createWindow() {
  const w = currentWin();
  hint('جارٍ جلب البلاطات وبناء GeoTIFF…');
  try {
    const r = await api('/api/samples/mosaic', {method: 'POST', headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({x0: w.x0, y0: w.y0, nx: w.nx, ny: w.ny})});
    S.pendingWin = null;
    await openSample(r.metadata.sample_id); refreshBudget();
    hint(r.existing ? 'العينة موجودة مسبقًا — فُتحت (لا طلبات جديدة).' : 'تم إنشاء عينة جديدة.');
  } catch (e) { hint('تعذر: ' + e.message); }
}
async function importTif(file) {
  const fd = new FormData(); fd.append('file', file);
  hint('جارٍ استيراد ' + file.name + '…');
  try {
    const r = await api('/api/samples/import', {method: 'POST', body: fd});
    await openSample(r.metadata.sample_id);
    hint(r.existing ? 'الصورة مستوردة سابقًا — فُتحت.' : 'تم الاستيراد مع الحفاظ على CRS والمحول.');
  } catch (e) { hint('تعذر الاستيراد: ' + e.message); }
}
async function openSample(id) {
  if (S.dirty && !confirm('توجد تعديلات غير محفوظة. تجاهلها؟')) return;
  clearAll();
  const r = await api('/api/samples/' + id);
  S.sample = r.metadata; S.dirty = false;
  const b = L.latLngBounds(r.preview.bounds);
  S.overlay = L.imageOverlay(`/api/samples/${id}/file/preview.jpg?t=${Date.now()}`, b, {opacity: 1, interactive: false}).addTo(map);
  S.outline = L.rectangle(b, {color: '#00e5ff', weight: 1, fill: false, interactive: false}).addTo(map);
  fitTo(b.pad(0.05));
  if (S.winRect) { map.removeLayer(S.winRect); S.winRect = null; }
  r.geojson.features.forEach(f => addFeat({id: f.properties.id, kind: f.properties.kind, track_id: f.properties.track_id,
    track_type: f.properties.track_type, clarity: f.properties.clarity,
    latlngs: f.geometry.coordinates.map(([x, y]) => [y, x])}));
  $('#cur').hidden = false; $('#toolbar').hidden = false; if (isMobile()) setSheet(false);
  $('#cur-id').textContent = id;
  $('#m-terrain').value = S.sample.terrain || ''; $('#m-clarity').value = S.sample.clarity || '';
  $('#m-notes').value = S.sample.notes || '';
  const g = S.sample.georef;
  $('#m-info').innerHTML = `CRS: <code>${g.crs.length > 20 ? 'EPSG:' + g.epsg : g.crs}</code> · ${g.width}×${g.height}px · ${g.ground_res_m.toFixed(3)} م/بكسل<br>
    المصدر: ${S.sample.source.type} · الترخيص: ${S.sample.license.status}${S.sample.fixture ? ' · <b class="bad">عينة اختبار برمجية</b>' : ''}`;
  setTool('select'); updateAim(); updateStats(); loadSamples(); renderQuality(null);
}
function clearAll() {
  S.feats.forEach(f => f.layer && map.removeLayer(f.layer)); S.feats = []; S.sel = null; S.history = [];
  clearHandles(); cancelDraft();
  ['overlay', 'outline', 'maskLayer'].forEach(k => { if (S[k]) { map.removeLayer(S[k]); S[k] = null; } });
  $('#chk-overlay').checked = false;
}

// ------------------------------------------------------------------ features
function style(f) {
  const sel = S.sel === f.id;
  if (f.kind === 'edge') return {pane: 'feat', color: '#00e5ff', weight: sel ? 3 : 2, dashArray: '5 4'};
  return {pane: 'feat', color: TYPE_COLORS[f.track_type] || '#fff', weight: sel ? 5 : 3, opacity: 1};
}
function addFeat(f) {
  f.layer = L.polyline(f.latlngs, {...style(f), renderer: cv}).addTo(map);
  f.layer.on('click', e => { if (S.tool === 'select') { L.DomEvent.stopPropagation(e); select(f.id); } });
  f.layer.on('dblclick', e => { if (S.tool === 'select' && S.sel === f.id) { L.DomEvent.stopPropagation(e); insertVertex(f, e.latlng); } });
  S.feats.push(f); return f;
}
const byId = id => S.feats.find(f => f.id === id);
function snapshot() { S.history.push(JSON.stringify(S.feats.map(({layer, ...r}) => r))); if (S.history.length > 100) S.history.shift(); }
function undo() {
  if (!S.history.length) return;
  const prev = JSON.parse(S.history.pop());
  S.feats.forEach(f => map.removeLayer(f.layer)); S.feats = []; S.sel = null; clearHandles();
  prev.forEach(addFeat); S.dirty = true; updateStats(); select(null);
}
function select(id) {
  S.sel = id; S.vtx = null; S.feats.forEach(f => f.layer.setStyle(style(f)));
  clearHandles();
  const f = byId(id);
  if (f && S.tool === 'select') showHandles(f);
  if (f && f.kind === 'centerline') { setType(f.track_type, true); $('#t-clarity').value = f.clarity; }
  updateToolbarUI();
  $('#sel-info').textContent = f ? (f.kind === 'edge' ? 'حافة محددة' : `مسار محدد: ${CFG.types[f.track_type]} · ${f.latlngs.length} نقطة`) : 'لا مسار محدد';
}
function clearHandles() { S.handles.forEach(h => map.removeLayer(h)); S.handles = []; }
function showHandles(f) {
  clearHandles();
  f.latlngs.forEach((ll, i) => {
    const act = S.vtx && S.vtx.id === f.id && S.vtx.i === i;
    const m = L.marker(ll, {draggable: true, icon: L.divIcon({className: '', html: `<div class="vtxwrap${act ? ' act' : ''}"><div class="vtx"></div></div>`, iconSize: [44, 44], iconAnchor: [22, 22]}), zIndexOffset: 1000}).addTo(map);
    m.on('dragstart', snapshot);
    m.on('drag', () => { const p = m.getLatLng(); f.latlngs[i] = [p.lat, p.lng]; f.layer.setLatLngs(f.latlngs); });
    m.on('dragend', () => { S.dirty = true; updateStats(); });
    m.on('click', () => { S.vtx = {id: f.id, i}; showHandles(f); updateToolbarUI(); hint('نقطة محددة: اسحبها أو «حذف نقطة»'); });
    m.on('contextmenu', () => deleteVertex(f, i));
    S.handles.push(m);
  });
}
function deleteVertex(f, i) {
  if (f.latlngs.length <= 2) { hint('الخط يحتاج نقطتين على الأقل — احذف المسار كاملًا بزر «حذف».'); return; }
  snapshot(); f.latlngs.splice(i, 1); f.layer.setLatLngs(f.latlngs); S.vtx = null; S.dirty = true; showHandles(f); updateStats(); updateToolbarUI();
}
function updateToolbarUI() {
  $('#btn-delvtx').hidden = !(S.vtx && byId(S.vtx.id) && S.tool === 'select');
  updateAim();
}
function insertVertex(f, latlng) {
  const pt = map.latLngToLayerPoint(latlng); let best = 0, bd = 1e9;
  for (let i = 0; i < f.latlngs.length - 1; i++) {
    const a = map.latLngToLayerPoint(f.latlngs[i]), b = map.latLngToLayerPoint(f.latlngs[i + 1]);
    const d = L.LineUtil.pointToSegmentDistance(pt, a, b); if (d < bd) { bd = d; best = i; }
  }
  snapshot(); f.latlngs.splice(best + 1, 0, [latlng.lat, latlng.lng]); f.layer.setLatLngs(f.latlngs);
  S.dirty = true; showHandles(f); updateStats();
}
function deleteSel() {
  const f = byId(S.sel); if (!f) { hint('حدّد مسارًا أولًا (انقره) ثم اضغط حذف.'); return; } snapshot();
  const rm = f.kind === 'centerline' ? S.feats.filter(x => x.id === f.id || x.track_id === f.id) : [f];
  rm.forEach(x => { map.removeLayer(x.layer); S.feats.splice(S.feats.indexOf(x), 1); });
  S.sel = null; clearHandles(); S.dirty = true; select(null); updateStats();
}

// ------------------------------------------------------------------ drawing
function setTool(t) {
  cancelDraft(); S.tool = t; S.vtx = null;
  document.querySelectorAll('#toolbar [data-tool]').forEach(b => b.classList.toggle('on', b.dataset.tool === t));
  map.getContainer().style.cursor = t === 'select' ? '' : 'crosshair'; updateToolbarUI();
  if (t === 'select') { if (S.sel) showHandles(byId(S.sel)); hint('انقر مسارًا لتحديده؛ اسحب النقاط للتعديل؛ نقر مزدوج على الخط لإضافة نقطة؛ نقر يمين على نقطة لحذفها.'); }
  else { clearHandles(); hint(S.aim ? 'حرّك الخريطة حتى يقع المؤشر على الدرب ثم «＋ نقطة»' : t === 'edge' ? 'ارسم الحافة: انقر لإضافة نقاط، نقر مزدوج أو Enter للإنهاء (يلزم تحديد مسار أولًا).' : 'ارسم خط وسط المسار: انقر لإضافة نقاط، نقر مزدوج أو Enter للإنهاء، Backspace يحذف آخر نقطة.'); }
}
function cancelDraft() { if (S.draft) { map.removeLayer(S.draft.layer); if (S.draft.rubber) map.removeLayer(S.draft.rubber); S.draft = null; } }
function addPoint(latlng) {
  if (!S.sample || S.tool === 'select') return;
  if (S.tool === 'edge' && !(S.draft || (byId(S.sel) && byId(S.sel).kind === 'centerline'))) { hint('حدّد مسارًا (خط وسط) أولًا بأداة التحديد ثم ارسم حافته.'); return; }
  if (!S.draft) {
    S.draft = {pts: [], layer: L.polyline([], {pane: 'feat', color: S.tool === 'edge' ? '#00e5ff' : TYPE_COLORS[S.type], weight: 3, dashArray: '2 6'}).addTo(map),
               rubber: L.polyline([], {pane: 'feat', color: '#fff', weight: 1, dashArray: '3 5', interactive: false}).addTo(map), parent: S.sel};
  }
  const last = S.draft.pts[S.draft.pts.length - 1];
  if (last && Math.abs(last[0] - latlng.lat) < 1e-10 && Math.abs(last[1] - latlng.lng) < 1e-10) return;
  S.draft.pts.push([latlng.lat, latlng.lng]); S.draft.layer.setLatLngs(S.draft.pts);
  hint(`${S.draft.pts.length} نقطة — تابع أو اضغط «إنهاء»`);
}
map.on('click', e => {
  if (document.body.classList.contains('sheet-open') && isMobile()) { setSheet(false); return; }   // tap on map closes the sheet only
  if (!S.sample) return;
  if (S.tool === 'select') { select(null); return; }
  if (S.aim) return;            // crosshair mode: points only via the + button
  addPoint(e.latlng);
});
map.on('move', () => { if (S.draft && S.draft.pts.length && S.aim) S.draft.rubber.setLatLngs([S.draft.pts[S.draft.pts.length - 1], aimLatLng()]); });
map.on('mousemove', e => { if (S.draft && S.draft.pts.length && !S.aim) S.draft.rubber.setLatLngs([S.draft.pts[S.draft.pts.length - 1], e.latlng]); });
map.on('dblclick', () => { if (!isMobile()) finishDraft(); });
function finishDraft() {
  const d = S.draft; if (!d) return;
  if (d.pts.length < 2) { cancelDraft(); return; }
  snapshot();
  const pts = d.pts.slice(); const parent = d.parent; cancelDraft();
  const f = S.tool === 'edge'
    ? {id: uid(), kind: 'edge', track_id: parent, latlngs: pts}
    : {id: uid(), kind: 'centerline', track_type: S.type, clarity: +$('#t-clarity').value, latlngs: pts};
  if (f.kind === 'centerline') f.track_id = f.id;
  addFeat(f); S.dirty = true; updateStats();
  if (f.kind === 'centerline') { S.sel = f.id; S.feats.forEach(x => x.layer.setStyle(style(x))); }
  hint(f.kind === 'edge' ? 'أُضيفت الحافة. ارسم الأخرى أو انتقل لأداة التحديد.' : 'أُضيف خط الوسط. اضغط E لرسم حافتيه (اختياري) أو C لمسار آخر.');
}

// ------------------------------------------------------------------ type / meta / stats / save
function setType(t, fromSel) {
  S.type = t; document.querySelectorAll('.tchip').forEach(c => c.classList.toggle('on', c.dataset.type === t));
  const f = byId(S.sel);
  if (!fromSel && f && f.kind === 'centerline' && S.tool === 'select') { snapshot(); f.track_type = t; f.layer.setStyle(style(f)); S.dirty = true; updateStats(); }
}
$('#t-clarity').onchange = () => { const f = byId(S.sel); if (f && f.kind === 'centerline') { snapshot(); f.clarity = +$('#t-clarity').value; S.dirty = true; } };
function lenM(ll) { let s = 0; for (let i = 1; i < ll.length; i++) s += L.latLng(ll[i - 1]).distanceTo(L.latLng(ll[i])); return s; }
function updateStats() {
  const by = {}; let edges = 0;
  S.feats.forEach(f => { if (f.kind === 'edge') edges++; else { const b = by[f.track_type] = by[f.track_type] || {n: 0, m: 0}; b.n++; b.m += lenM(f.latlngs); } });
  $('#stats').innerHTML = '<table>' + Object.entries(by).map(([t, b]) => `<tr><td><i class="pill" style="background:${TYPE_COLORS[t]};color:#000">${CFG.types[t]}</td><td>${b.n} مسار</td><td>${(b.m).toFixed(0)} م</td></tr>`).join('') + `</table>
    <div class="muted">حواف: ${edges}${S.dirty ? ' · <b class="bad">غير محفوظ</b>' : ''}</div>`;
}
function renderQuality(q) {
  $('#quality').innerHTML = q ? `<div class="card"><b class="${q.ok ? 'ok' : 'bad'}">فحص الجودة: ${q.ok ? 'سليم' : 'ملاحظات'}</b>
    <div class="muted">تغطية القناع ${q.coverage ?? '-'} · p95 انحراف ${q.p95_offset_px ?? '-'} px · عرض فعلي ${q.mean_width_m ?? '-'} م · recall ${q.line_recall ?? '-'}</div>
    ${(q.problems || []).map(p => `<div class="bad">• ${p}</div>`).join('')}</div>` : '';
}
async function save() {
  if (!S.sample) return;
  const fc = {type: 'FeatureCollection', features: S.feats.map(f => ({type: 'Feature',
    properties: f.kind === 'edge' ? {id: f.id, kind: 'edge', track_id: f.track_id} : {id: f.id, kind: 'centerline', track_type: f.track_type, clarity: f.clarity},
    geometry: {type: 'LineString', coordinates: f.latlngs.map(([a, b]) => [b, a])}}))};
  const body = {geojson: fc, terrain: $('#m-terrain').value || null, clarity: $('#m-clarity').value ? +$('#m-clarity').value : null, notes: $('#m-notes').value};
  try {
    const r = await api(`/api/samples/${S.sample.sample_id}/annotations`, {method: 'PUT', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(body)});
    S.sample = r.metadata; S.dirty = false; updateStats(); renderQuality(r.quality); loadSamples();
    hint('حُفظت العينة (صورة، GeoJSON، قناع، بيانات وصفية).'); if ($('#chk-overlay').checked) showMask(true);
  } catch (e) { hint('تعذر الحفظ: ' + e.message); }
}
function showMask(on) {
  if (S.maskLayer) { map.removeLayer(S.maskLayer); S.maskLayer = null; }
  if (on && S.sample) S.maskLayer = L.imageOverlay(`/api/samples/${S.sample.sample_id}/file/overlay.png?t=${Date.now()}`, S.overlay.getBounds(), {opacity: .9, interactive: false}).addTo(map);
}

// ------------------------------------------------------------------ batch + export
async function loadBatch() {
  $('#batch').innerHTML = '<div class="muted">جارٍ التحليل…</div>';
  const b = await api('/api/collection/batch');
  if (!b.windows) { $('#batch').innerHTML = `<div class="card">${b.message || 'لا حاجة لدفعة.'}</div>`; return; }
  if (S.batchLayer) map.removeLayer(S.batchLayer);
  S.batchLayer = L.layerGroup().addTo(map);
  b.windows.forEach((w, i) => {
    const r = L.rectangle([[w.bbox[1], w.bbox[0]], [w.bbox[3], w.bbox[2]]], {color: w.state === 'pending' ? '#ffd400' : '#555', weight: 1, fill: false}).addTo(S.batchLayer);
    r.bindTooltip(String(i + 1), {permanent: true, direction: 'center', className: 'winlabel'});
  });
  $('#batch').innerHTML = `<h3>الأنواع الناقصة (${b.batch_id})</h3>` + b.missing_types.map(m => `
    <div><b>${m.label}</b> <span class="muted">لديك ${m.have.tracks} مسار · ${m.have.length_km} كم · ${m.have.regions} منطقة — المطلوب +${m.need.tracks} مسار، +${m.need.length_km} كم، +${m.need.regions} منطقة</span>
    <div class="bar"><div style="width:${Math.round(m.progress * 100)}%"></div></div></div>`).join('') +
    `<h3>النوافذ المقترحة (${b.windows.filter(w => w.state === 'pending').length} معلّقة من ${b.windows.length})</h3>` +
    b.windows.map((w, i) => `<div class="card ${w.state !== 'pending' ? 'done' : ''}"><b>${i + 1}.</b> <code>${w.centre[1].toFixed(4)}, ${w.centre[0].toFixed(4)}</code>
      ${w.for_types.map(t => `<span class="pill" style="background:${TYPE_COLORS[t]};color:#000">${CFG.types[t]}</span>`).join('')}
      <div class="muted">${w.hint_note}</div>
      ${w.state === 'pending' ? `<button data-open="${i}">افتح النافذة</button> <button data-skip="${w.id}">تخطي</button>` : `<span class="muted">${w.state}</span>`}</div>`).join('');
  document.querySelectorAll('[data-open]').forEach(btn => btn.onclick = () => {
    const w = b.windows[+btn.dataset.open]; S.pendingWin = {x0: w.tiles.x0, y0: w.tiles.y0, nx: w.tiles.nx, ny: w.tiles.ny};
    if (S.sample) { if (S.dirty && !confirm('تعديلات غير محفوظة. تجاهل؟')) return; clearAll(); S.sample = null; $('#cur').hidden = true; $('#toolbar').hidden = true; }
    updateAim();
    map.fitBounds(winBounds(w.tiles.x0, w.tiles.y0, w.tiles.nx, w.tiles.ny).pad(0.15)); drawWinRect(); setTab('sample'); if (isMobile()) setSheet(false);
    hint('النافذة محددة من الدفعة — اضغط «جلب النافذة».');
  });
  document.querySelectorAll('[data-skip]').forEach(btn => btn.onclick = async () => { await api('/api/collection/skip', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({window_id: btn.dataset.skip, reason: 'تخطّاها المالك'})}); loadBatch(); });
}
async function doExport() {
  $('#export-out').innerHTML = '<div class="muted">جارٍ التصدير…</div>';
  try {
    const r = await api('/api/export', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({gsd: +$('#x-gsd').value, include_fixtures: $('#x-fix').checked})});
    $('#export-out').innerHTML = `<div class="card"><b class="${r.ready_for_training ? 'ok' : 'bad'}">جاهز للتدريب: ${r.ready_for_training ? 'نعم' : 'لا'}</b>
      <div>السلامة: ${r.integrity_passed ? '<span class=ok>نجحت</span>' : '<span class=bad>فشلت</span>'}</div>
      <div class="muted">تدريب ${r.counts.train} · تحقق ${r.counts.validation} · اختبار ${r.counts.test}</div>
      <code>${r.path}</code>${r.sufficiency_issues.map(i => `<div class="bad">• ${i}</div>`).join('')}</div>`;
  } catch (e) { $('#export-out').innerHTML = `<div class="card bad">${e.message}</div>`; }
}
function setSheet(open) { document.body.classList.toggle('sheet-open', open); setTimeout(() => { updateAim(); if (!S.pendingWin) drawWinRect(); }, 50); }
function setTab(t, fromUser) {
  if (isMobile() && fromUser) { const same = document.body.classList.contains('sheet-open') && $('#tabs button.on').dataset.tab === t; setSheet(!same); }
  document.querySelectorAll('#tabs button').forEach(b => b.classList.toggle('on', b.dataset.tab === t));
  ['sample', 'batch', 'export'].forEach(x => $('#tab-' + x).hidden = x !== t);
}

// ------------------------------------------------------------------ wiring
document.querySelectorAll('#tabs button').forEach(b => b.onclick = () => setTab(b.dataset.tab, true));
document.querySelectorAll('#toolbar [data-tool]').forEach(b => b.onclick = () => setTool(b.dataset.tool));
$('#btn-add').onclick = () => { if (S.tool === 'select') { hint('اختر «خط الوسط» أو «حافة» أولًا.'); return; } addPoint(aimLatLng()); };
$('#btn-aim').onclick = () => { S.aim = !S.aim; updateAim(); hint(S.aim ? 'وضع التصويب: ＋ نقطة تضيف عند المؤشر' : 'وضع اللمس المباشر: المس الخريطة لإضافة نقطة'); };
$('#btn-delvtx').onclick = () => { const f = S.vtx && byId(S.vtx.id); if (f) deleteVertex(f, S.vtx.i); };
$('#btn-finish').onclick = finishDraft; $('#btn-undo').onclick = undo; $('#btn-del').onclick = deleteSel; $('#btn-save').onclick = save;
$('#btn-win').onclick = createWindow; $('#fab-win').onclick = () => { setSheet(false); createWindow(); }; $('#btn-batch').onclick = loadBatch; $('#btn-export').onclick = doExport;
$('#win-size').onchange = () => { S.pendingWin = null; drawWinRect(); };
$('#chk-overlay').onchange = e => showMask(e.target.checked);
$('#file-tif').onchange = e => e.target.files[0] && importTif(e.target.files[0]);
['m-terrain', 'm-clarity', 'm-notes'].forEach(id => $('#' + id).onchange = () => { S.dirty = true; updateStats(); });
window.addEventListener('keydown', e => {
  if (['INPUT', 'TEXTAREA', 'SELECT'].includes(document.activeElement.tagName)) return;
  const k = e.key.toLowerCase();
  if ((e.ctrlKey || e.metaKey) && k === 'z') { e.preventDefault(); undo(); }
  else if ((e.ctrlKey || e.metaKey) && k === 's') { e.preventDefault(); save(); }
  else if (k === 'enter') finishDraft();
  else if (k === 'escape') { cancelDraft(); setTool('select'); }
  else if (k === 'backspace' && S.draft) { S.draft.pts.pop(); S.draft.layer.setLatLngs(S.draft.pts); }
  else if (k === 'delete' || (k === 'backspace' && S.sel)) deleteSel();
  else if (k === 'v') setTool('select'); else if (k === 'c' && S.sample) setTool('centerline'); else if (k === 'e' && S.sample) setTool('edge');
});
const drop = $('#drop');
['dragenter', 'dragover'].forEach(ev => window.addEventListener(ev, e => { e.preventDefault(); drop.hidden = false; }));
['dragleave', 'drop'].forEach(ev => window.addEventListener(ev, e => { e.preventDefault(); if (ev === 'drop' || e.target === drop) drop.hidden = true; }));
window.addEventListener('drop', e => { const f = e.dataTransfer.files[0]; if (f) importTif(f); });
window.addEventListener('beforeunload', e => { if (S.dirty) { e.preventDefault(); e.returnValue = ''; } });
window.__annot = {S, map, openSample, save};
init();
