#!/usr/bin/env python3
"""Render the owner's review cards (read-only deck) for a blind re-judgement with MY rubric. python -I 09_render_cards.py <data_dir> <deck.json>"""
import sys, json, random
from PIL import Image, ImageDraw
sys.path.insert(0, '/Users/m4pro/code/map-wt/desertmaps-study/docs/desertmaps-study/scripts'); import tilelib as T
D, DECK = sys.argv[1], sys.argv[2]
deck = json.load(open(DECK))['cards']
cards = [c for c in deck if c['source'] == 'desertmaps_new' and not c.get('control')]
random.seed(5); random.shuffle(cards)           # blind order, no verdict shown
import os; os.makedirs(f'{D}/review2', exist_ok=True)
tl = set()
for c in cards:
    x, y = T.lonlat_to_tilef(*c['mid'])
    for tx in range(int(x) - 1, int(x) + 2):
        for ty in range(int(y) - 1, int(y) + 2): tl.add((tx, ty))
T.fetch_many(sorted(tl))
ids = []
for k, c in enumerate(cards):
    x, y = T.lonlat_to_tilef(*c['mid']); tx0, ty0 = int(x) - 1, int(y) - 1
    im, _ = T.mosaic(tx0, ty0, int(x) + 1, int(y) + 1)
    cx, cy = (x - tx0) * 512, (y - ty0) * 512; box = (int(cx - 512), int(cy - 512), int(cx + 512), int(cy + 512))
    raw = im.crop(box); ov = raw.copy(); d = ImageDraw.Draw(ov)
    pts = [((T.lonlat_to_tilef(lo, la)[0] - tx0) * 512 - box[0], (T.lonlat_to_tilef(lo, la)[1] - ty0) * 512 - box[1]) for lo, la in c['line']]
    d.line(pts, fill=(255, 40, 40), width=2)
    pair = Image.new('RGB', (1800, 900)); pair.paste(raw.resize((896, 896)), (2, 2)); pair.paste(ov.resize((896, 896)), (902, 2))
    ImageDraw.Draw(pair).text((8, 8), f'K{k:02d}', fill=(255, 255, 0))
    pair.save(f'{D}/review2/K{k:02d}.jpg', quality=85); ids.append((f'K{k:02d}', c['pid']))
json.dump(dict(ids), open(f'{D}/review2/key.json', 'w'))
for s in range(0, len(ids), 3):
    sh = Image.new('RGB', (1500, 750 * len(ids[s:s + 3])))
    for j, (kid, _) in enumerate(ids[s:s + 3]): sh.paste(Image.open(f'{D}/review2/{kid}.jpg').resize((1500, 750)), (0, 750 * j))
    sh.save(f'{D}/review2/sheet_{s // 3:02d}.jpg', quality=80)
print(len(ids))
