"""Pure rules of «دليل البر» (no I/O): naming, classification, geometry, merging.

Every entry comes from a source record (OSM element, GeoNames row, or a camp-site candidate
from scripts/camp-sites). Nothing here invents a place, a name or a coordinate: the only
derived values are a simplified outline, a bounding box and a representative point inside it.
"""
import math
import re
import unicodedata

KINDS = ("nafud", "rawda", "fayda", "camp")

ODBL = "ODbL-1.0"
CC_BY = "CC-BY-4.0"

# ---------------------------------------------------------------- names

_AR = re.compile(r"[؀-ۿ]")
_TASHKEEL = re.compile(r"[ً-ٰٟـ]")


def has_arabic(s):
    return bool(s) and bool(_AR.search(s))


def norm_ar(s):
    """Arabic for matching: no tashkeel/tatweel, one alef, ة→ه, ى→ي, no leading «ال» per word."""
    if not s:
        return ""
    s = _TASHKEEL.sub("", s)
    s = re.sub("[أإآٱ]", "ا", s).replace("ة", "ه").replace("ى", "ي").replace("ؤ", "و").replace("ئ", "ي")
    words = [w[2:] if w.startswith("ال") and len(w) > 3 else w for w in re.split(r"[\s\-_/،,()]+", s) if w]
    return " ".join(words)


def norm_en(s):
    """Latin for matching: no diacritics or ʿayn/hamza marks, lower case, no «al/ar/ad…» articles."""
    if not s:
        return ""
    s = unicodedata.normalize("NFKD", s)
    s = "".join(c for c in s if not unicodedata.combining(c))
    s = re.sub(r"[‘’'`ʿʾ´]", "", s).lower()
    s = re.sub(r"\b(a[lnrtdsz]|ash|ath|adh|az|as|at)[\s\-]+", "", s)
    s = re.sub(r"[^a-z ]+", " ", s)
    return " ".join(s.split())


# Arabic first word → kind (after norm_ar, so «الروضة» and «روضه» match too).
AR_PREFIX = {
    "rawda": ("روضه", "روضات", "رياض", "روض"),
    "fayda": ("فيضه", "فيضات", "فياض", "فيض"),
    "nafud": ("نفود", "نفد", "نفيد", "عرق", "عروق", "رمله", "رملات", "دهنا", "دهناء", "طعس", "نقا", "نقيان"),
}
# «الربع الخالي» is a nafud too (two words).
AR_PHRASE = {"nafud": ("ربع خالي",)}

EN_PREFIX = {
    "rawda": ("rawdat", "rawdah", "rawda", "rawd", "rawdhat", "raudhat", "raudat", "riyad"),
    "fayda": ("faydat", "faydah", "fayda", "fayd", "faidat", "faidah", "faid"),
    "nafud": ("nafud", "nefud", "nufud", "irq", "uruq", "ramlat", "dahna", "rub al khali", "rub khali", "tuus", "naqa"),
}


def kind_from_names(ar, en):
    a = norm_ar(ar)
    if a:
        first = a.split()[0]
        for k, ps in AR_PREFIX.items():
            if first in ps:
                return k
        for k, ps in AR_PHRASE.items():
            if any(a.startswith(p) for p in ps):
                return k
    e = norm_en(en)
    if e:
        for k, ps in EN_PREFIX.items():
            for p in ps:
                if e == p or e.startswith(p + " "):
                    return k
    return None


# ---------------------------------------------------------------- OSM

# A feature with one of these is a building, a shop, a school («روضة أطفال»), a road, a park in
# a town, a farm or a settlement: not a place in the desert.
OSM_REJECT_KEYS = ("amenity", "shop", "building", "highway", "railway", "office", "healthcare", "craft",
                   "power", "man_made", "aeroway", "public_transport", "club", "sport", "brand", "operator:type")
OSM_REJECT = {
    "place": {"city", "town", "village", "suburb", "neighbourhood", "quarter", "hamlet", "isolated_dwelling",
              "city_block", "plot", "farm", "allotments", "borough", "municipality", "county", "state"},
    "landuse": {"residential", "commercial", "retail", "industrial", "farmland", "farmyard", "orchard", "construction",
                "religious", "cemetery", "military", "education", "garages", "railway", "plant_nursery", "greenhouse_horticulture"},
    "leisure": {"park", "playground", "pitch", "garden", "sports_centre", "stadium", "swimming_pool", "resort",
                "fitness_centre", "water_park", "amusement_arcade", "golf_course", "track", "dog_park", "picnic_table"},
    "tourism": {"hotel", "motel", "guest_house", "chalet", "apartment", "hostel", "attraction", "museum", "theme_park", "zoo"},
    "boundary": {"administrative", "postal_code", "census", "political"},
    "natural": {"tree", "peak", "spring", "water", "coastline", "bay", "cape", "beach", "cave_entrance", "cliff"},
    "waterway": {"canal", "drain", "ditch", "river", "stream"},
}
OSM_DESERT_NATURAL = {"sand", "desert", "dune"}


def osm_names(tags):
    ar = tags.get("name:ar") or (tags.get("name") if has_arabic(tags.get("name")) else None)
    en = tags.get("name:en") or tags.get("int_name") or (tags.get("name") if tags.get("name") and not has_arabic(tags.get("name")) else None)
    alts = []
    for k in ("name", "alt_name", "alt_name:ar", "alt_name:en", "old_name", "old_name:ar", "official_name", "official_name:ar",
              "official_name:en", "loc_name", "short_name", "int_name", "name:en"):
        for v in (tags.get(k) or "").split(";"):
            v = v.strip()
            if v and v != ar and v != en and v not in alts:
                alts.append(v)
    return ar, en, alts


# The same selection as queries/*.overpassql (used on a Geofabrik extract by extract_pbf.py).
NAME_RE = re.compile(r"^(ال)?(روضة|روضه|روضات|رياض|فيضة|فيضه|فياض|فيضات|نفود|نفد|عرق|عروق|رملة|رمله|رملات|دهناء|طعس|نقا)( |$)"
                     r"|الدهناء|الربع الخالي|الثمامة|الثمامه")


def osm_candidate(tags):
    name = tags.get("name")
    if not name:
        return False
    if tags.get("natural") in OSM_DESERT_NATURAL:
        return True
    if not NAME_RE.search(name):
        return False
    return ("natural" in tags
            or tags.get("place") in {"locality", "region", "area", "plain"}
            or tags.get("landuse") in {"meadow", "grass"}
            or tags.get("boundary") == "protected_area"
            or tags.get("leisure") == "nature_reserve"
            or tags.get("tourism") in {"camp_site", "picnic_site", "viewpoint"})


def osm_rejected(tags):
    if any(k in tags for k in OSM_REJECT_KEYS):
        return True
    return any(tags.get(k) in vs for k, vs in OSM_REJECT.items())


def osm_kind(tags):
    """The kind of an OSM element, or None (not a desert place, or not one of ours)."""
    if osm_rejected(tags):
        return None
    ar, en, _ = osm_names(tags)
    if not (ar or en):
        return None
    k = kind_from_names(ar, en)
    if k is None and tags.get("natural") in OSM_DESERT_NATURAL:
        k = "nafud"
    return k


# ---------------------------------------------------------------- GeoNames

# Codes that can be one of our kinds (the name decides which; a bare dune/erg/sand is a nafud).
GN_CODES = {"DUNE", "ERG", "SAND", "DPR", "PNDI", "SBKH", "PLN", "AREA", "WAD", "HLLS", "LCTY", "RGN", "DPRG", "PLAT", "UPLD", "GRSLD", "SCRB", "OAS", "BSNP"}
GN_SAND = {"DUNE", "ERG", "SAND"}


def geonames_kind(code, name, asciiname, ar):
    if code not in GN_CODES:
        return None
    k = kind_from_names(ar, asciiname or name)
    if k is None and code in GN_SAND:
        k = "nafud"
    return k


# ---------------------------------------------------------------- geometry

R_EARTH = 6371008.8


def meters(a, b):
    """Haversine distance between two [lng, lat] points, metres."""
    lng1, lat1, lng2, lat2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((lat2 - lat1) / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin((lng2 - lng1) / 2) ** 2
    return 2 * R_EARTH * math.asin(min(1.0, math.sqrt(h)))


def _perp(p, a, b):
    if a == b:
        return math.hypot(p[0] - a[0], p[1] - a[1])
    dx, dy = b[0] - a[0], b[1] - a[1]
    t = max(0.0, min(1.0, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / (dx * dx + dy * dy)))
    return math.hypot(p[0] - a[0] - t * dx, p[1] - a[1] - t * dy)


def simplify(pts, tol):
    """Douglas–Peucker (iterative), tolerance in degrees. Keeps first and last."""
    if len(pts) <= 2:
        return list(pts)
    keep = [False] * len(pts)
    keep[0] = keep[-1] = True
    stack = [(0, len(pts) - 1)]
    while stack:
        i, j = stack.pop()
        dmax, idx = 0.0, None
        for k in range(i + 1, j):
            d = _perp(pts[k], pts[i], pts[j])
            if d > dmax:
                dmax, idx = d, k
        if idx is not None and dmax > tol:
            keep[idx] = True
            stack += [(i, idx), (idx, j)]
    return [p for p, k in zip(pts, keep) if k]


def ring_area(ring):
    """Signed shoelace area in degrees² (only for comparing sizes)."""
    s = 0.0
    for (x1, y1), (x2, y2) in zip(ring, ring[1:] + ring[:1]):
        s += x1 * y2 - x2 * y1
    return s / 2


def bbox(rings):
    xs = [p[0] for r in rings for p in r]
    ys = [p[1] for r in rings for p in r]
    return [min(xs), min(ys), max(xs), max(ys)]


def inside(pt, ring):
    x, y = pt
    c = False
    n = len(ring)
    for i in range(n):
        x1, y1 = ring[i]
        x2, y2 = ring[(i + 1) % n]
        if (y1 > y) != (y2 > y) and x < (x2 - x1) * (y - y1) / (y2 - y1) + x1:
            c = not c
    return c


def inside_any(pt, rings):
    return any(inside(pt, r) for r in rings)


def representative_point(rings):
    """A point inside the biggest ring: its centroid when inside, else the inside grid point
    farthest from the edge (a coarse «pole of inaccessibility»)."""
    ring = max(rings, key=lambda r: abs(ring_area(r)))
    a = ring_area(ring)
    if abs(a) > 1e-12:
        cx = cy = 0.0
        for (x1, y1), (x2, y2) in zip(ring, ring[1:] + ring[:1]):
            f = x1 * y2 - x2 * y1
            cx += (x1 + x2) * f
            cy += (y1 + y2) * f
        c = [cx / (6 * a), cy / (6 * a)]
        if inside(c, ring):
            return c
    w, s, e, n = bbox([ring])
    best, bd = None, -1.0
    steps = 24
    for i in range(1, steps):
        for j in range(1, steps):
            p = [w + (e - w) * i / steps, s + (n - s) * j / steps]
            if not inside(p, ring):
                continue
            d = min(_perp(p, ring[k], ring[(k + 1) % len(ring)]) for k in range(len(ring)))
            if d > bd:
                best, bd = p, d
    return best or list(ring[0])


def assemble_rings(ways):
    """Join open way geometries (lists of [lng, lat]) into closed rings by matching ends.
    Ways that do not close are dropped (the outline is then unknown, the bbox still holds)."""
    rings, open_ = [], []
    for w in ways:
        if len(w) < 2:
            continue
        if w[0] == w[-1] and len(w) >= 4:
            rings.append(w[:-1])
        else:
            open_.append(list(w))
    while open_:
        cur = open_.pop()
        changed = True
        while changed and cur[0] != cur[-1]:
            changed = False
            for i, w in enumerate(open_):
                if w[0] == cur[-1]:
                    cur += w[1:]
                elif w[-1] == cur[-1]:
                    cur += list(reversed(w))[1:]
                elif w[-1] == cur[0]:
                    cur = w[:-1] + cur
                elif w[0] == cur[0]:
                    cur = list(reversed(w))[:-1] + cur
                else:
                    continue
                open_.pop(i)
                changed = True
                break
        if cur[0] == cur[-1] and len(cur) >= 4:
            rings.append(cur[:-1])
    return rings


def tolerance(rings):
    """Simplification tolerance (degrees) by size: ~1 % of the diagonal, 0.002° (≈200 m) at least."""
    w, s, e, n = bbox(rings)
    return max(0.002, 0.01 * math.hypot(e - w, n - s))


def compact_rings(rings, max_points=400):
    """Simplify, round to 4 decimals (≈11 m), drop slivers; raise the tolerance until small."""
    tol = tolerance(rings)
    for _ in range(8):
        out = []
        for r in rings:
            closed = r + [r[0]]
            sr = simplify(closed, tol)[:-1]
            sr = [[round(x, 4), round(y, 4)] for x, y in sr]
            dedup = [p for i, p in enumerate(sr) if i == 0 or p != sr[i - 1]]
            if len(dedup) >= 3 and abs(ring_area(dedup)) > 1e-7:
                out.append(dedup)
        if sum(len(r) for r in out) <= max_points:
            return out
        tol *= 1.6
    return out


def distance_to_edge(pt, rings):
    """0 inside an outline, else metres to its nearest edge (equirectangular around `pt`)."""
    if inside_any(pt, rings):
        return 0.0
    k = math.cos(math.radians(pt[1]))
    best = math.inf
    for r in rings:
        for i in range(len(r)):
            a, b = r[i], r[(i + 1) % len(r)]
            pa = ((a[0] - pt[0]) * k, a[1] - pt[1])
            pb = ((b[0] - pt[0]) * k, b[1] - pt[1])
            best = min(best, _perp((0.0, 0.0), pa, pb))
    return math.radians(best) * R_EARTH


# ---------------------------------------------------------------- merging

MERGE_M = {"nafud": 25_000, "rawda": 6_000, "fayda": 6_000, "camp": 0}

SOURCE_RANK = {"osm:relation": 0, "osm:way": 1, "osm:node": 2, "geonames": 3, "camp": 4}


def _rank(e):
    pre = e["id"].rsplit("/", 1)[0] if e["id"].startswith("osm:") else e["id"].split(":")[0]
    return (0 if e.get("polygon") else 1, SOURCE_RANK.get(pre, 9), e["id"])


def keys(e):
    out = set()
    for n in [e.get("name_ar")] + [a for a in e.get("alt", []) if has_arabic(a)]:
        if n:
            out.add("ar:" + norm_ar(n))
    for n in [e.get("name_en")] + [a for a in e.get("alt", []) if a and not has_arabic(a)]:
        if n:
            out.add("en:" + norm_en(n))
    return out


def near(a, b):
    lim = MERGE_M.get(a["kind"], 0)
    if lim <= 0:
        return False
    for x, y in ((a, b), (b, a)):
        if x.get("polygon") and (inside_any(y["point"], x["polygon"]) or distance_to_edge(y["point"], x["polygon"]) < lim):
            return True
    return meters(a["point"], b["point"]) < lim


def merge(entries):
    """Same kind + a shared normalised name (Arabic or Latin) + close → one entry.

    The kept id is the best source's (outline first, then relation > way > node > GeoNames), so
    ids are stable from one build to the next while the sources keep theirs. Every source id is
    listed in `sources`; Arabic names from any source fill a missing `name_ar`."""
    entries = sorted(entries, key=_rank)
    out = []
    index = {}
    for e in entries:
        target = None
        if e["kind"] != "camp":
            for k in keys(e):
                for j in index.get((e["kind"], k), []):
                    if near(out[j], e):
                        target = j
                        break
                if target is not None:
                    break
        if target is None:
            out.append(e)
            j = len(out) - 1
        else:
            j = target
            t = out[j]
            for field in ("name_ar", "name_en"):
                if not t.get(field) and e.get(field):
                    t[field] = e[field]
            for a in [e.get("name_ar"), e.get("name_en")] + e.get("alt", []):
                if a and a not in t["alt"] and a != t.get("name_ar") and a != t.get("name_en"):
                    t["alt"].append(a)
            for s in e["sources"]:
                if s not in t["sources"]:
                    t["sources"].append(s)
        for k in keys(out[j]):
            index.setdefault((out[j]["kind"], k), [])
            if j not in index[(out[j]["kind"], k)]:
                index[(out[j]["kind"], k)].append(j)
    return out
