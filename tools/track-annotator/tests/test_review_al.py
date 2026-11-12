"""Review mode, completeness/ignore regions, hard negatives, suggestions provenance, priority queue, impact."""
import json
import random
from pathlib import Path

import numpy as np
import pytest
from PIL import Image

from annotator import collect, config, export, geo, quality, review, rasterize, store, suggest, tiles
from tests.conftest import fc_line, make_test_tif
from tests.test_store_export import _annotated, _line_in


# ------------------------------------------------------------------ helpers
def _fake_mosaic(monkeypatch):
    def fm(z, x0, y0, nx, ny):
        rng = np.random.default_rng(x0 + y0)
        base = rng.normal(130, 25, (ny * 2, nx * 2)).clip(0, 255)
        rgb = np.kron(base, np.ones((256, 256)))[:, :, None].repeat(3, 2).astype("uint8")
        return rgb, geo.mosaic_grid(z, x0, y0, nx, ny)
    monkeypatch.setattr(tiles, "fetch_mosaic", fm)


def _card(src="desertmaps_new", control=None, lon=46.65, lat=25.15, pid="c1"):
    L = review._cut([[lon, lat], [lon + 0.004, lat + 0.0005]], 0, 200)
    c = review._mk(src, L, pid, "test", control=control, extra={"non_osm": True})
    c["idx"] = 0
    return c


def _put_deck(cards):
    review.REVIEW_DIR.mkdir(parents=True, exist_ok=True)
    review.DECK.write_text(json.dumps({"cards": cards, "n_cards": len(cards)}))


# ------------------------------------------------------------------ review mode
def test_wilson_interval():
    lo, hi = review.wilson(8, 10)
    assert 0.490 <= lo < 0.495 and 0.94 < hi < 0.95
    assert review.wilson(0, 0) is None and review.wilson(0, 1)[0] == 0.0


def test_segments_are_short_and_inside_the_line():
    line = [[46.0, 25.0], [46.05, 25.0]]  # ~5 km
    seg = review.segment_of(line, random.Random(1))
    assert 60 <= review._cum(seg)[-1] <= review.MAX_SEG_M + 1
    assert review.segment_of([[46.0, 25.0], [46.0003, 25.0]], random.Random(1)) is None  # too short


def test_card_pixels_roundtrip_and_fit_the_crop():
    c = _card()
    px = review.line_px(c)
    assert all(0 <= x <= review.CARD_PX and 0 <= y <= review.CARD_PX for x, y in px)
    back = review.px_to_lonlat(c, px)
    for (lo, la), (lo2, la2) in zip(c["line"], back):
        assert abs(lo - lo2) < 2e-6 and abs(la - la2) < 2e-6   # <~ 0.3 m (px rounding to 0.1)


def test_verdicts_become_labels_with_provenance_and_undo(monkeypatch):
    _fake_mosaic(monkeypatch)
    cs = [_card(pid=f"p{i}", lon=46.65 + 0.0005 * i) for i in range(5)]
    _put_deck(cs)
    r = review.verdict("p0", "correct")
    sid = r["sample_id"]
    fc = store.read_tracks(sid)
    f = fc["features"][0]["properties"]
    assert f["kind"] == "centerline" and f["source"] == "human_verified" and f["proposal_source"] == "desertmaps_new" and f["proposal_id"] == "p0"
    r2 = review.verdict("p1", "wrong", "fence_pipeline")
    neg = [x for x in store.read_tracks(r2["sample_id"])["features"] if x["properties"]["kind"] == "negative"]
    assert neg and neg[0]["properties"]["category"] == "fence" and neg[0]["properties"]["reason"] == "fence_pipeline"
    assert review.verdict("p2", "wrong", "offset")["sample_id"] is None      # offset is logged, not labelled
    assert review.verdict("p3", "skip")["sample_id"] is None
    with pytest.raises(ValueError):
        review.verdict("p4", "wrong")                                          # a reason is required
    assert review.undo_last()["pid"] == "p3"
    review.undo_last(); review.undo_last()
    review.undo_last()                                                          # p1 removed again
    fcs = [x for x in store.read_tracks(r2["sample_id"])["features"] if x["properties"].get("proposal_id") == "p1"]
    assert not fcs


def test_controls_never_become_labels_and_are_kept_out_of_precision(monkeypatch):
    _fake_mosaic(monkeypatch)
    cs = [_card(pid="a", control="shifted_wrong"), _card(pid="b", lon=46.7), _card(pid="c", lon=46.71)]
    _put_deck(cs)
    assert review.verdict("a", "wrong", "not_track")["sample_id"] is None
    review.verdict("b", "correct"); review.verdict("c", "wrong", "wadi")
    st = review.stats()
    d = st["sources"]["desertmaps_new"]
    assert d["n"] == 2 and d["approved"] == 1 and d["wrong"] == 1 and d["precision_raw"] == 0.5
    assert st["controls"]["shifted_wrong_rejected"] == "1/1"


def test_edit_counts_as_correct_and_logs_edit_rate(monkeypatch):
    _fake_mosaic(monkeypatch)
    _put_deck([_card(pid="e")])
    px = review.line_px(review.card_by_id("e"))
    px[1][1] += 12
    review.verdict("e", "correct", ms=4000, line_px_edit=px, edits=["drag"])
    st = review.stats()
    assert st["edit_rate"] == 1.0 and st["median_seconds_per_card"] == 4.0
    sid = review.read_verdicts()[0]["sample_id"]
    f = store.read_tracks(sid)["features"][0]["properties"]
    assert f["edited"] is True


def test_snap_moves_a_rigidly_offset_line_onto_the_ridge(monkeypatch):
    c = _card(pid="s")
    px = np.array(review.line_px(c))
    img = np.full((512, 512, 3), 120, np.uint8)
    off = 30                                              # the real track sits 30 px (~16 m) below the proposal
    for x, y in px:                                       # paint a bright ridge along the shifted line
        pass
    xs = np.linspace(px[0, 0], px[-1, 0], 400); ys = np.linspace(px[0, 1], px[-1, 1], 400) + off
    for x, y in zip(xs, ys):
        img[int(max(0, y - 3)):int(y + 4), int(x)] = 235
    monkeypatch.setattr(review, "crop_image", lambda card: Image.fromarray(img))
    narrow = review.snap(c, 16.0)
    wide = review.snap(c, 64.0)
    assert wide["response_after"] > wide["response_before"] * 3
    assert abs(wide["rigid_shift_px"]) >= 20 and abs(narrow["rigid_shift_px"]) <= 16


def test_deck_mix_controls_and_non_osm_share(monkeypatch, tmp_path):
    # tiny DesertMaps fixture file (test only): 40 'unverified' + 4 'verified_osm' lines
    feats = []
    rng = random.Random(0)
    for i in range(44):
        lon, lat = 45 + rng.random() * 5, 22 + rng.random() * 4
        feats.append({"type": "Feature", "geometry": {"type": "LineString", "coordinates": [[lon, lat], [lon + 0.01, lat + 0.002]]},
                      "properties": {"fid": f"t{i}", "tier": "unverified" if i < 40 else "verified_osm", "length_km": 1.1, "region": "x"}})
    p = tmp_path / "dm.geojson"
    p.write_text(json.dumps({"type": "FeatureCollection", "features": feats}))
    monkeypatch.setattr(review, "DESERTMAPS", p)
    d = review.build_deck(60, n_model=0, n_ridge=0)
    cards = d["cards"]
    non_ctl = [c for c in cards if not c.get("control")]
    assert d["controls"]["shifted_wrong"] == 2 and d["controls"]["likely_right"] == 2 and d["controls"]["repeat"] == 2
    assert d["non_osm_share"] >= 0.6                              # novel proposals dominate
    assert all(c["length_m"] <= review.MAX_SEG_M + 1 for c in cards)
    assert {c["source"] for c in non_ctl} <= set(review.SOURCE_LABELS)
    assert len({c["pid"] for c in cards}) == len(cards)
    ids = {c["pid"] for c in cards}
    assert all(c["repeat_of"] in ids for c in cards if c.get("control") == "repeat")


def test_review_api_progress_and_stats(monkeypatch):
    from fastapi.testclient import TestClient
    from annotator import api
    _fake_mosaic(monkeypatch)
    _put_deck([_card(pid="x1"), _card(pid="x2", lon=46.7)])
    cl = TestClient(api.app)
    d = cl.get("/api/review/deck").json()
    assert d["ready"] and d["progress"]["total"] == 2 and len(d["cards"]) == 2 and d["cards"][0]["line_px"]
    r = cl.post("/api/review/verdict", json={"pid": "x1", "verdict": "correct", "ms": 5000}).json()
    assert r["progress"]["done"] == 1
    assert len(cl.get("/api/review/deck").json()["cards"]) == 1
    assert cl.post("/api/review/verdict", json={"pid": "x2", "verdict": "wrong"}).status_code == 400
    assert cl.post("/api/review/undo").json()["undone"]["pid"] == "x1"
    assert "sources" in cl.get("/api/review/stats").json()


# ------------------------------------------------------------------ completeness / ignore / hard negatives
def _ann_sample(tmp_path, name, origin, complete, negative=False, seed=1):
    p = make_test_tif(tmp_path / name, origin=origin, seed=seed)
    meta, _ = store.create_from_geotiff(p)
    feats = [_line_in(meta, [(0.05, 0.9), (0.3, 0.6), (0.55, 0.5), (0.8, 0.25), (0.95, 0.1)], "dirt")]
    if negative:
        n = _line_in(meta, [(0.1, 0.15), (0.9, 0.2)], "dirt", fid="n1")
        n["properties"] = {"id": "n1", "kind": "negative", "category": "pivot_circle"}
        feats.append(n)
    store.save_annotations(meta["sample_id"], {"type": "FeatureCollection", "features": feats}, {"complete": complete})
    return meta["sample_id"]


def test_incomplete_samples_get_ignore_regions_and_a_warning(tmp_path):
    _ann_sample(tmp_path, "a.tif", (500000.0, 2800000.0), complete=False)
    _ann_sample(tmp_path, "b.tif", (512000.0, 2800000.0), complete=True, negative=True, seed=2)
    root = export.run_export(block_km=5.0)
    man = json.loads((root / "manifest.json").read_text())
    recs = {r["id"]: r for r in man["tiles"]}
    inc = [r for r in recs.values() if not r["complete"]]
    comp = [r for r in recs.values() if r["complete"]]
    assert inc and comp and man["needs_ignore_mask_loss"] is True
    for r in inc:
        ign = np.array(Image.open(root / "extras" / f"{r['id']}__ignore_mask.png"))
        road = np.array(Image.open(root / "spacenet" / "processed" / f"road_mask_{r['id']}.png"))
        assert (ign > 0).mean() > 0.5 and not ((ign > 0) & (road > 0)).any()    # unlabeled area ignored, positives never
    for r in comp:
        assert not np.array(Image.open(root / "extras" / f"{r['id']}__ignore_mask.png")).any()
    assert any(r["hardneg_categories"] == ["pivot_circle"] for r in comp)
    hn = [np.array(Image.open(root / "extras" / f"{r['id']}__hardneg_mask.png")) for r in comp if r["hardneg_categories"]]
    assert hn and config.NEG_INDEX["pivot_circle"] in np.unique(hn[0])
    rep = json.loads((root / "quality_report.json").read_text())
    assert rep["warnings"] and "مكتملة" in rep["warnings"][0] and rep["incomplete_samples"]
    assert rep["integrity_passed"], rep["integrity_issues"]
    assert any("ignore" in s for s in rep["sufficiency_issues"]) and not rep["ready_for_training"]


def test_complete_window_without_tracks_exports_negative_tiles_and_only_complete_flag(tmp_path):
    _ann_sample(tmp_path, "a.tif", (500000.0, 2800000.0), complete=False)
    p = make_test_tif(tmp_path / "neg.tif", origin=(512000.0, 2800000.0), seed=5)
    meta, _ = store.create_from_geotiff(p)
    store.save_annotations(meta["sample_id"], {"type": "FeatureCollection", "features": []}, {"complete": True})
    root = export.run_export(only_complete=True)
    man = json.loads((root / "manifest.json").read_text())
    assert {r["sample_id"] for r in man["tiles"]} == {meta["sample_id"]}
    assert man["counts"]["tiles_negative_only"] > 0 and not man["needs_ignore_mask_loss"]
    split = json.loads((root / "spacenet" / "data_split.json").read_text())
    neg = json.loads((root / "spacenet" / "negatives_split.json").read_text())
    assert sum(len(v) for v in split.values()) == 0 and sum(len(v) for v in neg.values()) > 0   # upstream loader never sees empty graphs
    rep = json.loads((root / "quality_report.json").read_text())
    assert rep["integrity_passed"], rep["integrity_issues"]


def test_manifest_carries_review_provenance_and_weight_hint(tmp_path, monkeypatch):
    _fake_mosaic(monkeypatch)
    sid = _ann_sample(tmp_path, "a.tif", (500000.0, 2800000.0), complete=True)
    fc = store.read_tracks(sid)
    fc["features"][0]["properties"].update(source="human_verified", proposal_source="desertmaps_new", proposal_id="z")
    store.save_annotations(sid, fc, {"complete": True})
    root = export.run_export()
    man = json.loads((root / "manifest.json").read_text())
    assert any(r["verified_sources"] == ["desertmaps_new"] and r["weight_hint"] == 2.0 for r in man["tiles"])
    assert "stats" in man["review"]


def test_hard_negative_validation():
    from annotator import store as st
    bad = {"type": "FeatureCollection", "features": [{"type": "Feature", "properties": {"kind": "negative", "category": "nope"},
           "geometry": {"type": "LineString", "coordinates": [[46, 25], [46.1, 25]]}}]}
    with pytest.raises(st.SampleError):
        st.validate_geojson(bad)


# ------------------------------------------------------------------ pre-annotation provenance
def test_suggestion_provenance_counts(tmp_path):
    p = make_test_tif(tmp_path / "s.tif")
    meta, _ = store.create_from_geotiff(p)
    sid = meta["sample_id"]
    sg = {"type": "FeatureCollection", "backend": "ridge", "features": [
        {"type": "Feature", "properties": {"id": f"sg{i}", "kind": "centerline", "source": "model_suggested", "confidence": .5},
         "geometry": _line_in(meta, [(0.1, 0.1 + 0.2 * i), (0.9, 0.1 + 0.2 * i)])["geometry"]} for i in range(4)]}
    store._write_geojson(store.sample_dir(sid) / "suggestions.geojson", sg)
    keep = lambda i, st: {"type": "Feature", "properties": {"id": f"k{i}", "kind": "centerline", "track_type": "dirt", "clarity": 2,
                          "source": "model_suggested", "suggestion_id": f"sg{i}", "edit_state": st}, "geometry": sg["features"][i]["geometry"]}
    hand = _line_in(meta, [(0.2, 0.95), (0.8, 0.95)], "sandy", fid="h1")
    store.save_annotations(sid, {"type": "FeatureCollection", "features": [keep(0, "accepted"), keep(1, "corrected"), hand]},
                           {"rejected_suggestions": ["sg2"]})
    m = store.read_metadata(sid)["annotation"]["suggestions"]
    assert (m["n_suggested"], m["accepted_unchanged"], m["accepted_corrected"], m["rejected"], m["pending"], m["added_by_hand"]) == (4, 1, 1, 1, 1, 1)
    assert m["precision_proxy"] == 0.5 and m["correction_rate"] is not None
    assert (store.sample_dir(sid) / "suggestions.geojson").is_file()               # original model output kept
    q = quality.check_sample(sid)
    assert any("لم يُراجَع" in w for w in q["warnings"])


def test_ridge_backend_finds_a_bright_track_and_flags_provenance():
    img = np.full((600, 600, 3), 110, np.uint8)
    rng = np.random.default_rng(0)
    img = (img + rng.normal(0, 4, img.shape)).clip(0, 255).astype("uint8")
    img[295:303, 50:550] = 200
    lines, info = suggest.run_ridge(img, np.ones((600, 600), np.uint8))
    assert lines and info["backend"] == "ridge"
    best = max(lines, key=lambda l: len(l[0]))[0]
    assert abs(np.mean(best[:, 1]) - 299) < 6


# ------------------------------------------------------------------ priority queue + impact
def test_priority_queue_cap_reasons_minutes_and_novelty(tmp_path):
    b = collect.current_batch()
    assert len(b["windows"]) <= 12 and b["estimate"]["minutes_total"] > 0
    for w in b["windows"]:
        assert w["why"] and w["est_minutes"] > 0 and 0 < w["score"] <= 1
    scores = [w["score"] for w in b["windows"]]
    assert scores[0] >= max(scores[1:]) * 0.5 or len(scores) == 1            # best-first greedy (later picks lose novelty)
    # spatial novelty: a labelled sample right next to a window lowers its value
    cands = collect.load_candidates()
    c = next(x for x in cands if x["source"] == "osm_weak")
    a = collect.analyse()
    far = collect.window_value(c, a, [])
    near = collect.window_value(c, a, [geo.block_xy(*c["centre"])])
    assert near["novelty"] < far["novelty"] and near["score"] < far["score"]


def test_model_disagreement_replaces_the_osm_prior(tmp_path):
    c = next(x for x in collect.load_candidates() if x["source"] == "osm_weak")
    a = collect.analyse()
    assert collect.window_value(c, a, [])["uncertainty_source"] == "osm_hint_prior"
    collect.save_score(c["id"], {"disagreement": 0.9, "backend": "ridge"})
    v = collect.window_value(c, a, [])
    assert v["uncertainty_source"].startswith("model_vs_osm") and v["uncertainty"] == 0.9
    d = collect.disagreement([[[46.0, 25.0], [46.01, 25.0]]], [[[46.0, 25.002], [46.01, 25.002]]])   # ~220 m apart
    assert d["disagreement"] == 1.0
    assert collect.disagreement([[[46.0, 25.0], [46.01, 25.0]]], [])["disagreement"] is None


def test_impact_reports_added_km_split_and_remaining(tmp_path):
    sid = _ann_sample(tmp_path, "a.tif", (500000.0, 2800000.0), complete=False)
    im = collect.impact(sid)
    assert im["added_km_total"] > 0.5 and im["types"]["dirt"]["added_km"] > 0.5
    assert im["types"]["dirt"]["remaining_km"] < im["types"]["dirt"]["target_km"]
    assert im["split"]["after"]["leakage_ok"] and im["split"]["after"]["blocks"] >= 1
    assert im["unflagged_samples"] == 1 and im["complete"] is False


def test_suggest_and_job_api(tmp_path, monkeypatch):
    from fastapi.testclient import TestClient
    from annotator import api
    p = make_test_tif(tmp_path / "s.tif")
    meta, _ = store.create_from_geotiff(p)
    monkeypatch.setattr(suggest, "available_backends", lambda: {"sam_road": False, "ridge": True})
    cl = TestClient(api.app)
    assert cl.get("/api/config").json()["suggest_backends"]["ridge"]
    jid = cl.post(f"/api/samples/{meta['sample_id']}/suggest", json={"backend": "ridge"}).json()["job"]
    import time
    for _ in range(100):
        j = cl.get(f"/api/jobs/{jid}").json()
        if j["state"] != "running":
            break
        time.sleep(0.3)
    assert j["state"] == "done", j
    assert cl.get(f"/api/samples/{meta['sample_id']}").json()["suggestions"]["backend"] == "ridge"
