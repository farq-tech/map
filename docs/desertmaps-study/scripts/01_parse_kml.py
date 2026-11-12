#!/usr/bin/env python3 -I
"""Parse DesertMaps My Maps KML (untrusted input) -> GeoJSON LineStrings with provenance.
Run: python3 -I 01_parse_kml.py <data_dir>   (data_dir holds kml/ and manifest_regions.json)"""
import sys, json, hashlib, glob, os, math
import xml.etree.ElementTree as ET
from pyproj import Geod
K = '{http://www.opengis.net/kml/2.2}'
geod = Geod(ellps='WGS84')
D = sys.argv[1]
REG = json.load(open(f'{D}/regions.json'))
RIGHTS = 'owner-declared (no contract supplied)'
FOLDER_KIND = {'طرق صحراوية': 'desert_road_line', 'رسم حدود': 'boundary_line', 'حدود': 'boundary_line'}

def coords(txt):
    out = []
    for tok in txt.split():
        p = tok.split(',')
        if len(p) >= 2:
            try: out.append((float(p[0]), float(p[1])))
            except ValueError: pass
    return out

feats = []; summary = {}; pts = {}
for r in REG:
    f = f"{D}/kml/{r['map_id']}.kml"
    raw = open(f, 'rb').read(); sha = hashlib.sha256(raw).hexdigest()
    root = ET.fromstring(raw)
    doc = root.find(K + 'Document')
    styles = {}
    for s in doc.findall(K + 'Style'):
        ls = s.find(K + 'LineStyle')
        if ls is not None: styles['#' + s.get('id')] = (ls.findtext(K + 'color'), ls.findtext(K + 'width'))
    for sm in doc.findall(K + 'StyleMap'):
        for p in sm.findall(K + 'Pair'):
            if p.findtext(K + 'key') == 'normal': styles['#' + sm.get('id')] = styles.get(p.findtext(K + 'styleUrl'))
    n = {'lines': 0, 'polygons': 0, 'points': 0}; km = 0
    for fo in doc.findall(K + 'Folder'):
        fname = fo.findtext(K + 'name') or ''
        for pm in fo.iter(K + 'Placemark'):
            ls_all = pm.findall('.//' + K + 'LineString')
            pg = pm.findall('.//' + K + 'Polygon')
            if not ls_all and not pg:
                n['points'] += 1; continue
            geoms = []
            for l in ls_all:
                c = coords(l.findtext(K + 'coordinates') or '')
                if len(c) >= 2: geoms.append(('LineString', c))
            for p in pg:
                c = coords(p.findtext('.//' + K + 'outerBoundaryIs/' + K + 'LinearRing/' + K + 'coordinates') or '')
                if len(c) >= 3: geoms.append(('PolygonRing', c))
            st = styles.get(pm.findtext(K + 'styleUrl'))
            for gt, c in geoms:
                L = geod.line_length([x for x, y in c], [y for x, y in c]) / 1000
                kind = FOLDER_KIND.get(fname, 'other_line')
                if gt == 'PolygonRing':
                    kind = 'polygon_ring'; n['polygons'] += 1
                else: n['lines'] += 1; km += L
                feats.append({'type': 'Feature', 'properties': {
                    'source': 'desertmaps', 'rights': RIGHTS, 'region': r['region'], 'map_id': r['map_id'],
                    'map_url': r['map_url'], 'kml_url': r['kml_url'], 'kml_file': f"kml/{r['map_id']}.kml",
                    'kml_sha256': sha, 'retrieved': '2026-11-12', 'folder': fname,
                    'name': (pm.findtext(K + 'name') or '').strip(), 'style_color': st[0] if st else None,
                    'style_width': st[1] if st else None, 'desc': (pm.findtext(K + 'description') or '').strip()[:500] or None,
                    'geom_src': gt, 'line_kind_folder': kind, 'n_vertices': len(c), 'length_km': round(L, 4)},
                    'geometry': {'type': 'LineString', 'coordinates': c}})
    summary[r['region']] = {**n, 'line_km': round(km, 2), 'sha256': sha}
for i, ft in enumerate(feats): ft['properties']['fid'] = f"dm-{ft['properties']['map_id'][:6]}-{i:05d}"
json.dump({'type': 'FeatureCollection', 'features': feats}, open(f'{D}/geojson/desertmaps_all_lines.geojson', 'w'), ensure_ascii=False)
json.dump(summary, open(f'{D}/geojson/parse_summary.json', 'w'), ensure_ascii=False, indent=1)
print(json.dumps(summary, ensure_ascii=False, indent=1))
