#!/usr/bin/env python3
"""Rank candidate review cards (DesertMaps 'unverified' pieces, not yet reviewed) by expected gain for NOVEL-track recall.
score = P(real track | stratum) x novelty(distance to OSM) x coverage_gap(region reviewed so far) x model_uncertainty(round-1 model on the window).
Output is deck-compatible JSON (annotation-tool review cards) + a strata table. usage: 13_rank_next_batch.py <data_dir> <deck.json> <verdicts.jsonl> (research .sam-venv python)"""
import os, sys, json, math, random, collections
os.environ['PYTORCH_ENABLE_MPS_FALLBACK'] = '1'
import numpy as np, torch, shapely
from shapely.geometry import shape, LineString
from shapely import STRtree
from pyproj import Transformer, Geod
from PIL import Image
D, DECK, VERD = sys.argv[1:4]
sys.path.insert(0, '/Users/m4pro/code/map-wt/desertmaps-study/docs/desertmaps-study/scripts'); import tilelib as T
RO = '/Users/m4pro/farq-map/research/sary-albarq-road-extraction'; REPO = f'{RO}/vendor/sam_road'
random.seed(20261113); GEOD = Geod(ellps='WGS84')
tr = Transformer.from_crs(4326, 32638, always_xy=True)
P = lambda g: shapely.transform(g, lambda a: np.column_stack(tr.transform(a[:, 0], a[:, 1])))
deck = {c['pid']: c for c in json.load(open(DECK))['cards']}; V = [json.loads(l) for l in open(VERD)]
reviewed_parents = set(); reviewed_pts = []
for v in V:
    c = deck[v['pid']]; reviewed_pts.append(c['mid'])
    if v['source'] == 'desertmaps_new' and v['pid'].startswith('dm-dm-'): reviewed_parents.add('-'.join(v['pid'].split('-')[1:4]))
# ---- strata evidence (owner verdicts, desertmaps_new, non-control)
osm = [P(shape(f['geometry'])) for f in json.load(open(f'{RO}/output/saudi_osm_desert_tracks_weak_labels.geojson'))['features']]; otree = STRtree(osm)
def med_dist(line):
    g = P(LineString(line)); pts = shapely.line_interpolate_point(g, np.linspace(0, g.length, 15))
    return float(np.median(otree.query_nearest(pts, return_distance=True, all_matches=False)[1]))
ev = collections.defaultdict(lambda: [0, 0])
for v in V:
    c = deck[v['pid']]
    if v['source'] != 'desertmaps_new' or v.get('control'): continue
    for key in ((c['region'], 'near' if med_dist(c['line']) < 40 else 'far'), (c['region'], 'all'), ('ALL', 'near' if med_dist(c['line']) < 40 else 'far'), ('ALL', 'all')):
        ev[key][1] += 1; ev[key][0] += v['verdict'] == 'correct'
prior = {'ALL': (25, 32)}                               # global approval 25/32 = prior mean
def wil(k, n, z=1.96):
    if n == 0: return (0.0, 1.0)
    p = k / n; d = 1 + z * z / n; c = p + z * z / (2 * n); h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)); return ((c - h) / d, (c + h) / d)
# my own 100-sample random review (stricter rubric) is the prior for regions the owner has not seen: B-stratum lenient rate 18/44
MY_LENIENT = {'الشرقية': (6, 14), 'الرياض': (3, 8), 'حائل': (4, 8), 'المدينة المنورة': (2, 5), 'تبوك': (2, 2), 'الحدود الشمالية': (1, 3), 'نجران': (1, 1), 'عسير': (0, 2), 'مكة المكرمة': (0, 1)}
def p_real(region, near):
    k, n = ev.get((region, 'all'), [0, 0]); a, b = MY_LENIENT.get(region, (0, 0))
    # shrink owner data (weight 1) + my lenient data (weight 0.5) + global prior (weight 4 pseudo-obs at 0.7)
    num = k + 0.5 * a + 0.7 * 4; den = n + 0.5 * b + 4; return num / den
# ---- model (round-1 fine-tune) for uncertainty
sys.path.insert(0, REPO); sys.path.insert(0, f'{REPO}/sam'); cwd = os.getcwd(); os.chdir(REPO)
from model import SAMRoad
from utils import load_config
cfg = load_config(f'{REPO}/config/toponet_vitb_256_spacenet.yaml'); cfg.SAM_CKPT_PATH = f'{REPO}/{cfg.SAM_CKPT_PATH}'
model = SAMRoad(cfg); model.load_state_dict(torch.load(f'{D}/runs/ft_v1_state.pt', map_location='cpu')); os.chdir(cwd); dev = torch.device('mps'); model.to(dev).eval()
# ---- candidates
feats = [f for f in json.load(open(f'{D}/geojson/desertmaps_cleaned_v1.geojson'))['features'] if f['properties']['tier'] == 'unverified' and f['properties']['piece_length_km'] >= 0.1]
random.shuffle(feats)
def cut(coords, s0, s1):
    d = [0.0]
    for i in range(1, len(coords)): d.append(d[-1] + GEOD.inv(*coords[i - 1], *coords[i])[2])
    def at(s):
        for i in range(1, len(d)):
            if d[i] >= s:
                t = (s - d[i - 1]) / max(d[i] - d[i - 1], 1e-9); return [coords[i - 1][0] + t * (coords[i][0] - coords[i - 1][0]), coords[i - 1][1] + t * (coords[i][1] - coords[i - 1][1])]
        return list(coords[-1])
    return [at(s0)] + [list(coords[i]) for i in range(len(coords)) if s0 < d[i] < s1] + [at(s1)], d[-1]
cands = []
for f in feats:
    p = f['properties']; coords = f['geometry']['coordinates']; pid_parent = p['fid']
    if pid_parent in reviewed_parents: continue
    tot = sum(GEOD.inv(*coords[i - 1], *coords[i])[2] for i in range(1, len(coords)))
    L = min(tot, 260.0); s = random.uniform(0, tot - L); line, _ = cut(coords, s, s + L)
    mid = cut(coords, tot / 2 if tot < 260 else s + L / 2, (tot / 2 if tot < 260 else s + L / 2) + 0.01)[0][0]
    if any(abs(mid[0] - m[0]) < 0.004 and abs(mid[1] - m[1]) < 0.004 for m in reviewed_pts): continue
    cands.append(dict(parent=pid_parent, region=p['region'], line=[[round(a, 7), round(b, 7)] for a, b in line], mid=[round(mid[0], 7), round(mid[1], 7)], length_m=round(L, 1)))
    if len(cands) >= 700: break
print('candidates', len(cands))
tiles = set()
for c in cands:
    x, y = T.lonlat_to_tilef(*c['mid']); c['t'] = (int(x), int(y)); tiles.add(c['t'])
T.fetch_many(sorted(tiles), 4)
for i in range(0, len(cands), 16):
    batch = cands[i:i + 16]; imgs = []
    for c in batch:
        p = T.fetch(*c['t']); imgs.append(np.asarray(Image.open(p).convert('RGB').resize((256, 256), Image.BOX)) if p else np.zeros((256, 256, 3), np.uint8))
    with torch.inference_mode():
        s, _ = model.infer_masks_and_img_features(torch.from_numpy(np.stack(imgs)).float().to(dev)); pr = s[..., 1].cpu().numpy()
    for c, p_, im in zip(batch, pr, imgs):
        # model probability sampled along the window line (pixel coords inside the tile; clipped)
        xs = [min(max((T.lonlat_to_tilef(lo, la)[0] - c['t'][0]) * 256, 0), 255) for lo, la in c['line']]; ys = [min(max((T.lonlat_to_tilef(lo, la)[1] - c['t'][1]) * 256, 0), 255) for lo, la in c['line']]
        c['model_prob'] = float(np.mean([p_[int(y), int(x)] for x, y in zip(xs, ys)]))
        a = im.astype(float); lum = a.mean(); sat = float(((a.max(2) - a.min(2)) / np.maximum(a.max(2), 1)).mean())
        c['terrain'] = 'rocky_dark' if lum < 110 else ('sand_orange' if sat > 0.28 else 'gravel_plain')
for c in cands:
    c['dist_osm_m'] = med_dist(c['line']); near = c['dist_osm_m'] < 40
    pr = p_real(c['region'], near)
    novelty = 0.4 if near else 1.0
    rev = ev.get((c['region'], 'all'), [0, 0])[1]; gap = 1.0 / (1.0 + rev / 8.0)
    unc = 1.0 - 2 * abs(c['model_prob'] - 0.4) if c['model_prob'] < 0.9 else 0.1   # undecided model = most to learn; confident-high = already known
    unc = max(unc, 0.1)
    c['score'] = round(pr * novelty * (0.5 + gap) * (0.4 + unc), 4); c['p_real'] = round(pr, 3)
cands.sort(key=lambda c: -c['score'])
# diversity cap: <=30% per region, <=50% per terrain in the top 120
top, cnt, cnt_t = [], collections.Counter(), collections.Counter()
for c in cands:
    if cnt[c['region']] >= 36 or cnt_t[c['terrain']] >= 60: continue
    top.append(c); cnt[c['region']] += 1; cnt_t[c['terrain']] += 1
    if len(top) >= 120: break
cards = []
for i, c in enumerate(top):
    fx, fy = T.lonlat_to_tilef(*c['mid']); x0, y0 = int(math.floor(fx - 0.5)), int(math.floor(fy - 0.5))
    cards.append(dict(pid=f"dm-{c['parent']}-r2-{i}", source='desertmaps_new', detail=f"{c['region']} · جديد · rank {i + 1}", conf=None, line=c['line'], mid=c['mid'], length_m=c['length_m'], x0=x0, y0=y0,
                      type_hint='dirt', type_source='default', control=None, region=c['region'], non_osm=True, value=c['score'],
                      why=[f"P(درب حقيقي) تقديرية {c['p_real']}", f"بُعد OSM ≈ {c['dist_osm_m']:.0f} م", f"احتمال النموذج على الخط {c['model_prob']:.2f}", f"تضاريس تقريبية: {c['terrain']}"], idx=i))
strata = []
for (reg, kind), (k, n) in sorted(ev.items(), key=lambda kv: (kv[0][0], kv[0][1])):
    lo, hi = wil(k, n); strata.append(dict(region=reg, osm_distance=kind, owner_approved=k, owner_n=n, approval=round(k / n, 3) if n else None, wilson95=[round(lo, 3), round(hi, 3)]))
out = dict(created='2026-11-13', method='score = P(real|region; owner verdicts + 0.5x my lenient rate + prior) x novelty(near OSM<40m: 0.4, far: 1.0) x (0.5+coverage_gap) x (0.4+model_uncertainty); caps: <=36 cards/region, <=60/terrain',
           caveats=['approval = owner verdict (a track is there), not centreline accuracy', 'strata n are tiny; regions with no owner cards use my stricter own review as a weak prior', 'terrain is a crude image heuristic'],
           strata_evidence=strata, regions_unreviewed_by_owner=[r for r in MY_LENIENT if ev.get((r, 'all'), [0, 0])[1] == 0], composition=dict(region=dict(cnt), terrain=dict(cnt_t)), cards=cards)
json.dump(out, open(f'{D}/next_batch_ranking.json', 'w'), ensure_ascii=False, indent=1); print(json.dumps(dict(composition=out['composition'], unreviewed=out['regions_unreviewed_by_owner']), ensure_ascii=False))
