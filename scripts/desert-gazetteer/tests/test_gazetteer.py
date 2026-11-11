import json
import os
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

import build  # noqa: E402
import gazetteer as gz  # noqa: E402


# ---------------------------------------------------------------- names and kinds

@pytest.mark.parametrize("ar,en,kind", [
    ("روضة خريم", None, "rawda"),
    ("الروضه", None, "rawda"),
    ("رياض الخبراء", None, "rawda"),
    ("فيضة السر", None, "fayda"),
    ("فيضه نوره", None, "fayda"),
    ("نفود الثويرات", None, "nafud"),
    ("عروق بني معارض", None, "nafud"),
    ("رملة يام", None, "nafud"),
    ("الدهناء", None, "nafud"),
    ("الربع الخالي", None, "nafud"),
    ("وادي حنيفة", None, None),
    (None, "Rawḑat Nūrah", "rawda"),
    (None, "Fayḑat as Sirr", "fayda"),
    (None, "Nafūd ath Thuwayrāt", "nafud"),
    (None, "‘Irq al Qahhāb", "nafud"),
    (None, "Rub‘ al Khali", "nafud"),
    (None, "Wadi Hanifah", None),
])
def test_kind_from_names(ar, en, kind):
    assert gz.kind_from_names(ar, en) == kind


def test_norm_ar_matches_spellings():
    assert gz.norm_ar("روضة التنهات") == gz.norm_ar("روضه التنهات")
    assert gz.norm_ar("الدَّهْناء") == gz.norm_ar("الدهناء") == "دهناء"
    assert gz.norm_ar("نفود الثويرات") == "نفود ثويرات"


def test_norm_en_drops_marks_and_articles():
    assert gz.norm_en("Nafūd ath Thuwayrāt") == "nafud thuwayrat"
    assert gz.norm_en("Ad Dahnā’") == "dahna"


def test_osm_kindergarten_and_district_are_not_rawdas():
    assert gz.osm_kind({"name": "روضة الأطفال الأولى", "amenity": "kindergarten"}) is None
    assert gz.osm_kind({"name": "الروضة", "place": "suburb"}) is None
    assert gz.osm_kind({"name": "روضة سدير", "place": "town"}) is None
    assert gz.osm_kind({"name": "روضة خريم", "natural": "grassland"}) == "rawda"
    assert gz.osm_kind({"name": "روضة نورة", "place": "locality"}) == "rawda"


def test_osm_named_sand_is_nafud_even_without_a_prefix():
    assert gz.osm_kind({"name": "الغميس", "natural": "sand"}) == "nafud"
    assert gz.osm_kind({"natural": "sand"}) is None  # no name → nothing to show


def test_osm_names_keep_alternates():
    ar, en, alt = gz.osm_names({"name": "نفود الزراني", "name:en": "Nufud az Zarrani", "int_name": "Nufūd az Zarrānī", "alt_name": "النفود;نفود"})
    assert ar == "نفود الزراني" and en == "Nufud az Zarrani"
    assert "Nufūd az Zarrānī" in alt and "النفود" in alt and "نفود" in alt


def test_geonames_kind_by_code_and_name():
    assert gz.geonames_kind("DUNE", "‘Irq al Qahhāb", "`Irq al Qahhab", None) == "nafud"
    assert gz.geonames_kind("DPR", "Rawḑat Nūrah", "Rawdat Nurah", "روضة نورة") == "rawda"
    assert gz.geonames_kind("SBKH", "Fayḑat Su‘ūd", "Faydat Su`ud", None) == "fayda"
    assert gz.geonames_kind("PPL", "Rawḑat Sudayr", "Rawdat Sudayr", None) is None  # a town
    assert gz.geonames_kind("DPR", "Qā‘ al Jathūm", "Qa` al Jathum", None) is None


# ---------------------------------------------------------------- geometry

SQUARE = [[46.0, 24.0], [47.0, 24.0], [47.0, 25.0], [46.0, 25.0]]


def test_inside_and_edge_distance():
    assert gz.inside([46.5, 24.5], SQUARE)
    assert gz.distance_to_edge([46.5, 24.5], [SQUARE]) == 0
    d = gz.distance_to_edge([47.1, 24.5], [SQUARE])
    assert 9_000 < d < 11_000  # 0.1° of longitude at 24.5° N ≈ 10.1 km


def test_simplify_keeps_corners_drops_collinear():
    line = [[0, 0], [0.5, 0.0001], [1, 0], [1, 1]]
    assert gz.simplify(line, 0.001) == [[0, 0], [1, 0], [1, 1]]


def test_assemble_rings_joins_reversed_ways():
    a = [[0, 0], [1, 0], [1, 1]]
    b = [[0, 0], [0, 1], [1, 1]]  # runs the other way
    rings = gz.assemble_rings([a, b])
    assert len(rings) == 1 and len(rings[0]) == 4


def test_representative_point_inside_a_u_shape():
    u = [[0, 0], [3, 0], [3, 3], [2, 3], [2, 1], [1, 1], [1, 3], [0, 3]]
    p = gz.representative_point([u])
    assert gz.inside(p, u)


def test_compact_rings_bounds_size():
    import math
    circle = [[46 + math.cos(t / 500 * 2 * math.pi), 24 + math.sin(t / 500 * 2 * math.pi)] for t in range(500)]
    out = gz.compact_rings([circle], max_points=60)
    assert 3 <= sum(len(r) for r in out) <= 60
    assert gz.inside([46, 24], out[0])


# ---------------------------------------------------------------- merging

def entry(id_, kind, ar=None, en=None, pt=(46.5, 24.5), poly=None):
    e = {"id": id_, "kind": kind, "name_ar": ar, "name_en": en, "alt": [], "point": list(pt),
         "sources": [{"id": id_, "licence": "x"}]}
    if poly:
        e["polygon"] = poly
    return e


def test_merge_same_name_close_keeps_outline_id_and_all_sources():
    a = entry("geonames:1", "rawda", "روضة خريم", "Rawdat Khuraym", (47.30, 25.38))
    b = entry("osm:node/9", "rawda", "روضه خريم", None, (47.31, 25.39))
    c = entry("osm:way/5", "rawda", "روضة خريم", None, (47.305, 25.385), poly=[[[47.2, 25.3], [47.4, 25.3], [47.4, 25.5], [47.2, 25.5]]])
    out = gz.merge([a, b, c])
    assert len(out) == 1
    assert out[0]["id"] == "osm:way/5"
    assert {s["id"] for s in out[0]["sources"]} == {"geonames:1", "osm:node/9", "osm:way/5"}
    assert out[0]["name_en"] == "Rawdat Khuraym"


def test_merge_keeps_far_namesakes_apart():
    a = entry("osm:node/1", "rawda", "روضة الخفس", pt=(46.0, 25.0))
    b = entry("osm:node/2", "rawda", "روضة الخفس", pt=(45.0, 26.0))
    assert len(gz.merge([a, b])) == 2


def test_merge_never_crosses_kinds_or_merges_camps():
    a = entry("osm:node/1", "rawda", "روضة نورة")
    b = entry("osm:node/2", "fayda", "روضة نورة")
    c1 = entry("camp:a", "camp", "كشتة مقترحة")
    c2 = entry("camp:b", "camp", "كشتة مقترحة")
    assert len(gz.merge([a, b, c1, c2])) == 4


def test_merge_big_sand_sea_absorbs_points_inside_it():
    sea = entry("osm:relation/1", "nafud", "الدهناء", "Ad Dahna", (47.5, 25.0),
                poly=[[[46.5, 22.0], [48.5, 22.0], [48.5, 28.0], [46.5, 28.0]]])
    pt = entry("geonames:2", "nafud", "الدهناء", "Ad Dahna", (47.9, 26.8))
    assert len(gz.merge([pt, sea])) == 1


# ---------------------------------------------------------------- build (sources → entries)

def test_from_osm_node_way_relation(tmp_path):
    raw = {"elements": [
        {"type": "node", "id": 1, "lat": 25.38, "lon": 47.3, "tags": {"name": "روضة خريم", "place": "locality"}},
        {"type": "way", "id": 2, "tags": {"name": "نفود السر", "natural": "sand"},
         "geometry": [{"lat": 25, "lon": 45}, {"lat": 25, "lon": 45.5}, {"lat": 25.5, "lon": 45.5}, {"lat": 25.5, "lon": 45}, {"lat": 25, "lon": 45}]},
        {"type": "relation", "id": 3, "tags": {"name": "عرق الثمامة", "natural": "sand"}, "members": [
            {"type": "way", "role": "outer", "geometry": [{"lat": 26, "lon": 46}, {"lat": 26, "lon": 47}, {"lat": 27, "lon": 47}]},
            {"type": "way", "role": "outer", "geometry": [{"lat": 27, "lon": 47}, {"lat": 27, "lon": 46}, {"lat": 26, "lon": 46}]}]},
        {"type": "node", "id": 4, "lat": 24.7, "lon": 46.7, "tags": {"name": "روضة الأطفال", "amenity": "kindergarten"}},
        {"type": "node", "id": 5, "lat": 40.0, "lon": 10.0, "tags": {"name": "روضة بعيدة", "place": "locality"}},
    ]}
    out = {e["id"]: e for e in build.from_osm(raw)}
    assert set(out) == {"osm:node/1", "osm:way/2", "osm:relation/3"}
    assert out["osm:way/2"]["kind"] == "nafud" and out["osm:way/2"]["polygon"]
    assert gz.inside(out["osm:relation/3"]["point"], out["osm:relation/3"]["polygon"][0])
    assert out["osm:node/1"]["point"] == [47.3, 25.38]


def test_from_geonames_uses_arabic_alternates(tmp_path):
    main = tmp_path / "SA.txt"
    alt = tmp_path / "alt.txt"
    main.write_text("\t".join(["101", "Rawḑat Nūrah", "Rawdat Nurah", "", "25.6", "46.1", "T", "DPR", "SA"]) + "\n"
                    + "\t".join(["102", "Rawḑat Sudayr", "Rawdat Sudayr", "", "25.4", "45.6", "P", "PPL", "SA"]) + "\n", encoding="utf-8")
    alt.write_text("1\t101\tar\tروضة نورة\t1\n2\t101\tar\tروضه نوره\t\n", encoding="utf-8")
    out = build.from_geonames(str(main), str(alt))
    assert len(out) == 1
    e = out[0]
    assert e["id"] == "geonames:101" and e["kind"] == "rawda"
    assert e["name_ar"] == "روضة نورة" and e["name_en"] == "Rawdat Nurah"
    assert e["point"] == [46.1, 25.6]


def test_from_camps_reads_candidates(tmp_path):
    fc = {"type": "FeatureCollection", "properties": {"name": "الثمامة"}, "features": [
        {"type": "Feature", "geometry": {"type": "Point", "coordinates": [46.7, 25.3]},
         "properties": {"id": "thumamah-001", "region": "thumamah", "rank": 1, "score": 0.6, "near_name": "طعس دليل"}}]}
    p = tmp_path / "camp-sites-thumamah.geojson"
    p.write_text(json.dumps(fc, ensure_ascii=False), encoding="utf-8")
    out = build.from_camps(str(tmp_path / "camp-sites-*.geojson"))
    assert out[0]["id"] == "camp:thumamah-001" and out[0]["kind"] == "camp"
    assert out[0]["name_ar"] == "كشتة قرب طعس دليل"


# ---------------------------------------------------------------- the bundled file

BUNDLE = os.path.join(build.OUT)


@pytest.mark.skipif(not os.path.exists(BUNDLE), reason="not built yet")
def test_bundle_is_small_valid_and_sourced():
    assert os.path.getsize(BUNDLE) < 2_000_000
    doc = json.load(open(BUNDLE, encoding="utf-8"))
    ids = [e["id"] for e in doc["entries"]]
    assert len(ids) == len(set(ids)), "ids are unique"
    for e in doc["entries"]:
        assert e["kind"] in gz.KINDS
        assert e.get("name_ar") or e.get("name_en")
        assert build.in_saudi(e["point"])
        assert e["sources"] and all(s["id"] and s["licence"] for s in e["sources"])
        if e.get("polygon"):
            assert e.get("bbox")
    kinds = {e["kind"] for e in doc["entries"]}
    assert {"nafud", "rawda", "fayda", "camp"} <= kinds
