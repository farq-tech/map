"""Batch 2 import (append-only) and the two-level positive verdict (واضح / ضعيف)."""
import json

import pytest

from annotator import review, store
from tests.test_review_al import _card, _fake_mosaic, _put_deck


def _batch_file(tmp_path, n=20, with_judged=None):
    cards = []
    for i in range(n):
        c = _card(pid=f"b2-{i}", lon=47.0 + 0.003 * i, lat=24.0)
        c.pop("idx", None)
        cards.append(c)
    if with_judged:
        cards.append({**_card(pid=with_judged, lon=46.0), })
    p = tmp_path / "next_batch_ranking.json"
    p.write_text(json.dumps({"created": "2026-11-13", "method": "m", "caveats": ["c"],
                             "strata_evidence": [{"region": "ALL", "approval": 0.78}], "composition": {}, "cards": cards}))
    return p


def test_import_appends_without_touching_verdicts_and_is_idempotent(tmp_path, monkeypatch):
    _fake_mosaic(monkeypatch)
    _put_deck([_card(pid=f"a{i}", lon=46.6 + 0.01 * i) for i in range(6)])
    for i in range(4):
        review.verdict(f"a{i}", "correct")                       # legacy single «صح»
    before = review.VERDICTS.read_text()
    bf = _batch_file(tmp_path, 20, with_judged="a1")            # a1 was already judged: must never come back
    r = review.import_batch(bf, 2)
    assert r["added"] == r["cards"] + r["controls"] and r["cards"] == 20 and r["controls"] == 5
    assert review.VERDICTS.read_text() == before                  # verdict log untouched
    d = review.load_deck()
    pids = [c["pid"] for c in d["cards"]]
    assert len(pids) == len(set(pids)) and pids[:6] == [f"a{i}" for i in range(6)]
    assert d["batches"]["2"]["strata_evidence"][0]["approval"] == 0.78
    assert (review.REVIEW_DIR / "deck.json.bak-before-batch2").is_file()
    b2 = [c for c in d["cards"] if c.get("batch") == 2]
    ctl = [c for c in b2 if c.get("control")]
    assert sum(1 for c in ctl if c["control"] == "shifted_wrong") == 3 and sum(1 for c in ctl if c["control"] == "repeat") == 2
    assert all(c["repeat_of"] in {"a0", "a2", "a3", "a1"} for c in ctl if c["control"] == "repeat")   # repeats re-show judged cards
    assert review.import_batch(bf, 2)["added"] == 0              # idempotent


def test_progress_is_scoped_to_the_newest_pending_batch(tmp_path, monkeypatch):
    _fake_mosaic(monkeypatch)
    _put_deck([_card(pid=f"a{i}", lon=46.6 + 0.01 * i) for i in range(3)])
    for i in range(3):
        review.verdict(f"a{i}", "correct_clear")
    p0 = review.progress()
    assert p0["total"] == 3 and p0["left"] == 0
    review.import_batch(_batch_file(tmp_path, 10), 2)
    p = review.progress()
    assert p["batch"] == 2 and p["done"] == 0 and p["total"] == 15 and p["left"] == 15


def test_two_level_verdicts_make_graded_labels(monkeypatch):
    _fake_mosaic(monkeypatch)
    _put_deck([_card(pid="c", lon=46.7), _card(pid="f", lon=46.8), _card(pid="l", lon=46.9)])
    props = {}
    for pid, v in (("c", "correct_clear"), ("f", "correct_faint"), ("l", "correct")):
        sid = review.verdict(pid, v)["sample_id"]
        props[pid] = store.read_tracks(sid)["features"][0]["properties"]
    assert (props["c"]["verdict_level"], props["c"]["clarity"], props["c"]["label_confidence"]) == ("clear", 1, 1.0)
    assert (props["f"]["verdict_level"], props["f"]["clarity"], props["f"]["label_confidence"]) == ("faint", 3, 0.5)
    assert props["l"]["verdict_level"] == "unspecified"                     # the 58 legacy verdicts keep working
    r = review.verdict("c", "correct_clear", more_tracks=True)
    assert store.read_metadata(r["sample_id"])["review_more_tracks"] is True


def test_strict_and_lenient_precision_with_legacy_separate(monkeypatch):
    _fake_mosaic(monkeypatch)
    cs = [_card(pid=f"p{i}", lon=46.5 + 0.02 * i) for i in range(12)]
    _put_deck(cs)
    seq = ["correct"] * 3 + ["correct_clear"] * 2 + ["correct_faint"] * 3 + ["wrong"] * 4
    for c, v in zip(cs, seq):
        review.verdict(c["pid"], v, "not_track" if v == "wrong" else None)
    d = review.stats()["sources"]["desertmaps_new"]
    assert (d["clear"], d["faint"], d["unspecified"], d["wrong"]) == (2, 3, 3, 4)
    assert d["strict"]["k"] == 2 and d["strict"]["n"] == 9          # legacy verdicts excluded from the two-level rates
    assert d["lenient"]["k"] == 5 and d["lenient"]["n"] == 9
    assert d["strict"]["p"] == 0.222 and d["lenient"]["p"] == 0.556
    assert d["lenient_all"]["k"] == 8 and d["lenient_all"]["n"] == 12
    assert d["strict"]["wilson95"][0] < 0.222 < d["strict"]["wilson95"][1]


def test_repeat_consistency_is_reported_for_both_definitions(monkeypatch):
    _fake_mosaic(monkeypatch)
    a, b = _card(pid="a", lon=46.5), _card(pid="b", lon=46.6)
    rep1 = {**_card(pid="a-r", lon=46.5), "control": "repeat", "repeat_of": "a"}
    rep2 = {**_card(pid="b-r", lon=46.6), "control": "repeat", "repeat_of": "b"}
    _put_deck([a, b, rep1, rep2])
    review.verdict("a", "correct_clear"); review.verdict("b", "correct_clear")
    review.verdict("a-r", "correct_faint"); review.verdict("b-r", "wrong", "not_track")
    c = review.stats()["controls"]
    assert c["repeat_consistent"] == "1/2" and c["repeat_consistent_level"] == "0/2"


def test_api_accepts_new_verdicts_and_exposes_batches(tmp_path, monkeypatch):
    from fastapi.testclient import TestClient
    from annotator import api
    _fake_mosaic(monkeypatch)
    _put_deck([_card(pid="x")])
    review.import_batch(_batch_file(tmp_path, 8), 2)
    cl = TestClient(api.app)
    d = cl.get("/api/review/deck").json()
    assert d["progress"]["batch"] == 2 and "2" in d["batches"]
    pid = d["cards"][0]["pid"]
    assert cl.post("/api/review/verdict", json={"pid": pid, "verdict": "correct_faint", "ms": 3000}).status_code == 200
    assert cl.post("/api/review/verdict", json={"pid": d["cards"][1]["pid"], "verdict": "maybe"}).status_code == 400
    s = cl.get("/api/review/stats").json()["sources"]["desertmaps_new"]
    assert s["faint"] == 1


def test_ui_has_three_big_buttons_and_swipe_semantics():
    from pathlib import Path
    S = Path(__file__).resolve().parent.parent / "static"
    html, js = (S / "index.html").read_text(), (S / "review.js").read_text()
    for i in ("rv-right", "rv-faint", "rv-wrong"):
        assert f'id="{i}"' in html
    assert "if (dx > 90) send('correct_clear')" in js and "openReasons()" in js
    assert "correct_faint" in js and "strict" in js and "lenient" in js
