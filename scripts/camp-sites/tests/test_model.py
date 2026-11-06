"""Unit tests for the camp-site rules on synthetic terrain (no downloads).

Run: python -m pytest scripts/camp-sites/tests -q
"""
import os
import sys

import numpy as np
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import model as M  # noqa: E402

DX, DY = 56.0, 62.0


def valley(rows=80, cols=80, depth=12.0, tilt=0.004):
    """A plain tilted to the south with a V-shaped wadi down the middle column."""
    r, c = np.mgrid[0:rows, 0:cols].astype(float)
    z = 700.0 - tilt * r * DY + depth * np.minimum(np.abs(c - cols // 2) / 10.0, 1.0)
    return z


def base_layers(z):
    shape = z.shape
    slope = M.slope_pct(z, DX, DY)
    filled = M.priority_flood(z, eps=1e-5)
    acc = M.d8_accumulation(filled, DX, DY)
    sink = filled - z
    excl, d_ch, idx = M.channel_exclusion(acc, DX, DY, sink)
    zeros = np.zeros(shape)
    far = np.full(shape, 1e5)
    return {
        "slope": slope, "sink_depth": sink, "acc_km2": acc, "channel_excl": excl, "d_channel": d_ch,
        "hand": M.hand(z, idx), "sabkha": np.zeros(shape, bool), "water_frac": zeros, "built_frac": zeros,
        "d_settle": far, "d_road": far, "d_military": far, "ndvi_here": zeros + 0.1,
        "tpi500": zeros, "dark": zeros + 1, "green_near": zeros, "famous": zeros, "sunset": zeros + 1,
        "gravel_near": zeros + 1, "sand_near": zeros + 1, "d_track": zeros + 800, "rough_1km": zeros,
    }


def test_wadi_bed_is_excluded():
    z = valley()
    L = base_layers(z)
    excluded, rules = M.hard_exclusions(L)
    mid = z.shape[1] // 2
    # The wadi bed in the lower half (big enough catchment) is excluded as «wadi» …
    assert rules["wadi"][60, mid]
    assert excluded[60, mid]
    # … and so is its flood buffer either side …
    assert excluded[60, mid + 1] and excluded[60, mid - 1]
    # … but the high flank far from the channel is not.
    assert not rules["wadi"][60, 5]


def test_wadi_bed_never_picked_even_if_it_scores_best():
    z = valley()
    L = base_layers(z)
    excluded, _ = M.hard_exclusions(L)
    score = np.zeros(z.shape)
    score[60, z.shape[1] // 2] = 10.0  # rig the wadi bed to look like the best place
    score[30, 10] = 1.0
    picks = M.pick_sites(score, excluded, DX, DY, n=5, edge_cells=2)
    assert (60, z.shape[1] // 2) not in picks
    assert (30, 10) in picks


def test_channel_buffer_grows_with_catchment():
    acc = np.full((10, 10), 0.01)
    acc[:, 5] = 0.6
    small, *_ = M.channel_exclusion(acc, DX, DY)
    acc[:, 5] = 600.0
    big, *_ = M.channel_exclusion(acc, DX, DY)
    assert big.sum() > small.sum()


def test_closed_depression_is_a_sink():
    r, c = np.mgrid[0:40, 0:40].astype(float)
    z = 600 + 0.02 * ((r - 20) ** 2 + (c - 20) ** 2) ** 0.5 * 10  # a bowl
    filled = M.priority_flood(z, eps=1e-5)
    depth = filled - z
    assert depth[20, 20] > M.SINK_DEPTH_M
    L = base_layers(z)
    _, rules = M.hard_exclusions(L)
    assert rules["sink"][20, 20]


@pytest.mark.parametrize("key,value,rule", [
    ("sabkha", True, "sabkha"),
    ("slope", 12.0, "steep"),
    ("water_frac", 0.5, "water"),
    ("built_frac", 0.6, "built"),
    ("d_settle", 300.0, "built"),
    ("d_road", 100.0, "road"),
    ("d_military", 200.0, "military"),
    ("ndvi_here", 0.4, "on_plants"),
])
def test_hard_exclusions(key, value, rule):
    z = np.full((20, 20), 600.0) + np.mgrid[0:20, 0:20][0] * 0.01  # gentle, no channel
    L = base_layers(z)
    L[key] = L[key].copy() if hasattr(L[key], "copy") else L[key]
    L[key][10, 10] = value
    excluded, rules = M.hard_exclusions(L)
    assert rules[rule][10, 10]
    assert excluded[10, 10]
    assert not excluded[3, 3]


def test_gentle_ground_scores_flatter_than_slope():
    z = np.full((20, 20), 600.0)
    L = base_layers(z)
    L["slope"] = np.zeros((20, 20))
    L["slope"][5, 5] = 6.0
    ax = M.axis_scores(L)
    assert ax["comfort"][10, 10] > ax["comfort"][5, 5]


def dune_north_of_site():
    """A 12 m dune ridge 2 rows (~120 m) north of the centre row (lee zone ~10 H)."""
    z = np.full((40, 40), 600.0)
    z[17:19, :] = 612.0
    return z


def test_shelter_depends_on_wind_direction():
    z = dune_north_of_site()
    sh = M.shelter_index(z, DX, DY)
    i_n, i_s = M.DIRS.index("N"), M.DIRS.index("S")
    assert sh[i_n, 20, 20] > 0.5      # wind from the north: the dune shelters the site
    assert sh[i_s, 20, 20] < 0.1      # wind from the south: open


def test_ranking_flips_with_wind_direction():
    """Same two places; tonight's wind decides which is better (the owner's rule)."""
    axes = {"safety": 1.0, "comfort": 0.7, "beauty": 0.6, "access": 0.8}
    lee_of_north = [0.9, 0.5, 0, 0, 0, 0, 0, 0.5]
    lee_of_south = [0, 0, 0, 0.5, 0.9, 0.5, 0, 0]
    north = M.total_score(axes, lee_of_north, 0, 35), M.total_score(axes, lee_of_south, 0, 35)
    south = M.total_score(axes, lee_of_north, 180, 35), M.total_score(axes, lee_of_south, 180, 35)
    assert north[0] > north[1]
    assert south[1] > south[0]


def test_wind_weight_rises_with_gusts():
    assert M.wind_weight(10) < M.wind_weight(35) < M.wind_weight(60)
    assert M.wind_weight(80) == pytest.approx(0.6)


def test_sunset_open_vs_blocked():
    z = np.full((40, 120), 600.0)
    z[:, 5:8] = 640.0  # a 40 m ridge to the west of the columns past it
    op = M.sunset_openness(z, DX, DY, max_dist_m=3000)
    assert op[20, 15] < op[20, 2] or op[20, 15] < 0.5
    assert op[20, 2] > 0.9


def test_pick_sites_keeps_separation():
    score = np.random.default_rng(1).random((100, 100))
    picks = M.pick_sites(score, np.zeros((100, 100), bool), DX, DY, n=20, min_sep_m=900, edge_cells=0)
    for i, a in enumerate(picks):
        for b in picks[i + 1:]:
            assert abs(a[0] - b[0]) * DY > 900 or abs(a[1] - b[1]) * DX > 900


def test_reasons_are_najdi_and_ordered():
    parts = {"sunset": 1.0, "dark": 0.9, "green": 0.0, "view": 0.2, "quiet": 0.7, "flat": 1.0, "drains": 1.0,
             "firm": 1.0, "soft": 0.0, "fame": 0.0}
    codes = M.reasons(parts, d_channel=900, d_track=500)
    assert codes[0] == "sunset"
    assert "green" not in codes
    assert all(c in M.REASON_AR for c in codes)
