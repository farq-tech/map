"""National «دروب البر» tiles: names, coverage, haloed crop and the manifest (synthetic data only)."""
import hashlib
import json
import os
import sys
import zlib

import numpy as np
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import regions as RG  # noqa: E402
import routes as RT  # noqa: E402
import tiles as T  # noqa: E402

K = 3600 // RT.ROUTE_ARCSEC  # route cells per degree


def synthetic(bbox, seed=0):
    """A random route grid on the 3-arc-second lattice over bbox (as grid_from_layers returns it)."""
    s, w, n, e = bbox
    rows, cols = round((n - s) * K), round((e - w) * K)
    rng = np.random.default_rng(seed)
    return {"cls": rng.integers(0, 7, (rows, cols)).astype("uint8"), "track": rng.random((rows, cols)) < 0.1,
            "road": rng.random((rows, cols)) < 0.05, "big": rng.random((rows, cols)) < 0.02,
            "dem": 500 + rng.random((rows, cols)) * 50, "ridge": rng.integers(0, 256, (rows, cols)).astype("uint8"),
            "coh": rng.random((rows, cols)), "bbox": bbox}


def test_tile_names_are_the_south_west_corner():
    assert RG.tile_id(25.3, 46.7) == "t25_46"
    assert RG.tile_id(25.0, 46.0) == "t25_46"
    assert RG.tile_id(24.999, 46.0) == "t24_46"
    assert RG.parse_tile_id("t25_46") == (25, 46)
    assert RG.parse_tile_id("t16_42") == (16, 42)
    assert RG.parse_tile_id("thumamah") is None
    assert RG.parse_tile_id("t25_46.bin") is None
    assert RG.tile_bbox(25, 46) == (25.0, 46.0, 26.0, 47.0)


def test_tiles_covering_a_bbox():
    assert RG.tiles_covering((25.2, 46.3, 25.8, 46.9)) == [(25, 46)]
    # An edge exactly on a degree does not pull in the neighbour.
    assert RG.tiles_covering((25.0, 46.0, 26.0, 47.0)) == [(25, 46)]
    assert sorted(RG.tiles_covering((24.5, 45.5, 25.5, 46.5))) == [(24, 45), (24, 46), (25, 45), (25, 46)]


def test_tile_names_resolve_like_regions_with_a_halo():
    r = RG.REGIONS["t25_46"]
    h = RG.TILE_HALO_DEG
    assert r["tile"] == (25.0, 46.0, 26.0, 47.0)
    assert r["bbox"] == pytest.approx((25 - h, 46 - h, 26 + h, 47 + h))
    assert "thumamah" in RG.REGIONS and "t25_46" not in list(RG.REGIONS)  # pilots only when iterating
    with pytest.raises(KeyError):
        RG.REGIONS["atlantis"]
    # The halo is a whole number of cells on both the analysis and the route lattice.
    assert (h * 3600 / RG.ROUTE_ARCSEC) == pytest.approx(round(h * 3600 / RG.ROUTE_ARCSEC))
    assert (h * 3600 / RG.ANALYSIS_ARCSEC) == pytest.approx(round(h * 3600 / RG.ANALYSIS_ARCSEC))


def test_kingdom_tiles_hold_the_pilots_and_skip_the_sea_and_neighbours():
    names = set(RG.ksa_tiles())
    for pilot in RG.REGIONS.values():
        for la, lo in RG.tiles_covering(pilot["bbox"]):
            assert f"t{la}_{lo}" in names
    assert {"t24_46", "t21_39", "t26_50", "t17_43"} <= names  # Riyadh, Jeddah, Dammam, Najran
    assert "t32_35" not in names  # Jordan / the Levant
    assert "t16_34" not in names  # Red Sea off Eritrea
    assert "t30_47" not in names  # Kuwait / Iraq
    assert 150 < len(names) < 300


def test_crop_from_the_halo_gives_exact_neighbouring_tiles():
    # Two tiles side by side, each computed haloed; their crops must sit edge to edge on the lattice.
    h = 0.05
    big = synthetic((24.95, 45.95, 26.05, 48.05))
    left = RT.crop(big, (25.0, 46.0, 26.0, 47.0))
    right = RT.crop(big, (25.0, 47.0, 26.0, 48.0))
    assert left["cls"].shape == right["cls"].shape == (K, K)
    off = round(h * K)
    np.testing.assert_array_equal(np.hstack([left["cls"], right["cls"]]), big["cls"][off:off + K, off:off + 2 * K])
    np.testing.assert_array_equal(left["dem"], big["dem"][off:off + K, off:off + K])
    assert left["bbox"] == (25.0, 46.0, 26.0, 47.0)
    with pytest.raises(ValueError):
        RT.crop(big, (25.0, 46.0, 26.5, 49.0))


def test_written_tile_and_manifest(tmp_path):
    out = tmp_path / "out"
    out.mkdir()
    for i, (la, lo) in enumerate([(25, 46), (25, 47)]):
        g = RT.crop(synthetic((la - 0.05, lo - 0.05, la + 1.05, lo + 1.05), seed=i), RG.tile_bbox(la, lo))
        RT.write_bin(g, str(out / T.tile_file(f"t{la}_{lo}")), f"t{la}_{lo}")
    (out / "routes-thumamah.bin").write_bytes(b"not a tile, ignored")

    h = T.read_header(str(out / "routes-t25_46.bin"))
    assert (h["rows"], h["cols"], h["south"], h["west"], h["arcsec"]) == (K, K, 25.0, 46.0, RT.ROUTE_ARCSEC)

    m = T.write_manifest(str(out), "2026-11-10", {"osm_md5": "abc"})
    assert json.loads((out / "manifest.json").read_text()) == m
    assert m["format"] == "SARYRT1" and m["arcsec"] == RT.ROUTE_ARCSEC and m["tile_deg"] == 1
    assert "OpenStreetMap" in m["attribution"] and "Google" not in json.dumps(m)
    assert [t["id"] for t in m["tiles"]] == ["t25_46", "t25_47"]
    t0 = m["tiles"][0]
    data = (out / "routes-t25_46.bin").read_bytes()
    assert t0["bytes"] == len(data) and t0["sha256"] == hashlib.sha256(data).hexdigest()
    assert t0["bbox"] == [25.0, 46.0, 26.0, 47.0] and (t0["rows"], t0["cols"]) == (K, K)
    assert m["built_from"] == {"osm_md5": "abc"}
    # The payload is what the app reads: magic, header, then rows*cols*4 bytes.
    raw = zlib.decompress(data)
    assert raw[:8] == b"SARYRT1\0"


def test_manifest_refuses_a_tile_under_the_wrong_name(tmp_path):
    g = RT.crop(synthetic((24.95, 45.95, 26.05, 47.05)), (25.0, 46.0, 26.0, 47.0))
    RT.write_bin(g, str(tmp_path / "routes-t26_46.bin"), "t25_46")
    with pytest.raises(ValueError):
        T.build_manifest(str(tmp_path), "v")
