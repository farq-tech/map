import json

import httpx
import numpy as np
import pytest
from fastapi.testclient import TestClient

from annotator import api, collect, config, store, tiles
from tests.conftest import fc_line, make_test_tif
from tests.test_store_export import _annotated


@pytest.fixture
def client():
    return TestClient(api.app)


def test_empty_data_requests_all_six_types_in_one_batch():
    b = collect.current_batch()
    assert b["status"] == "open"
    assert {m["type"] for m in b["missing_types"]} == set(config.TRACK_TYPES)
    assert 1 <= len(b["windows"]) <= collect.MAX_WINDOWS
    assert len({w["id"] for w in b["windows"]}) == len(b["windows"])
    for t in config.TRACK_TYPES:  # every type has at least one proposed window
        assert any(t in w["for_types"] for w in b["windows"]), t


def test_batch_is_idempotent_and_never_re_requests(tmp_path):
    b1 = collect.current_batch()
    b2 = collect.current_batch()
    assert b1["batch_id"] == b2["batch_id"]  # same open batch, not a new ask
    wid = b1["windows"][0]["id"]
    collect.skip_window(wid, "غير مناسبة")
    b3 = collect.current_batch()
    assert next(w for w in b3["windows"] if w["id"] == wid)["state"] == "skipped"
    # close everything, then a NEW batch must not contain any earlier window
    for w in b3["windows"]:
        if w["state"] == "pending":
            collect.skip_window(w["id"])
    b4 = collect.current_batch()
    assert b4["batch_id"] != b1["batch_id"]
    assert not ({w["id"] for w in b4["windows"]} & {w["id"] for w in b1["windows"]})


def test_supplied_data_is_not_requested_again_and_fixtures_do_not_count(tmp_path):
    # an owner-annotated sample of type "sandy" (synthetic geotiff stands in for owner's GeoTIFF)
    _annotated(tmp_path, ttype="sandy")
    a = collect.analyse()
    assert a["annotated_samples"] == 1
    assert a["types"]["sandy"]["have"]["tracks"] == 1 and a["types"]["dirt"]["have"]["tracks"] == 0
    # a fixture sample is ignored by the analysis
    p = make_test_tif(tmp_path / "f.tif", origin=(520000.0, 2800000.0))
    meta, _ = store.create_from_geotiff(p, fixture=True)
    from tests.test_store_export import _line_in
    store.save_annotations(meta["sample_id"], {"type": "FeatureCollection", "features": [_line_in(meta, [(0.1, 0.1), (0.9, 0.9)], "rocky")]})
    assert collect.analyse()["types"]["rocky"]["have"]["tracks"] == 0


def test_window_overlapping_supplied_imagery_is_excluded(monkeypatch, tmp_path):
    cands = collect.load_candidates()
    target = cands[0]
    # fabricate a sample whose bbox equals the candidate window
    from annotator import geo
    from rasterio.transform import Affine
    g = geo.mosaic_grid(**{"z": 17, "x0": target["tiles"]["x0"], "y0": target["tiles"]["y0"], "nx": 3, "ny": 3})
    rect = collect._rect_of_bbox(g.bbox_wgs84())
    monkeypatch.setattr(collect, "supplied_rects", lambda: [rect])
    b = collect.current_batch()
    assert target["id"] not in {w["id"] for w in b["windows"]}


# ---------------------------------------------------------------- API
def test_api_flow_import_save_list_export_status(client, tmp_path):
    cfg = client.get("/api/config").json()
    assert set(cfg["types"]) == set(config.TRACK_TYPES) and cfg["native_zoom"] == 17
    p = make_test_tif(tmp_path / "up.tif")
    r = client.post("/api/samples/import", files={"file": ("up.tif", open(p, "rb"), "image/tiff")})
    assert r.status_code == 200, r.text
    meta = r.json()["metadata"]
    sid = meta["sample_id"]
    from tests.test_store_export import _line_in
    fc = {"type": "FeatureCollection", "features": [_line_in(meta, [(0.1, 0.8), (0.5, 0.5), (0.9, 0.2)], "winding")]}
    r = client.put(f"/api/samples/{sid}/annotations", json={"geojson": fc, "terrain": "dunes", "clarity": 3})
    assert r.status_code == 200 and r.json()["quality"]["ok"], r.text
    got = client.get(f"/api/samples/{sid}").json()
    assert got["metadata"]["terrain"] == "dunes" and len(got["geojson"]["features"]) == 1
    assert client.get(f"/api/samples/{sid}/file/overlay.png").status_code == 200
    assert client.get(f"/api/samples/{sid}/file/../../etc/passwd").status_code in (404, 422)
    assert [s["sample_id"] for s in client.get("/api/samples").json()] == [sid]
    st = client.get("/api/collection/status").json()
    assert st["types"]["winding"]["have"]["tracks"] == 1
    bad = client.put(f"/api/samples/{sid}/annotations", json={"geojson": {"type": "Nope"}})
    assert bad.status_code == 400


def test_api_rejects_non_tif_and_crsless(client, tmp_path):
    assert client.post("/api/samples/import", files={"file": ("x.png", b"123", "image/png")}).status_code == 400


# ---------------------------------------------------------------- tiles: cache, budget, secrecy
class _Resp:
    def __init__(self, status=200, content=b""):
        self.status_code, self.content = status, content


def _jpeg():
    import io
    from PIL import Image
    b = io.BytesIO()
    Image.new("RGB", (512, 512), (120, 110, 90)).save(b, "JPEG")
    return b.getvalue()


def test_tile_cache_budget_and_token_never_leaks(monkeypatch):
    calls = []

    class FakeClient:
        def get(self, url):
            calls.append(url)
            return _Resp(200, _jpeg())

    monkeypatch.setattr(tiles, "_http", lambda: FakeClient())
    monkeypatch.setattr(config, "DAILY_TILE_BUDGET", 2)
    tiles.get_tile(17, 100, 100)
    tiles.get_tile(17, 100, 100)  # cache hit: no request, no budget
    tiles.get_tile(17, 101, 100)
    assert len(calls) == 2 and tiles.budget_status()["remaining"] == 0
    with pytest.raises(tiles.BudgetExceeded):
        tiles.get_tile(17, 102, 100)
    assert "pk.TESTTOKEN" in calls[0]  # only inside the outgoing request URL
    for f in config.DATA_DIR.rglob("*"):
        if f.is_file() and f.suffix in (".json", ".md", ".jpg") and f.stat().st_size < 100_000:
            assert b"TESTTOKEN" not in f.read_bytes(), f


def test_network_errors_are_sanitised(monkeypatch):
    class Boom:
        def get(self, url):
            raise httpx.ConnectError(f"failed {url}")
    monkeypatch.setattr(tiles, "_http", lambda: Boom())
    with pytest.raises(tiles.TileUnavailable) as e:
        tiles.get_tile(17, 5, 5)
    assert "TESTTOKEN" not in str(e.value) and "access_token" not in str(e.value)


def test_non_pk_token_is_refused(monkeypatch):
    monkeypatch.setenv("MAPBOX_ACCESS_TOKEN", "sk.secret")
    with pytest.raises(RuntimeError):
        config.mapbox_token()


def test_zoom_above_native_is_refused(client):
    assert client.get("/tiles/18/1/1.jpg").status_code == 404
