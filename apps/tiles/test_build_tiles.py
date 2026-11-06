"""python3 -m unittest test_build_tiles  (needs duckdb with the spatial extension, pmtiles, mapbox-vector-tile)"""
import gzip
import math
import os
import tempfile
import unittest

import mapbox_vector_tile as mvt
from pmtiles.reader import MmapSource, Reader

import build_tiles as bt

RIYADH = (46.6753, 24.7136)


def tile_of(lon, lat, z):
    n = 2 ** z
    return int((lon + 180) / 360 * n), int((1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n)


class Fixture(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.db = bt.connect()

    def write_places(self):
        path = os.path.join(self.dir, 'targets.parquet')
        lon, lat = RIYADH
        self.db.execute(f"""copy (select * from (values
            ('hh:1', 'ماكدونالدز', 'McDonald''s', 'food|fast_food', 'مطاعم', 'وجبات سريعة', 'McDonald''s', 'Sun: 08:00 - 24:00', 'العليا', 'open', null, 'point', {lon}, {lat}, '0500000000', 'a@b.sa'),
            ('hh:2', 'مغلق نهائي', null, 'food', 'مطاعم', null, null, null, 'العليا', 'مغلق نهائياً', null, 'point', {lon + 0.0005}, {lat}, null, null),
            ('hh:3', 'مغلق مؤقت', null, 'food', 'مطاعم', null, null, null, 'العليا', 'Temporarily closed', null, 'point', {lon + 0.001}, {lat}, null, null),
            ('gm:4', 'من قوقل', null, 'food', 'مطاعم', null, null, null, 'العليا', 'open', null, 'point', {lon + 0.0015}, {lat}, null, null),
            ('hh:5', 'موقع تقريبي', null, 'food', 'مطاعم', null, null, null, 'العليا', 'open', null, 'district', {lon + 0.002}, {lat}, null, null),
            ('hh:6', '', '', 'food', 'مطاعم', null, null, null, 'العليا', 'open', null, 'point', {lon + 0.0025}, {lat}, null, null),
            ('hh:7', 'دورة حياة مغلقة', null, 'food', 'مطاعم', null, null, null, 'العليا', 'open', 'closed', 'point', {lon + 0.003}, {lat}, null, null)
        ) t(poi_key, name_ar, name_en, category, category_ar, secondary_category, brand_name, working_hours, district_ar,
            company_status, lifecycle_state, location_precision, longitude, latitude, phone_norm, email)) to '{path}' (format parquet)""")
        return path

    def write_buildings(self, elevations):
        path = os.path.join(self.dir, 'buildings.parquet')
        lon, lat = RIYADH
        rows = []
        for i, e in enumerate(elevations):
            x = lon + i * 0.0003
            wkb = self.db.execute(f"select hex(ST_AsWKB(ST_MakeEnvelope({x}, {lat}, {x + 0.0002}, {lat + 0.0002})))").fetchone()[0]
            rows.append(f"('{1000 + i}', 'residential', '{e}', '{wkb}')")
        self.db.execute(f"""copy (select * from (values {', '.join(rows)}) t("HouseId", building_use, "Elevation", geometry_wkb_hex))
                            to '{path}' (format parquet)""")
        return path

    def roads(self):
        lon, lat = RIYADH
        self.db.execute(f"""create or replace temp table roads as select * from (values
            (1, ST_GeomFromText('LINESTRING({lon - 0.01} {lat}, {lon + 0.01} {lat})'), 'primary', 7, false, 'طريق الملك فهد', 'King Fahd Rd', null::varchar, 0, false, false, false, 0, 7),
            (2, ST_GeomFromText('LINESTRING({lon} {lat - 0.01}, {lon} {lat + 0.01})'), 'track', 11, false, null::varchar, null::varchar, null::varchar, 0, true, false, false, 0, 3)
        ) t(fid, g, class, minzoom, link, name_ar, name_en, ref, oneway, unpaved, bridge, tunnel, layer, rank)""")

    def read(self, path, z, lon=RIYADH[0], lat=RIYADH[1]):
        with open(path, 'rb') as fh:
            r = Reader(MmapSource(fh))
            data = r.get(z, *tile_of(lon, lat, z))
            meta = r.metadata()
        return (mvt.decode(gzip.decompress(data)) if data else {}), meta


class PlacesTests(Fixture):
    def test_only_open_precise_owned_places_and_no_contacts(self):
        n = bt.load_places(self.db, self.write_places())
        names = {r[0] for r in self.db.execute('select name_ar from places').fetchall()}
        self.assertEqual(names, {'ماكدونالدز', 'مغلق مؤقت'}, 'permanently closed, Google-sourced, imprecise, unnamed and lifecycle-closed rows are left out')
        self.assertEqual(n, 2)
        self.roads()
        out = os.path.join(self.dir, 'farq.pmtiles')
        bt.build(self.db, ['roads', 'places'], out, 13, 15, (46.6, 24.6, 46.8, 24.8), log=lambda *_: None)
        tile, meta = self.read(out, 15)
        props = [f['properties'] for f in tile['places']['features']]
        mc = next(p for p in props if p['name_ar'] == 'ماكدونالدز')
        self.assertEqual(mc['cat'], 'food')
        self.assertEqual(mc['hours'], 'Sun: 08:00 - 24:00')
        self.assertEqual(mc['fid'], 'hh:1')
        self.assertTrue(next(p for p in props if p['name_ar'] == 'مغلق مؤقت')['temp_closed'])
        for p in props:
            self.assertFalse({'phone', 'phone_norm', 'email', 'whatsapp'} & set(p), 'no contact field reaches a tile')
        self.assertIn('roads', tile, 'both layers in one tile')
        self.assertEqual([l['id'] for l in meta['vector_layers']], ['roads', 'places'])
        self.assertIn('OpenStreetMap', meta['attribution'])

    def test_missing_columns_do_not_break_an_older_release(self):
        path = os.path.join(self.dir, 'old.parquet')
        self.db.execute(f"copy (select 'hh:9' poi_key, 'بقالة' name_ar, {RIYADH[0]} longitude, {RIYADH[1]} latitude) to '{path}' (format parquet)")
        self.assertEqual(bt.load_places(self.db, path), 1)

    def test_caps_keep_brands_first_below_the_top_zoom(self):
        lon, lat = RIYADH
        rows = ', '.join(f"('hh:{i}', 'مكان {i}', {'null' if i else repr('علامة')}, {lon + (i % 30) * 0.00001}, {lat})" for i in range(200))
        path = os.path.join(self.dir, 'many.parquet')
        self.db.execute(f"copy (select * from (values {rows}) t(poi_key, name_ar, brand_name, longitude, latitude)) to '{path}' (format parquet)")
        bt.load_places(self.db, path)
        self.roads()
        out = os.path.join(self.dir, 'cap.pmtiles')
        bt.build(self.db, ['roads', 'places'], out, 13, 15, (46.6, 24.6, 46.8, 24.8), log=lambda *_: None)
        z13 = self.read(out, 13)[0]['places']['features']
        self.assertEqual(len(z13), bt.PLACE_CAP[13])
        self.assertIn('مكان 0', {f['properties']['name_ar'] for f in z13}, 'the brand survives the cap')
        self.assertEqual(len(self.read(out, 15)[0]['places']['features']), 200, 'top zoom is uncapped')


class BuildingTests(Fixture):
    def test_storeys_become_metres(self):
        bt.load_buildings(self.db, self.write_buildings([2, 3, 4, 0]))
        heights = sorted(r[0] for r in self.db.execute('select height from buildings').fetchall() if r[0] is not None)
        self.assertEqual(heights, [6.4, 9.6, 12.8])
        self.assertEqual(self.db.execute('select count(*) from buildings where height is null').fetchone()[0], 1, 'unknown height stays unknown')

    def test_metres_stay_metres(self):
        bt.load_buildings(self.db, self.write_buildings([12.5, 30, 9]))
        self.assertEqual(sorted(r[0] for r in self.db.execute('select height from buildings').fetchall()), [9.0, 12.5, 30.0])

    def test_buildings_only_from_their_min_zoom(self):
        bt.load_buildings(self.db, self.write_buildings([2, 3]))
        self.roads()
        out = os.path.join(self.dir, 'b.pmtiles')
        bt.build(self.db, ['roads', 'buildings'], out, 12, 15, (46.6, 24.6, 46.8, 24.8), log=lambda *_: None)
        self.assertNotIn('buildings', self.read(out, 13)[0])
        self.assertEqual(len(self.read(out, 15)[0]['buildings']['features']), 2)


class RoadTests(Fixture):
    def test_min_zoom_per_class_and_attributes(self):
        self.roads()
        out = os.path.join(self.dir, 'r.pmtiles')
        bt.build(self.db, ['roads'], out, 7, 12, (46.6, 24.6, 46.8, 24.8), log=lambda *_: None)
        z8 = self.read(out, 8)[0]['roads']['features']
        self.assertEqual([f['properties']['class'] for f in z8], ['primary'], 'the desert track appears from z11')
        z12 = {f['properties']['class']: f['properties'] for f in self.read(out, 12)[0]['roads']['features']}
        self.assertEqual(sorted(f['id'] for f in self.read(out, 12)[0]['roads']['features']), [1, 2], 'OSM way id is the feature id')
        self.assertEqual(z12['primary']['name_ar'], 'طريق الملك فهد')
        self.assertTrue(z12['track']['unpaved'])

    def test_tile_math(self):
        self.assertEqual(self.db.execute(f'select tile_x({RIYADH[0]}, 14), tile_y({RIYADH[1]}, 14)').fetchone(), tile_of(*RIYADH, 14))
        self.assertEqual(self.db.execute('select tile_x(180, 3), tile_y(-89, 3)').fetchone(), (7, 7), 'clamped to the grid')



class FetchAtlasTests(unittest.TestCase):
    class FakeS3:
        def __init__(self, objects):
            self.objects, self.downloaded = objects, []

        def get_paginator(self, _):
            objs = self.objects
            class P:
                def paginate(self, Bucket):
                    return [{'Contents': objs[:2]}, {'Contents': objs[2:]}]
            return P()

        def download_file(self, bucket, key, path):
            self.downloaded.append(key)
            with open(path, 'w') as fh:
                fh.write(key)

    def test_newest_targets_and_named_buildings(self):
        from datetime import datetime
        import fetch_atlas
        s3 = self.FakeS3([
            {'Key': 'releases/a/targets.parquet', 'LastModified': datetime(2026, 10, 1), 'Size': 10},
            {'Key': 'releases/b/targets.parquet.bak', 'LastModified': datetime(2026, 11, 5), 'Size': 10},
            {'Key': 'releases/c/targets.parquet', 'LastModified': datetime(2026, 11, 2), 'Size': 10},
            {'Key': 'releases/d/targets.parquet', 'LastModified': datetime(2026, 11, 4), 'Size': 0},
        ])
        self.assertEqual(fetch_atlas.newest(s3, 'b', 'targets.parquet'), 'releases/c/targets.parquet', 'newest non-empty exact name')
        dest = tempfile.mkdtemp()
        env = {'BUCKET': 'b', 'BUILDINGS_OBJECT': 'buildings/normalized.parquet'}
        old = {k: os.environ.get(k) for k in ('BUCKET', 'BUILDINGS_OBJECT', 'PLACES_OBJECT')}
        os.environ.update(env); os.environ.pop('PLACES_OBJECT', None)
        try:
            got = fetch_atlas.main(dest, s3)
        finally:
            for k, v in old.items():
                os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)
        self.assertEqual(got, {'places': 'releases/c/targets.parquet', 'buildings': 'buildings/normalized.parquet'})
        self.assertTrue(os.path.exists(os.path.join(dest, 'places.parquet')))
        self.assertFalse(any(f.endswith('.download') for f in os.listdir(dest)))

    def test_no_bucket_means_roads_only(self):
        import fetch_atlas
        old = os.environ.pop('BUCKET', None)
        try:
            self.assertEqual(fetch_atlas.main(tempfile.mkdtemp(), object()), {})
        finally:
            if old is not None:
                os.environ['BUCKET'] = old


if __name__ == '__main__':
    unittest.main()
