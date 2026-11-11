"""Cost and route rules of «مخطط دروب البر» on synthetic grids (mirrored in DesertRouterTests.swift)."""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import routes as RT  # noqa: E402


def grid(rows=30, cols=30, cls=RT.FIRM):
    return {"cls": np.full((rows, cols), cls, "uint8"), "track": np.zeros((rows, cols), bool), "road": np.zeros((rows, cols), bool),
            "big": np.zeros((rows, cols), bool), "dem": np.full((rows, cols), 500.0), "ridge": np.full((rows, cols), 255, "uint8"),
            "bbox": (25.0, 46.0, 25.0 + rows * RT.ROUTE_ARCSEC / 3600, 46.0 + cols * RT.ROUTE_ARCSEC / 3600)}


def cells(path):
    return set(path)


def test_easy_route_goes_around_sabkha():
    g = grid()
    g["cls"][5:25, 12:18] = RT.SABKHA  # a sabkha between start and end, open at the ends
    G = RT.Grid(g)
    easy = RT.route(G, (15, 2), (15, 27), "easy")
    assert easy and not any(g["cls"][r, c] == RT.SABKHA for r, c in easy)
    short = RT.route(G, (15, 2), (15, 27), "short")
    assert any(g["cls"][r, c] == RT.SABKHA for r, c in short), "the shortest cuts through, and is flagged"
    s = RT.summarize(G, short)
    assert any(h["reason"] == "sabkha" for h in s["hard"])


def test_prefers_a_track_even_if_longer():
    g = grid(cls=RT.SAND)
    g["track"][2, :] = True
    g["track"][2:16, 1] = True
    g["track"][2:16, 28] = True
    G = RT.Grid(g)
    easy = RT.route(G, (15, 1), (15, 28), "easy")
    s = RT.summarize(G, easy)
    assert s["track_pct"] > 80
    short = RT.route(G, (15, 1), (15, 28), "short")
    assert RT.summarize(G, short)["distance_m"] < s["distance_m"]


def test_rain_keeps_out_of_a_big_wadi():
    g = grid()
    g["cls"][:, 10:20] = RT.WADI
    g["big"][:, 10:20] = True
    g["cls"][:, 0] = RT.FIRM
    G = RT.Grid(g)
    # The wadi runs north–south between the points; along its bed is the only straight way.
    a, b = (2, 15), (27, 15)
    dry = RT.route(G, a, b, "short")
    assert dry and all(g["big"][r, c] for r, c in dry[1:-1])
    wet = RT.route(G, a, b, "short", rain=True)
    assert wet is None or not any(g["big"][r, c] for r, c in wet[1:])


def test_rain_routes_around_the_wadi_bed_when_it_can():
    g = grid()
    g["cls"][:, 10:20] = RT.WADI
    g["big"][:, 10:20] = True
    g["cls"][0:3, :] = RT.FIRM   # a crossing at the top (a ford)
    g["big"][0:3, :] = False
    G = RT.Grid(g)
    wet = RT.route(G, (25, 2), (25, 27), "easy", rain=True)
    assert wet and not any(g["big"][r, c] for r, c in wet)


def test_against_the_dune_grain_costs_more():
    eff_along, _ = RT.cell_effort(RT.SAND, 0, 90, 90, 0.0, False)     # ridges run E–W, moving east
    eff_across, why = RT.cell_effort(RT.SAND, 0, 90, 0, 0.0, False)   # moving north across them
    assert eff_across > eff_along * 2
    assert why == "against"


def test_steep_descent_is_refused_and_flagged():
    eff, why = RT.cell_effort(RT.FIRM, 0, 255, 0, -0.4, False)
    assert eff is None and why == "down"
    eff, why = RT.cell_effort(RT.FIRM, 0, 255, 0, -0.2, False)
    assert eff is not None and why == "down"


def test_forbidden_never_crossed():
    g = grid()
    g["cls"][:, 15] = RT.FORBIDDEN
    G = RT.Grid(g)
    assert RT.route(G, (5, 2), (5, 27), "short") is None


def test_bin_round_trip(tmp_path):
    import json, struct, zlib
    g = grid(rows=4, cols=5)
    g["cls"][1, 2] = RT.CREST
    g["track"][0, 0] = True
    g["dem"][3, 4] = 512.25
    g["ridge"][2, 2] = 45
    p = tmp_path / "r.bin"
    RT.write_bin(g, str(p), "t")
    raw = zlib.decompress(p.read_bytes())
    assert raw[:8] == b"SARYRT1\0"
    n = struct.unpack("<I", raw[8:12])[0]
    h = json.loads(raw[12:12 + n])
    cells = np.frombuffer(raw[12 + n:], "uint8").reshape(h["rows"], h["cols"], 4)
    assert cells[1, 2, 0] & 0x0F == RT.CREST
    assert cells[0, 0, 0] & RT.TRACK
    assert cells[2, 2, 1] == 45
    z = cells[3, 4, 2] | (cells[3, 4, 3].astype(int) << 8)
    assert h["z0"] + z / 4 == 512.25
