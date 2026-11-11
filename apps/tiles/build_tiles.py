"""Farq map tiles: one PMTiles archive with three vector layers, drawn over satellite imagery in the apps.

    roads      OpenStreetMap highways (© OpenStreetMap contributors, ODbL), Arabic name first. Fresh each build:
               the extract is downloaded new every time (build.sh), so a street opened last week is on the map.
    places     Farq Atlas golden directory (targets.parquet): name, category, hours, temporary closure.
               Permanently closed places, imprecise points and Google-sourced rows are left out, and no contact
               field (phone, WhatsApp, e-mail) is ever written into a tile.
    buildings  Farq Atlas building footprints (buildings.parquet from normalize_buildings.py), with a height
               for 3D when the source carries one.

Every layer is optional except roads, so a build without Atlas files still gives fresh streets.

Usage:
    python3 build_tiles.py --osm saudi_arabia.osm.pbf [--places targets.parquet] [--buildings buildings.parquet]
                           --out farq.pmtiles [--bbox minlon,minlat,maxlon,maxlat] [--max-zoom 15]

The archive is written beside --out and renamed into place only when complete, so a server reading --out never
sees half a file.
"""
from __future__ import annotations

import argparse
import gzip
import json
import math
import os
import shutil
import sys
import time
from datetime import datetime, timezone

import duckdb
from pmtiles.tile import Compression, TileType, zxy_to_tileid
from pmtiles.writer import Writer
from duckdb.sqltypes import BIGINT, UBIGINT

EXTENT = 4096
BUFFER = 64
EARTH = 40075016.68557849  # web-mercator world width in metres
ATTRIBUTION = '© OpenStreetMap contributors · Farq Atlas'

# OSM highway → (class, min zoom). Anything not listed (construction, proposed, raceway…) is not drawn.
ROAD_CLASSES = {
    'motorway': ('motorway', 5), 'trunk': ('trunk', 5), 'primary': ('primary', 7), 'secondary': ('secondary', 9),
    'tertiary': ('tertiary', 10),
    'motorway_link': ('motorway', 10), 'trunk_link': ('trunk', 10), 'primary_link': ('primary', 11),
    'secondary_link': ('secondary', 12), 'tertiary_link': ('tertiary', 12),
    'unclassified': ('minor', 12), 'residential': ('minor', 12), 'living_street': ('minor', 13), 'road': ('minor', 13),
    'service': ('service', 14),
    # desert and farm tracks: what an outing drives on
    'track': ('track', 11),
    'pedestrian': ('path', 14), 'footway': ('path', 14), 'path': ('path', 14), 'steps': ('path', 14), 'cycleway': ('path', 14),
}
UNPAVED = ('unpaved', 'dirt', 'sand', 'gravel', 'fine_gravel', 'ground', 'earth', 'compacted', 'mud', 'rock', 'pebblestone', 'salt')

# Per-tile caps for places: below the archive's top zoom only the most useful places fit, so labels stay readable.
PLACE_MIN_ZOOM = 13
PLACE_CAP = {13: 120, 14: 600}   # the top zoom is uncapped (every place appears once you zoom in)
BUILDING_MIN_ZOOM = 14

ARABIC_RE = '[؀-ۿ]'


def connect(memory: str | None = None, temp_directory: str | None = None) -> duckdb.DuckDBPyConnection:
    db = duckdb.connect()
    db.execute('LOAD spatial')
    if memory:
        db.execute(f"SET memory_limit='{memory}'")
    if temp_directory:
        os.makedirs(temp_directory, exist_ok=True)
        escaped = temp_directory.replace("'", "''")
        db.execute(f"SET temp_directory='{escaped}'")
    db.execute('SET preserve_insertion_order=false')
    # XYZ tile index of a lon/lat at zoom z (web mercator, latitude clamped to its valid range).
    db.execute("""create or replace macro tile_x(lon, z) as
        least((1 << z) - 1, greatest(0, cast(floor((lon + 180.0) / 360.0 * (1 << z)) as integer)))""")
    db.execute("""create or replace macro tile_y(lat, z) as
        least((1 << z) - 1, greatest(0, cast(floor((1.0 - ln(tan(radians(least(85.0511, greatest(-85.0511, lat))))
              + 1.0 / cos(radians(least(85.0511, greatest(-85.0511, lat))))) / pi()) / 2.0 * (1 << z)) as integer)))""")
    return db


def columns_of(db, path: str) -> set[str]:
    return {r[0] for r in db.execute('describe select * from read_parquet(?)', [path]).fetchall()}


def col(cols: set[str], name: str, cast: str = 'varchar') -> str:
    """The column if this release has it, else NULL: older Atlas releases lack some enrichment columns."""
    return f'cast(p."{name}" as {cast})' if name in cols else f'cast(null as {cast})'


def bbox_sql(bbox, lon='lon', lat='lat') -> str:
    if not bbox:
        return 'true'
    a, b, c, d = bbox
    return f'{lon} between {a} and {c} and {lat} between {b} and {d}'


# ---------------------------------------------------------------- roads

def load_roads(db, pbf: str, bbox=None) -> int:
    kinds = ', '.join(f"'{k}'" for k in ROAD_CLASSES)
    cls = ' '.join(f"when '{k}' then '{v[0]}'" for k, v in ROAD_CLASSES.items())
    mz = ' '.join(f"when '{k}' then {v[1]}" for k, v in ROAD_CLASSES.items())
    unpaved = ', '.join(f"'{s}'" for s in UNPAVED)
    db.execute(f"""create or replace temp table w as
        select id, refs, tags['highway'] hw,
          coalesce(tags['name:ar'], case when regexp_matches(coalesce(tags['name'], ''), '{ARABIC_RE}') then tags['name'] end) name_ar,
          coalesce(tags['name:en'], case when regexp_matches(coalesce(tags['name'], ''), '^[^{ARABIC_RE[1:-1]}]*[A-Za-z]') then tags['name'] end) name_en,
          tags['ref'] ref, tags['oneway'] oneway, tags['surface'] surface, tags['bridge'] bridge, tags['tunnel'] tunnel, tags['layer'] layer
        from ST_ReadOSM('{pbf}') where kind = 'way' and tags['highway'] in ({kinds}) and len(refs) >= 2""")
    db.execute(f"""create or replace temp table nd as
        select id, lon, lat from ST_ReadOSM('{pbf}')
        where kind = 'node' and id in (select distinct unnest(refs) from w)""")
    db.execute(f"""create or replace temp table road_src as
        select w.id fid, w.hw, w.name_ar, w.name_en, w.ref, w.oneway, w.surface, w.bridge, w.tunnel, w.layer,
               ST_MakeLine(list(ST_Point(nd.lon, nd.lat) order by r.ord)) g
        from w, unnest(w.refs) with ordinality as r(ref, ord) join nd on nd.id = r.ref
        group by all having count(*) >= 2""")
    db.execute(f"""create or replace temp table roads as
        select fid, g,
          case hw {cls} end as class,
          (case hw {mz} end)::integer as minzoom,
          hw like '%\\_link' escape '\\' as link,
          name_ar, name_en, ref,
          case when oneway in ('yes', '1', 'true') then 1 when oneway = '-1' then -1 else 0 end as oneway,
          (hw = 'track' or lower(coalesce(surface, '')) in ({unpaved})) as unpaved,
          coalesce(bridge, 'no') not in ('no', '0', 'false') as bridge,
          coalesce(tunnel, 'no') not in ('no', '0', 'false') as tunnel,
          coalesce(try_cast(layer as integer), 0) as layer,
          -- draw order inside the layer: major roads on top
          case case hw {cls} end when 'motorway' then 9 when 'trunk' then 8 when 'primary' then 7 when 'secondary' then 6
               when 'tertiary' then 5 when 'minor' then 4 when 'track' then 3 when 'service' then 2 else 1 end as rank
        from road_src""")
    if bbox:
        db.execute(f"delete from roads where not ST_Intersects(g, ST_MakeEnvelope({bbox[0]}, {bbox[1]}, {bbox[2]}, {bbox[3]}))")
    db.execute('drop table w; drop table nd; drop table road_src')
    return db.execute('select count(*) from roads').fetchone()[0]


# ---------------------------------------------------------------- places (Farq Atlas)

# Contacts never reach a map (CLAUDE.md): some directory names carry a mobile number or «واتساب 05…» inside the name.
DIGIT = '[0-9٠-٩۰-۹]'
PHONE_RE = rf'\+?{DIGIT}[0-9٠-٩۰-۹ ().\-]{{5,}}{DIGIT}'          # 7+ characters of digits: a phone, never a name
EMAIL_RE = r'[^\s@]+@[^\s@]+\.[A-Za-z]{2,}'
CONTACT_RE = r'(?i)(للتواصل|تواصل|اتصل|واتس ?[اآ]ب|واتساب|وتساب|واتس|whats ?app|wa\.me|call|tel[.:]?|mobile|phone|جوال ?:|هاتف ?:|ج ?:|ت ?:)'
TRAILING_RE = r'[\s\-–—:|/,،.(\[]+$'


def scrubbed(expr: str) -> str:
    """SQL: a name without any phone number, e-mail or «للتواصل / واتساب …» tail; null when nothing is left.
    With a contact in it, the name is cut at the first contact word or number; if that leaves nothing (the
    number came first), only the numbers and e-mails are taken out."""
    has = f"(regexp_matches({expr}, '{PHONE_RE}') or regexp_matches({expr}, '{EMAIL_RE}'))"
    cut = f"regexp_replace({expr}, '({CONTACT_RE}|{PHONE_RE}|{EMAIL_RE}).*$', '')"
    bare = f"regexp_replace(regexp_replace({expr}, '{PHONE_RE}', '', 'g'), '{EMAIL_RE}', '', 'g')"
    def clean(e):
        return f"nullif(trim(regexp_replace(trim({e}), '{TRAILING_RE}', '')), '')"
    return f"(case when {has} then coalesce({clean(cut)}, {clean(bare)}) else nullif(trim({expr}), '') end)"


def load_places(db, path: str, bbox=None) -> int:
    cols = columns_of(db, path)
    status = f"lower(trim(replace(coalesce({col(cols, 'company_status')}, ''), 'ـ', '')))"
    lifecycle = f"lower(trim(coalesce({col(cols, 'lifecycle_state')}, '')))"
    permanent = "('permanently closed','closed permanently','closed permanent','closed','cancelled','canceled','ملغي','ملغى'," \
                "'مغلق','مغلقة','مغلق نهائيا','مغلق نهائياً','مغلقة نهائيا','مغلقة نهائياً','مغلقه نهائيا','مغلقه نهائياً')"
    temporary = "('temporary closed','temporarily closed','closed temporary','closed temporarily','مغلق مؤقتا','مغلق مؤقتاً'," \
                "'مغلقة مؤقتا','مغلقة مؤقتاً','مغلقه مؤقتا','مغلقه مؤقتاً')"
    precision = f"coalesce({col(cols, 'location_precision')}, 'point')"
    name_ar, name_en, brand = (scrubbed(col(cols, c)) for c in ('name_ar', 'name_en', 'brand_name'))
    name = f"coalesce({name_ar}, {name_en})"
    category = f"split_part(coalesce({col(cols, 'category')}, ''), '|', 1)"
    db.execute(f"""create or replace temp table places as
        select p.poi_key::varchar as fid,
               ST_Point(p.longitude::double, p.latitude::double) g,
               {PLACE_MIN_ZOOM} as minzoom,
               {name_ar} as name_ar,
               {name_en} as name_en,
               nullif(trim({category}), '') as cat,
               nullif(trim({col(cols, 'category_ar')}), '') as cat_ar,
               nullif(trim({col(cols, 'secondary_category')}), '') as sub,
               {brand} as brand,
               nullif(trim({col(cols, 'working_hours')}), '') as hours,
               nullif(trim({col(cols, 'district_ar')}), '') as district,
               ({status} in {temporary}) as temp_closed,
               -- labels kept first when a tile is full: brands, then places with hours, then the rest
               (case when {brand} is not null then 2 else 0 end
                + case when nullif(trim({col(cols, 'working_hours')}), '') is not null then 1 else 0 end) as rank
        from read_parquet('{path}') p
        where p.poi_key is not null and p.longitude between -180 and 180 and p.latitude between -85 and 85
          and {name} is not null
          and {precision} = 'point'
          and {status} not in {permanent} and {lifecycle} not in ('closed', 'permanently closed', 'closed permanently')
          and not starts_with(p.poi_key::varchar, 'gm:')
          and {bbox_sql(bbox, 'p.longitude', 'p.latitude')}""")
    return db.execute('select count(*) from places').fetchone()[0]


# ---------------------------------------------------------------- buildings (Farq Atlas)

def load_buildings(db, path: str, bbox=None) -> int:
    cols = columns_of(db, path)
    elevation = col(cols, 'Elevation', 'double')
    use = col(cols, 'building_use')
    key = 'p."HouseId"::varchar' if 'HouseId' in cols else ('p.source_feature_id::varchar' if 'source_feature_id' in cols else 'cast(row_number() over () as varchar)')
    db.execute(f"""create or replace temp table b_src as
        with decoded as (
            select {key} fid, ST_GeomFromWKB(from_hex(p.geometry_wkb_hex)) original_g,
                   {use} as "use", {elevation} elevation
            from read_parquet('{path}') p where coalesce(p.geometry_wkb_hex, '') <> ''
        )
        select fid,
               case when ST_IsValid(original_g) then original_g
                    else ST_CollectionExtract(ST_MakeValid(original_g), 3) end g,
               use, elevation
        from decoded""")
    # Elevation is storeys in some vendor layers and metres in others (build_building_population.decide_elevation_mode)
    median = db.execute('select median(elevation) from b_src where elevation > 0').fetchone()[0]
    as_metres = median is not None and median >= 8
    height = 'least(250, elevation)' if as_metres else 'least(60, round(elevation)) * 3.2'
    db.execute(f"""create or replace temp table buildings as
        select fid, g, {BUILDING_MIN_ZOOM} as minzoom, use,
               case when elevation > 0 then round({height}, 1) end as height
        from b_src where g is not null and not ST_IsEmpty(g)""")
    if bbox:
        db.execute(f"delete from buildings where not ST_Intersects(g, ST_MakeEnvelope({bbox[0]}, {bbox[1]}, {bbox[2]}, {bbox[3]}))")
    db.execute('drop table b_src')
    return db.execute('select count(*) from buildings').fetchone()[0]


# ---------------------------------------------------------------- tiling

LAYER_ATTRS = {
    'roads': ['class', 'link', 'name_ar', 'name_en', 'ref', 'oneway', 'unpaved', 'bridge', 'tunnel', 'layer', 'rank'],
    'places': ['fid', 'name_ar', 'name_en', 'cat', 'cat_ar', 'sub', 'brand', 'hours', 'district', 'temp_closed'],
    'buildings': ['use', 'height'],
}


def prepare_layer(db, table: str) -> None:
    """Mercator geometry and the lon/lat box of every feature, once."""
    db.execute(f"""create or replace temp table {table}_m as
        select *, ST_Transform(g, 'EPSG:4326', 'EPSG:3857', always_xy := true) gm,
               ST_XMin(g) x0, ST_YMin(g) y0, ST_XMax(g) x1, ST_YMax(g) y1
        from {table}""")


def layer_tiles_sql(table: str, z: int, max_zoom: int) -> str:
    """One (x, y, blob) row per tile of this layer at zoom z."""
    # roads carry the OSM way id as the feature id, so a road cut at a tile edge is one road to the apps
    names = LAYER_ATTRS[table] + (['fid'] if table == 'roads' else [])
    attrs = ', '.join(names)
    struct = ', '.join(f'{a}: {a}' for a in names)
    id_arg = ", 'fid'" if table == 'roads' else ''
    world_px = EARTH / (1 << z) / EXTENT
    # simplify to about one pixel below the top zoom; points are never simplified
    geom = 'gm' if z >= max_zoom or table == 'places' else f'ST_SimplifyPreserveTopology(gm, {world_px:.6f})'
    cap = PLACE_CAP.get(z) if table == 'places' and z < max_zoom else None
    order = 'rank desc, fid' if table == 'places' else ('rank desc' if table == 'roads' else 'fid')
    ranked = f"""select *, row_number() over (partition by x, y order by {order}) n from t""" if cap else 'select * from t'
    return f"""
        with f as (
            select *, {geom} gz from {table}_m where minzoom <= {z}
        ), t as (
            select tx.x, ty.y, f.*
            from f,
                 lateral (select unnest(range(tile_x(f.x0, {z}), tile_x(f.x1, {z}) + 1)) x) tx,
                 lateral (select unnest(range(tile_y(f.y1, {z}), tile_y(f.y0, {z}) + 1)) y) ty
        ), r as ({ranked}), c as (
            select x, y, {attrs},
                   ST_AsMVTGeom(gz, ST_Extent(ST_TileEnvelope({z}, x::integer, y::integer)), {EXTENT}, {BUFFER}, true) geom
            from r {f'where n <= {cap}' if cap else ''}
        )
        select x, y, ST_AsMVT({{{struct}, geom: geom}}, '{table}', {EXTENT}, 'geom'{id_arg}) blob
        from c where geom is not null and not ST_IsEmpty(geom)
        group by x, y"""


def build(db, layers: list[str], out: str, min_zoom: int, max_zoom: int, bounds, log=print) -> dict:
    for t in layers:
        prepare_layer(db, t)
    tmp = out + '.partial'
    stats = {'tiles': 0, 'bytes': 0, 'per_zoom': {}}
    started = time.time()
    with open(tmp, 'wb') as fh:
        writer = Writer(fh)
        for z in range(min_zoom, max_zoom + 1):
            parts = [layer_tiles_sql(t, z, max_zoom) for t in layers
                     if db.execute(f'select count(*) from {t}_m where minzoom <= {z}').fetchone()[0]]
            if not parts:
                continue
            # one MVT per tile: layers are concatenated (protobuf repeated field), roads first so places draw on top
            union = ' union all '.join(f'select {i} li, * from ({p})' for i, p in enumerate(parts))
            cursor = db.execute(f"""with recursive tiles as (
                                     select x, y from ({union}) group by x, y
                                 ), hilbert as (
                                     select x tile_x, y tile_y, {z - 1}::integer a, x::bigint hx, y::bigint hy,
                                            (((1::bigint << ({z * 2})) - 1) // 3)::ubigint acc
                                     from tiles
                                     union all
                                     select tile_x, tile_y, a - 1,
                                            case when ry = 0 then case when rx <> 0 then s - 1 - hy else hy end else hx end,
                                            case when ry = 0 then case when rx <> 0 then s - 1 - hx else hx end else hy end,
                                            acc + case when rx = 0 and ry = 0 then 0
                                                       when rx = 0 and ry = s then 1::bigint << (2 * a)
                                                       when rx = s and ry = 0 then 3::bigint << (2 * a)
                                                       else 2::bigint << (2 * a) end
                                     from (select *, (1::bigint << a) s, ((1::bigint << a) & hx) rx,
                                                  ((1::bigint << a) & hy) ry
                                           from hilbert where a >= 0) state
                                 ), ordered as (
                                     select tile_x, tile_y, acc from hilbert where a = -1
                                 )
                                 select ordered.tile_x x, ordered.tile_y y, list(blob order by li) blobs
                                 from ({union}) tile_blobs
                                 join ordered on ordered.tile_x = tile_blobs.x and ordered.tile_y = tile_blobs.y
                                 group by ordered.tile_x, ordered.tile_y, ordered.acc
                                 order by ordered.acc""")
            zoom_tiles = 0
            while rows := cursor.fetchmany(256):
                for x, y, blobs in rows:
                    data = gzip.compress(b''.join(bytes(b) for b in blobs), mtime=0)
                    writer.write_tile(zxy_to_tileid(z, x, y), data)
                    stats['bytes'] += len(data)
                    zoom_tiles += 1
            stats['tiles'] += zoom_tiles
            stats['per_zoom'][z] = zoom_tiles
            log(f'  z{z}: {zoom_tiles} tiles ({time.time() - started:.0f}s)')
        built = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        metadata = {
            'name': 'farq', 'attribution': ATTRIBUTION, 'built_at': built, 'format': 'pbf',
            'vector_layers': [{'id': t, 'fields': {a: 'String' for a in LAYER_ATTRS[t]},
                               'minzoom': {'roads': 5, 'places': PLACE_MIN_ZOOM, 'buildings': BUILDING_MIN_ZOOM}[t], 'maxzoom': max_zoom}
                              for t in layers],
        }
        lon0, lat0, lon1, lat1 = bounds
        writer.finalize({
            'tile_type': TileType.MVT, 'tile_compression': Compression.GZIP,
            'min_lon_e7': int(lon0 * 1e7), 'min_lat_e7': int(lat0 * 1e7), 'max_lon_e7': int(lon1 * 1e7), 'max_lat_e7': int(lat1 * 1e7),
            'center_zoom': 10, 'center_lon_e7': int((lon0 + lon1) / 2 * 1e7), 'center_lat_e7': int((lat0 + lat1) / 2 * 1e7),
        }, metadata)
    os.replace(tmp, out)
    stats['built_at'] = metadata['built_at']
    return stats


SAUDI = (34.4, 16.3, 55.7, 32.2)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--osm', required=True, help='OpenStreetMap extract (.osm.pbf)')
    ap.add_argument('--places', help='Farq Atlas targets.parquet')
    ap.add_argument('--buildings', help='Farq Atlas buildings.parquet (normalize_buildings.py output)')
    ap.add_argument('--out', required=True)
    ap.add_argument('--bbox', help='minlon,minlat,maxlon,maxlat (a test area; default all of Saudi Arabia)')
    ap.add_argument('--min-zoom', type=int, default=5)
    ap.add_argument('--max-zoom', type=int, default=15)
    ap.add_argument('--memory', default=os.environ.get('TILES_MEMORY_LIMIT', '6GB'))
    a = ap.parse_args(argv)
    bbox = tuple(float(v) for v in a.bbox.split(',')) if a.bbox else None
    temp_dir = os.path.join(os.path.dirname(os.path.abspath(a.out)), '.farq-duckdb-tmp')
    db = connect(a.memory, temp_dir)
    t = time.time()
    try:
        layers = []
        n = load_roads(db, a.osm, bbox); layers.append('roads'); print(f'roads: {n:,} ({time.time() - t:.0f}s)')
        if a.places:
            n = load_places(db, a.places, bbox); layers.append('places'); print(f'places: {n:,}')
        if a.buildings:
            n = load_buildings(db, a.buildings, bbox); layers.append('buildings'); print(f'buildings: {n:,}')
        stats = build(db, layers, a.out, a.min_zoom, a.max_zoom, bbox or SAUDI)
        report = {'layers': layers, **stats, 'osm': os.path.basename(a.osm), 'seconds': round(time.time() - t)}
        with open(a.out + '.report.json', 'w') as fh:
            json.dump(report, fh, ensure_ascii=False, indent=2)
        print(json.dumps({k: v for k, v in report.items() if k != 'per_zoom'}, ensure_ascii=False))
        return 0
    finally:
        db.close()
        shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
