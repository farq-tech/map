#!/usr/bin/env python3
"""Build owner-review cards (track-annotator batch format) from OBF tracks that are NOT in our OSM data.

Inputs : tracks.geojson.gz (extract_obf.py) + tracks_scored.json.gz (compare_osm.py)
Output : rahal_new_cards.json   {"created","method","caveats","strata_evidence","composition","cards":[...]}

Selection
  tier B : (default) OSM-id present in the reference pbf, highway=track/path, and >=80 % of its length farther than 30 m
           from our older OSM snapshot (weak labels) -> mapped in OSM AFTER our snapshot, i.e. new for US, not Rahal-original
  tier A : (only with --allow-tier-a) >=80 % farther than 30 m from ANY OSM highway of the pbf; in practice these are
           ways outside the pbf clip (neighbouring countries), still real OSM ways -> off by default
  always : length >= --min-len m (default 500), desert-like surroundings (<= --max-density OSM ways within 800 m),
           track/path/unclassified (no service roads), <= --per-cell cards per 0.5 deg cell for spatial spread.
Each card carries one <=260 m window taken from the middle of the track.
The card ``source`` must be a key of annotator.review.SOURCE_LABELS in the running tool (see --source).
"""
from __future__ import annotations

import argparse
import gzip
import json
import math
import sys
from collections import Counter, defaultdict
from pathlib import Path

R = 6371008.8


def hav(a, b):
    p1, p2 = math.radians(a[1]), math.radians(b[1])
    dl = math.radians(b[0] - a[0])
    h = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * R * math.asin(min(1, math.sqrt(h)))


def window(coords, win=260.0):
    """Return (line, mid) for the <=win metre part around the middle of the polyline."""
    cum = [0.0]
    for a, b in zip(coords, coords[1:]):
        cum.append(cum[-1] + hav(a, b))
    L = cum[-1]
    s0, s1 = max(0.0, L / 2 - win / 2), min(L, L / 2 + win / 2)

    def at(s):
        for i in range(len(cum) - 1):
            if cum[i] <= s <= cum[i + 1]:
                t = 0 if cum[i + 1] == cum[i] else (s - cum[i]) / (cum[i + 1] - cum[i])
                return [coords[i][0] + (coords[i + 1][0] - coords[i][0]) * t,
                        coords[i][1] + (coords[i + 1][1] - coords[i][1]) * t]
        return coords[-1]

    line = [at(s0)] + [c for c, s in zip(coords, cum) if s0 < s < s1] + [at(s1)]
    return [[round(x, 7), round(y, 7)] for x, y in line], at(L / 2), L


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tracks", type=Path, required=True)
    ap.add_argument("--scored", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--max-cards", type=int, default=200)
    ap.add_argument("--min-len", type=float, default=500.0)
    ap.add_argument("--max-density", type=int, default=25)
    ap.add_argument("--per-cell", type=int, default=6)
    ap.add_argument("--weak-labels", type=Path, required=True,
                    help="KSA-clipped OSM snapshot; candidates must lie within 3 km of it (keeps cards inside the Kingdom)")
    ap.add_argument("--allow-tier-a", action="store_true")
    ap.add_argument("--source", default="rahal_obf_new",
                    help="card source key; must exist in SOURCE_LABELS of the running tool "
                         "(use desertmaps_new only as a no-restart fallback)")
    a = ap.parse_args()
    tracks = json.load(gzip.open(a.tracks, "rt", encoding="utf-8"))["features"]
    scored = json.load(gzip.open(a.scored, "rt", encoding="utf-8"))
    import shapely
    from shapely import STRtree
    wl = json.load(open(a.weak_labels))["features"]
    wtree = STRtree([shapely.linestrings(f["geometry"]["coordinates"]) for f in wl if f["geometry"]["type"] == "LineString"])

    def in_kingdom(i):
        c = tracks[i]["geometry"]["coordinates"]
        pt = shapely.points(c[len(c) // 2])
        return len(wtree.query_nearest(pt, max_distance=0.03)) > 0     # ~3 km

    cands = []
    for rec in scored:
        if rec["len_geo"] < a.min_len or rec["osm_ways_800m"] > a.max_density:
            continue
        if a.allow_tier_a and rec["hw"] in ("track", "path", "unclassified") and rec["cover_all30"] <= 0.2:
            tier = "A"
        elif (rec["hw"] in ("track", "path") and rec["id_cls"] == "osm_way_found"
              and rec.get("cover_weak30", 0.0) <= 0.2 and rec["cover_all30"] >= 0.8):
            tier = "B"
        else:
            continue
        if not in_kingdom(rec["i"]):
            continue
        cands.append((tier, rec))
    cands.sort(key=lambda tr: (tr[0], -min(tr[1]["len_geo"], 4000) * (1 - tr[1].get("cover_weak30", 0.0))))
    cells = defaultdict(int)
    cards = []
    for tier, rec in cands:
        ft = tracks[rec["i"]]
        p = ft["properties"]
        coords = ft["geometry"]["coordinates"]
        line, mid, L = window(coords)
        if len(line) < 2:
            continue
        cell = (math.floor(mid[0] * 2) / 2, math.floor(mid[1] * 2) / 2)
        if cells[cell] >= a.per_cell:
            continue
        cells[cell] += 1
        tt, sf = p.get("tracktype"), p.get("surface")
        if sf and "sand" in sf or tt in ("grade4", "grade5"):
            th = "sandy"
        elif tt in ("grade1", "grade2") or sf in ("rock", "gravel", "fine_gravel", "pebblestone"):
            th = "rocky" if tt == "grade1" else "dirt"
        elif tt == "grade3":
            th = "mixed"
        elif p["hw"] == "path":
            th = "faint"
        else:
            th = "dirt"
        why = [f"طول المسار الكامل ≈ {int(rec['len_geo'])} م (البطاقة تعرض 260 م من وسطه)",
               ("لا يقع ضمن 30 م من أي طريق في OSM الحالي" if tier == "A"
                else "موجود في OSM الأحدث (مُعرَّف OSM حقيقي) لكنه غير موجود في لقطة OSM القديمة عندنا"),
               f"نوع OBF: {p['hw']}" + (f" / {tt}" if tt else "") + (f" / {sf}" if sf else ""),
               f"طرق OSM ضمن 800 م: {rec['osm_ways_800m']}"]
        cards.append({
            "pid": f"rahal-{rec['id']}", "source": a.source,
            "detail": f"Rahal OBF · {'غير موجود في OSM' if tier == 'A' else 'أحدث من لقطة OSM عندنا'} · {p['hw']} · {rec['len_geo']/1000:.1f} كم",
            "conf": None, "line": line, "mid": [round(mid[0], 7), round(mid[1], 7)], "length_m": round(min(L, 260.0), 1),
            "x0": 0, "y0": 0, "type_hint": th, "type_source": "obf_tags" if (tt or sf) else "default", "control": None,
            "region": f"شبكة {cell[1]:.1f}N {cell[0]:.1f}E", "non_osm": False,
            "value": round(min(rec["len_geo"], 4000) / 1000 * (1 - rec.get("cover_weak30", 0.0)), 3), "why": why,
            "obf_osmid": rec["osmid"], "obf_id_class": rec["id_cls"], "tier": tier,
        })
        if len(cards) >= a.max_cards:
            break
    for i, c in enumerate(cards):
        c["idx"] = i
    doc = {
        "created": "2026-11-12",
        "method": ("OBF tracks (Rahal export, owner-declared permission) that are real OSM ways absent from our older OSM "
                   "snapshot (tier B; tier A = absent from all OSM, empty in practice); length>=500 m; desert-like (few OSM ways "
                   "within 800 m); <=6 per 0.5-degree cell; one 260 m window from the middle of each track."),
        "caveats": ["الأحكام تُقيّم وجود الدرب على الصورة لا مصدره", "بيانات طرف ثالث (رحّال) بإذن معلن من المالك: لا تُرفع إلى git",
                    "المصدر: rahal_export_2026-11-12 (OsmAnd obf Saudi-arabia_asia, edition 2026-11-01)"],
        "strata_evidence": [],
        "regions_unreviewed_by_owner": [],
        "composition": {"tier": dict(Counter(c["tier"] for c in cards)), "type_hint": dict(Counter(c["type_hint"] for c in cards)),
                        "id_class": dict(Counter(c["obf_id_class"] for c in cards))},
        "cards": cards,
    }
    a.out.write_text(json.dumps(doc, ensure_ascii=False))
    print(len(cards), "cards", doc["composition"], "candidates", len(cands))


if __name__ == "__main__":
    sys.exit(main())
