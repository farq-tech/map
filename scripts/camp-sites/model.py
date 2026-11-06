"""«الجلسة الحلوة» — a transparent, rule-based camp-site suitability model.

Everything here is pure numpy on a regular lat/lon grid, so it can be unit-tested on synthetic
terrain (tests/test_model.py). No learned model: every number on a card traces back to a rule
below, and the rule's Najdi reason is what the person reads.

Axes (0..1):  safety (a gate first: any hard exclusion removes the cell)
              comfort  (flat, drains, firm ground for the cars + soft sand to sit on)
              beauty   (sunset open to the west, a view, dark sky, greenery, quiet, a known place)
              access   (an OSM track close but not on top of it, no long dune crossing)
              shelter  per wind direction (8 values) — combined with tonight's wind in the app.
"""
import heapq
import math

import numpy as np
from scipy import ndimage

# Wind directions the wind comes FROM, clockwise from north (meteorological convention).
DIRS = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
DIR_AR = {"N": "الشمال", "NE": "الشمال الشرقي", "E": "الشرق", "SE": "الجنوب الشرقي",
          "S": "الجنوب", "SW": "الجنوب الغربي", "W": "الغرب", "NW": "الشمال الغربي"}

# ---- thresholds (the explainable rules) ------------------------------------------------------
SLOPE_MAX_PCT = 8.0          # hard: steeper than this is no camp ground
SLOPE_GOOD_PCT = 3.0         # comfort is full below this
CHANNEL_KM2 = 0.5            # upstream area that makes a drainage line a «شعيب» / wadi channel
CHANNEL_BUFFER_M = 75.0      # hard: never camp this close to a channel …
CHANNEL_BUFFER_PER_LOG = 60.0  # … plus this much per decade of upstream area above CHANNEL_KM2
SINK_DEPTH_M = 0.5           # hard: a closed depression this deep ponds water («جورة»)
SINK_DEPTH_SAND_M = 1.5      # the same on loose sand (infiltrates)
HAND_SAFE_M = 2.0            # height above the nearest channel that counts as «أرض أعلى»
BUILT_FRAC = 0.15            # hard: WorldCover built-up fraction in a cell
WATER_FRAC = 0.05            # hard: WorldCover water / wetland fraction
MILITARY_BUFFER_M = 1500.0
SETTLEMENT_MIN_M = 1500.0    # hard: closer than this to a village / farm («عزبة») is not a kashta
ROAD_MIN_M = 500.0           # hard: right on a paved road
ACCESS_MAX_M = 6000.0        # hard: farther than this from any track or road (a long dune crossing)


def cell_size_m(lat_deg, arcsec):
    dy = arcsec / 3600 * 110_574.0
    dx = arcsec / 3600 * 111_320.0 * math.cos(math.radians(lat_deg))
    return dx, dy


# ---- terrain ---------------------------------------------------------------------------------

def slope_pct(dem, dx, dy):
    gy, gx = np.gradient(dem, dy, dx)
    return np.hypot(gx, gy) * 100.0


def priority_flood(dem, eps=1e-3):
    """Barnes et al. (2014) priority-flood with epsilon: every cell drains to the border.
    Returns the filled surface (sinks raised to their spill level + a tiny gradient)."""
    rows, cols = dem.shape
    z = dem.astype("float64").ravel().copy()
    done = np.zeros(rows * cols, dtype=bool)
    heap = []
    for r in range(rows):
        for c in (0, cols - 1):
            i = r * cols + c
            if not done[i]:
                done[i] = True
                heap.append((z[i], i))
    for c in range(cols):
        for r in (0, rows - 1):
            i = r * cols + c
            if not done[i]:
                done[i] = True
                heap.append((z[i], i))
    heapq.heapify(heap)
    offs = [(-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)]
    zl = z.tolist()
    dl = done.tolist()
    while heap:
        h, i = heapq.heappop(heap)
        r, c = divmod(i, cols)
        for dr, dc in offs:
            rr, cc = r + dr, c + dc
            if 0 <= rr < rows and 0 <= cc < cols:
                j = rr * cols + cc
                if dl[j]:
                    continue
                dl[j] = True
                if zl[j] <= h:
                    zl[j] = h + eps
                heapq.heappush(heap, (zl[j], j))
    return np.array(zl).reshape(rows, cols)


def d8_accumulation(filled, dx, dy):
    """Upstream area (km²) of every cell, D8 steepest descent on the filled surface."""
    rows, cols = filled.shape
    pad = np.pad(filled, 1, mode="edge")
    offs = [(-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)]
    best = np.zeros_like(filled)
    recv = np.full(filled.shape, -1, dtype=np.int64)
    rr, cc = np.mgrid[0:rows, 0:cols]
    for dr, dc in offs:
        nb = pad[1 + dr: 1 + dr + rows, 1 + dc: 1 + dc + cols]
        dist = math.hypot(dr * dy, dc * dx)
        drop = (filled - nb) / dist
        nr, nc = rr + dr, cc + dc
        inside = (nr >= 0) & (nr < rows) & (nc >= 0) & (nc < cols)
        m = (drop > best) & inside
        best[m] = drop[m]
        recv[m] = (nr * cols + nc)[m]
    order = np.argsort(-filled, axis=None, kind="stable")
    acc = np.ones(rows * cols)
    rv = recv.ravel()
    accl = acc.tolist()
    rvl = rv.tolist()
    for i in order.tolist():
        j = rvl[i]
        if j >= 0:
            accl[j] += accl[i]
    return np.array(accl).reshape(rows, cols) * dx * dy / 1e6


def channel_mask(acc_km2, sink_depth=None):
    """Flowing channels. Inside a filled depression the D8 lines are artefacts of the fill
    (parallel straight lines across a flat); those cells are handled as «جورة» (ponding) instead."""
    ch = acc_km2 >= CHANNEL_KM2
    if sink_depth is not None:
        ch &= sink_depth < 0.05
    return ch


def channel_exclusion(acc_km2, dx, dy, sink_depth=None):
    """Cells inside the flood buffer of a channel. The buffer grows with the catchment
    (a big wadi floods wider than a small «شعيب»). Returns (excluded, dist_m, hand_ref_index)."""
    ch = channel_mask(acc_km2, sink_depth)
    if not ch.any():
        big = np.full(acc_km2.shape, 1e9)
        return np.zeros(acc_km2.shape, bool), big, None
    dist, idx = ndimage.distance_transform_edt(~ch, sampling=(dy, dx), return_indices=True)
    a_near = acc_km2[idx[0], idx[1]]
    buf = CHANNEL_BUFFER_M + CHANNEL_BUFFER_PER_LOG * np.log10(np.maximum(a_near / CHANNEL_KM2, 1.0))
    return dist <= buf, dist, idx


def hand(dem, idx):
    """Height above the nearest drainage channel (m)."""
    if idx is None:
        return np.full(dem.shape, 50.0)
    return dem - dem[idx[0], idx[1]]


def box_mean(a, radius_cells):
    k = 2 * radius_cells + 1
    return ndimage.uniform_filter(a.astype("float64"), size=k, mode="nearest")


def tpi(dem, radius_cells):
    """Topographic position: height above the neighbourhood mean (m)."""
    return dem - box_mean(dem, radius_cells)


def roughness(dem, radius_cells=2):
    m = box_mean(dem, radius_cells)
    m2 = box_mean(dem * dem, radius_cells)
    return np.sqrt(np.maximum(m2 - m * m, 0))


def _shift(a, dr, dc, fill):
    """out[r, c] = a[r + dr, c + dc] (fill outside)."""
    out = np.full_like(a, fill)
    rows, cols = a.shape
    r0, r1 = max(0, -dr), min(rows, rows - dr)
    c0, c1 = max(0, -dc), min(cols, cols - dc)
    if r0 < r1 and c0 < c1:
        out[r0:r1, c0:c1] = a[r0 + dr:r1 + dr, c0 + dc:c1 + dc]
    return out


def _dir_vec(az_deg):
    """Row/col unit step towards azimuth (north = up = row-1)."""
    a = math.radians(az_deg)
    return -math.cos(a), math.sin(a)


def horizon_angle(dem, az_deg, max_dist_m, dx, dy, eye_m=1.6, steps=None):
    """Max elevation angle (deg) of the terrain seen from each cell towards azimuth."""
    vr, vc = _dir_vec(az_deg)
    step_m = min(dx, dy)
    n = steps or max(1, int(max_dist_m / step_m))
    best = np.full(dem.shape, -90.0)
    base = dem + eye_m
    for k in range(1, n + 1):
        d = k * step_m
        dr = int(round(vr * d / dy))
        dc = int(round(vc * d / dx))
        if dr == 0 and dc == 0:
            continue
        dist = math.hypot(dr * dy, dc * dx)
        nb = _shift(dem, dr, dc, np.nan)
        ang = np.degrees(np.arctan2(nb - base, dist))
        best = np.fmax(best, ang)
    return best


def shelter_index(dem, dx, dy, veg_frac=None, max_dist_m=350.0, full_deg=9.0):
    """Wind shelter for each of the 8 directions the wind may come FROM (0..1).
    The obstacle's elevation angle upwind (a dune or ridge within ~350 m) measured from a
    person sitting (1 m): 9° or more (a 10 m dune at 60 m) counts as full shelter. Shrubs and
    trees upwind (WorldCover) add a little. Returns array (8, rows, cols)."""
    out = []
    for i, _ in enumerate(DIRS):
        az = i * 45.0
        ang = horizon_angle(dem, az, max_dist_m, dx, dy, eye_m=1.0)
        s = np.clip(ang / full_deg, 0, 1)
        if veg_frac is not None:
            vr, vc = _dir_vec(az)
            up = _shift(veg_frac, int(round(vr * 1.5)), int(round(vc * 1.5)), 0)
            s = np.clip(s + 0.25 * np.clip(up / 0.3, 0, 1), 0, 1)
        out.append(np.nan_to_num(s, nan=0.0))
    return np.stack(out).astype("float32")


def sunset_openness(dem, dx, dy, max_dist_m=3000.0):
    """1 when the western horizon (sunset azimuths 245°–295°, winter → summer) is open."""
    vals = []
    for az in (245, 260, 270, 280, 295):
        ang = horizon_angle(dem, az, max_dist_m, dx, dy, eye_m=1.6, steps=40)
        vals.append(np.clip(1 - (np.nan_to_num(ang, nan=-1) - 0.5) / 2.5, 0, 1))
    return np.mean(vals, axis=0)


# ---- ground type -----------------------------------------------------------------------------

def ground_classes(s2, slope, rough, wc, frac):
    """Transparent spectral rules on a dry-season Sentinel-2 scene.
      sabkha: very flat, bright, damper in SWIR than the sand around it, or OSM / WorldCover wet
      sand:   bright and red (iron-stained dune sand), or a rough dune surface
      gravel: darker bare ground («حزم» / «صلبة»): good for the cars
    Returns dict of boolean masks."""
    blue, green, red = s2["blue"], s2["green"], s2["red"]
    nir, sw1, sw2 = s2["nir"], s2["swir16"], s2["swir22"]
    bright = (blue + green + red) / 3
    redness = red / np.maximum(blue, 0.01)
    ndmi = (nir - sw1) / (nir + sw1 + 1e-6)
    # Salt crusts are bright and white (low redness) and absorb SWIR-2 when damp.
    sabkha_s2 = (slope < 1.0) & (bright > 0.28) & (redness < 2.2) & (ndmi > -0.04) & (sw2 / np.maximum(sw1, 0.01) < 0.82)
    sabkha = sabkha_s2 | (frac.get(90, 0) > 0.2) | (wc == 90)
    sand = ((bright > 0.12) & (redness > 6.0)) | (rough > 1.5)
    sand &= ~sabkha
    gravel = (~sand) & (~sabkha) & (slope < SLOPE_MAX_PCT) & (wc == 60)
    return {"sabkha": np.nan_to_num(sabkha).astype(bool), "sand": np.nan_to_num(sand).astype(bool),
            "gravel": np.nan_to_num(gravel).astype(bool), "bright": bright, "redness": redness}


# ---- scoring ---------------------------------------------------------------------------------

def ramp(x, a, b):
    """0 at a, 1 at b (either direction)."""
    return np.clip((x - a) / (b - a), 0, 1)


def hard_exclusions(L):
    """Every rule that removes a cell, with its reason code. L is a dict of layers."""
    rules = {
        "wadi": L["channel_excl"],
        # Rain soaks into dune sand; a hollow there needs to be deeper before it ponds.
        "sink": L["sink_depth"] > np.where(L.get("sand", False), SINK_DEPTH_SAND_M, SINK_DEPTH_M),
        "sabkha": L["sabkha"],
        "steep": L["slope"] > SLOPE_MAX_PCT,
        "water": L["water_frac"] > WATER_FRAC,
        "built": (L["built_frac"] > BUILT_FRAC) | (L["d_settle"] < SETTLEMENT_MIN_M),
        "road": L["d_road"] < ROAD_MIN_M,
        "military": L["d_military"] < MILITARY_BUFFER_M,
        "remote": np.minimum(L["d_track"], L["d_road"]) > ACCESS_MAX_M,
        "on_plants": L["ndvi_here"] > 0.25,
    }
    any_ = np.zeros(L["slope"].shape, bool)
    for m in rules.values():
        any_ |= m
    return any_, rules


def axis_scores(L):
    """Static axis scores (no wind: that is tonight's, applied in the app)."""
    flat = 1 - ramp(L["slope"], SLOPE_GOOD_PCT, SLOPE_MAX_PCT)
    drains = ramp(L["hand"], 0.5, HAND_SAFE_M) * (L["sink_depth"] < 0.15)
    firm_near = L["gravel_near"]            # firm ground within ~150 m to park
    soft_here = L["sand_near"]              # clean sand within ~100 m to sit on
    comfort = 0.40 * flat + 0.30 * drains + 0.15 * firm_near + 0.15 * soft_here

    safety = 0.5 + 0.5 * ramp(L["d_channel"], 150, 600) * ramp(L["hand"], 1.0, 4.0)

    view = ramp(L["tpi500"], 1.0, 8.0)
    dark = L["dark"]
    green = L["green_near"]
    quiet = ramp(L["d_road"], 800, 4000) * ramp(L["d_settle"], 2000, 6000)
    fame = L["famous"]
    beauty = 0.25 * L["sunset"] + 0.15 * view + 0.20 * dark + 0.15 * green + 0.15 * quiet + 0.10 * fame

    t = np.minimum(L["d_track"], L["d_road"] + 500)  # a paved road is access too, a little farther
    access = np.where(L["d_track"] < 100, 0.6, 1 - ramp(t, 1500, ACCESS_MAX_M)) * (1 - 0.5 * ramp(L["rough_1km"], 1.0, 4.0))
    return {"safety": safety, "comfort": comfort, "beauty": beauty, "access": access,
            "parts": {"flat": flat, "drains": drains, "firm": firm_near, "soft": soft_here, "view": view, "dark": dark,
                      "green": green, "quiet": quiet, "fame": fame, "sunset": L["sunset"]}}


WEIGHTS = {"comfort": 0.25, "beauty": 0.35, "access": 0.15, "shelter": 0.25}


def wind_weight(gust_kmh):
    """Wind matters more the stronger tonight's gusts (the owner: «الريح عامل مؤثر جدًا»)."""
    return 0.25 + 0.35 * float(np.clip((gust_kmh - 15) / 35, 0, 1))


def shelter_for(shelter8, from_deg):
    """Interpolate the 8-direction shelter to the actual wind direction."""
    f = (from_deg % 360) / 45.0
    i0 = int(math.floor(f)) % 8
    i1 = (i0 + 1) % 8
    w = f - math.floor(f)
    return (1 - w) * shelter8[i0] + w * shelter8[i1]


def total_score(axes, shelter8, wind_from_deg, gust_kmh):
    """The app's live ranking (mirrored in Swift `CampRanker`): safety gates (excluded cells
    never get here) and scales; the rest is a weighted mean whose wind weight rises with gusts."""
    ww = wind_weight(gust_kmh)
    rest = 1 - ww
    base = WEIGHTS["comfort"] + WEIGHTS["beauty"] + WEIGHTS["access"]
    s = rest * (WEIGHTS["comfort"] * axes["comfort"] + WEIGHTS["beauty"] * axes["beauty"] + WEIGHTS["access"] * axes["access"]) / base
    s = s + ww * shelter_for(shelter8, wind_from_deg)
    return s * (0.7 + 0.3 * axes["safety"])


def pick_sites(score, excluded, dx, dy, n=60, min_sep_m=900.0, edge_cells=6):
    """Greedy non-maximum suppression: the best cells at least min_sep_m apart."""
    s = np.where(excluded, -1, score).astype("float64")
    s[:edge_cells, :] = -1
    s[-edge_cells:, :] = -1
    s[:, :edge_cells] = -1
    s[:, -edge_cells:] = -1
    rr = int(math.ceil(min_sep_m / dy))
    rc = int(math.ceil(min_sep_m / dx))
    out = []
    flat = np.argsort(-s, axis=None)
    taken = np.zeros(s.shape, bool)
    for i in flat:
        if len(out) >= n:
            break
        r, c = divmod(int(i), s.shape[1])
        if s[r, c] <= 0:
            break
        if taken[r, c]:
            continue
        out.append((r, c))
        taken[max(0, r - rr): r + rr + 1, max(0, c - rc): c + rc + 1] = True
    return out


# ---- reasons (Najdi) -------------------------------------------------------------------------

REASON_AR = {
    "flat": "أرض مستوية",
    "drains": "أرض أعلى شوي تصرّف الماء",
    "far_wadi": "بعيد عن مجرى السيل",
    "firm": "أرض صلبة قريبة توقف عليها السيارات",
    "soft": "رمل ناعم للفرشة",
    "sunset": "الغروب مفتوح",
    "view": "مطل على امتداد",
    "dark": "بعيد عن الأنوار، النجوم واضحة",
    "green": "قريب من خضرة",
    "quiet": "هادي، بعيد عن الخط والعزب",
    "track": "قريب من درب",
    "fame": "مكان معروف للكشتات",
}


def reasons(parts, d_channel, d_track, famous_name=None, k=None):
    """Static reason codes in order of strength (the app adds tonight's wind first)."""
    cand = [
        ("sunset", parts["sunset"]), ("dark", parts["dark"]), ("green", parts["green"]), ("view", parts["view"]),
        ("quiet", parts["quiet"]), ("flat", parts["flat"] * 0.9), ("drains", parts["drains"] * 0.8),
        ("firm", parts["firm"] * 0.7), ("soft", parts["soft"] * 0.6), ("fame", parts["fame"]),
        ("far_wadi", 0.75 if d_channel > 600 else 0.0), ("track", 0.7 if 100 <= d_track <= 2000 else 0.0),
    ]
    codes = [c for c, v in sorted(cand, key=lambda kv: -float(kv[1])) if float(v) >= 0.6]
    return codes[:k] if k else codes
