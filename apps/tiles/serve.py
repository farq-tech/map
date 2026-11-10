"""Serve the Farq tile archive to the apps, and rebuild it on a schedule.

    GET /farq.json                TileJSON (what the Mapbox SDK reads: tile URL, zooms, bounds, layers, attribution)
    GET /tiles/{z}/{x}/{y}.mvt    one vector tile (gzip, as stored); 204 where the archive has none
    GET /healthz                  200 once an archive is loaded, with when it was built
    GET /desert/manifest.json     «دروب البر» national route tiles: the manifest (scripts/camp-sites/tiles.py)
    GET /desert/tiles/{id}.bin    one route tile (SARYRT1, zlib, as built), id like t25_46; 404 where there is none

Environment:
    DESERT_DATA_DIR     where manifest.json and routes-t*.bin live (read-only)    default $TILES_DATA_DIR/desert
    DESERT_PUBLIC_BASE  if set (https://bucket-host/desert), the desert endpoints redirect there instead
    TILES_DATA_DIR      where farq.pmtiles lives (a persistent volume)          default /data
    PUBLIC_URL          the URL the apps reach this service at (for TileJSON)    default http://localhost:$PORT
    PORT                                                                          default 8080
    REBUILD_HOURS       0 = never; otherwise rebuild that often (build.sh)       default 168 (weekly)
    BUILD_ON_START      1 = build at boot when there is no archive yet; always = rebuild at every boot (the old
                        archive keeps serving until the new one is complete)  default 1

A rebuild writes a new file and renames it over the old one; the server notices the new file and switches to it on
the next request, so tiles are never served from half an archive.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from pmtiles.reader import MmapSource, Reader

DATA = os.environ.get('TILES_DATA_DIR', '/data')
ARCHIVE = os.path.join(DATA, 'farq.pmtiles')
PORT = int(os.environ.get('PORT', '8080'))
PUBLIC_URL = os.environ.get('PUBLIC_URL', f'http://localhost:{PORT}').rstrip('/')
REBUILD_HOURS = float(os.environ.get('REBUILD_HOURS', '168'))
HERE = os.path.dirname(os.path.abspath(__file__))
TILE = re.compile(r'^/tiles/(\d{1,2})/(\d+)/(\d+)\.(?:mvt|pbf)$')
DESERT_DIR = os.environ.get('DESERT_DATA_DIR', os.path.join(DATA, 'desert'))
DESERT_PUBLIC_BASE = os.environ.get('DESERT_PUBLIC_BASE', '').rstrip('/')
DESERT_TILE = re.compile(r'^/desert/tiles/(t\d{1,2}_\d{1,3})\.bin$')


def desert_file(path: str, directory: str | None = None):
    """(file path, cache seconds) for a desert request path, or None. Only the manifest and well-formed
    tile names map to files: no other path can reach the disk."""
    directory = directory or DESERT_DIR
    if path == '/desert/manifest.json':
        return os.path.join(directory, 'manifest.json'), 300
    m = DESERT_TILE.match(path)
    if m:
        return os.path.join(directory, f'routes-{m.group(1)}.bin'), 86400
    return None


def desert_etag(file: str) -> str:
    st = os.stat(file)
    return f'"{st.st_mtime_ns:x}-{st.st_size:x}"'


class Archive:
    """The current archive, reopened when the file on disk is replaced."""

    def __init__(self, path: str):
        self.path = path
        self.lock = threading.Lock()
        self.stamp = None
        self.fh = None
        self.reader = None
        self.header = None
        self.meta = None

    def current(self):
        try:
            st = os.stat(self.path)
        except FileNotFoundError:
            return None
        stamp = (st.st_ino, st.st_mtime_ns, st.st_size)
        with self.lock:
            if stamp != self.stamp:
                fh = open(self.path, 'rb')
                reader = Reader(MmapSource(fh))
                header, meta = reader.header(), reader.metadata()
                old = self.fh
                self.fh, self.reader, self.header, self.meta, self.stamp = fh, reader, header, meta, stamp
                if old:
                    # requests that already hold the old reader finish first; the OS keeps the replaced file alive
                    threading.Timer(30, old.close).start()
            return self.reader, self.header, self.meta


ARCH = Archive(ARCHIVE)


def tilejson(header, meta) -> dict:
    e7 = lambda k: header[k] / 1e7
    return {
        'tilejson': '3.0.0', 'name': 'farq', 'scheme': 'xyz',
        'tiles': [f'{PUBLIC_URL}/tiles/{{z}}/{{x}}/{{y}}.mvt'],
        'minzoom': header['min_zoom'], 'maxzoom': header['max_zoom'],
        'bounds': [e7('min_lon_e7'), e7('min_lat_e7'), e7('max_lon_e7'), e7('max_lat_e7')],
        'center': [e7('center_lon_e7'), e7('center_lat_e7'), header['center_zoom']],
        'attribution': meta.get('attribution', ''), 'vector_layers': meta.get('vector_layers', []),
        'version': meta.get('built_at', ''),
    }


class Handler(BaseHTTPRequestHandler):
    server_version = 'farq-tiles'

    def log_message(self, *_):  # no request log: tile coordinates say where people look
        pass

    def send(self, code, body=b'', ctype='application/json', headers=None):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Access-Control-Allow-Origin', '*')
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)

    def do_HEAD(self):
        self.do_GET()

    def desert(self, path):
        """The «دروب البر» manifest and tiles, read-only, independent of the vector archive."""
        found = desert_file(path)
        if not found:
            return self.send(404, b'{"error":"NOT_FOUND"}')
        file, max_age = found
        if DESERT_PUBLIC_BASE:
            return self.send(302, headers={'Location': DESERT_PUBLIC_BASE + '/' + os.path.basename(file),
                                           'Cache-Control': f'public, max-age={max_age}'})
        try:
            etag = desert_etag(file)
            with open(file, 'rb') as f:
                body = f.read()
        except FileNotFoundError:
            return self.send(404, b'{"error":"NOT_FOUND"}', headers={'Cache-Control': 'public, max-age=300'})
        # The manifest is short-lived (a rebuild replaces it). A tile is checked against the manifest's sha256 by
        # the app, so a day of caching never makes it use a stale tile unknowingly.
        swr = ', stale-while-revalidate=604800' if max_age > 300 else ''
        cache = {'Cache-Control': f'public, max-age={max_age}{swr}', 'ETag': etag}
        if self.headers.get('If-None-Match') == etag:
            return self.send(304, headers=cache)
        ctype = 'application/json' if file.endswith('.json') else 'application/octet-stream'
        return self.send(200, body, ctype, cache)

    def do_GET(self):
        path = self.path.split('?', 1)[0]
        if path.startswith('/desert/'):
            return self.desert(path)
        arch = ARCH.current()
        if path == '/healthz':
            if not arch:
                return self.send(503, b'{"ok":false,"reason":"no archive yet"}')
            return self.send(200, json.dumps({'ok': True, 'built_at': arch[2].get('built_at')}).encode())
        if not arch:
            return self.send(503, b'{"error":"NOT_BUILT"}')
        reader, header, meta = arch
        version = meta.get('built_at', '')
        if path == '/farq.json':
            return self.send(200, json.dumps(tilejson(header, meta), ensure_ascii=False).encode(),
                             headers={'Cache-Control': 'public, max-age=300'})
        m = TILE.match(path)
        if not m:
            return self.send(404, b'{"error":"NOT_FOUND"}')
        z, x, y = (int(v) for v in m.groups())
        if not (0 <= x < 2 ** z and 0 <= y < 2 ** z):
            return self.send(404, b'{"error":"NOT_FOUND"}')
        etag = f'"{version}"'
        if self.headers.get('If-None-Match') == etag:
            return self.send(304, headers={'ETag': etag})
        data = reader.get(z, x, y) if header['min_zoom'] <= z <= header['max_zoom'] else None
        cache = {'Cache-Control': 'public, max-age=86400, stale-while-revalidate=604800', 'ETag': etag}
        if not data:
            return self.send(204, headers=cache)
        return self.send(200, data, 'application/vnd.mapbox-vector-tile', {**cache, 'Content-Encoding': 'gzip'})


def rebuild_forever():
    mode = os.environ.get('BUILD_ON_START', '1')
    if mode == 'always' or (mode == '1' and not os.path.exists(ARCHIVE)):
        run_build()
    if REBUILD_HOURS <= 0:
        return
    while True:
        time.sleep(REBUILD_HOURS * 3600)
        run_build()


def run_build():
    started = time.time()
    print('tiles: rebuild started', flush=True)
    code = subprocess.call(['sh', os.path.join(HERE, 'build.sh')])
    print(f'tiles: rebuild {"done" if code == 0 else f"FAILED ({code}); the previous archive stays live"} in {time.time() - started:.0f}s', flush=True)


def main():
    os.makedirs(DATA, exist_ok=True)
    threading.Thread(target=rebuild_forever, daemon=True).start()
    print(f'tiles: serving {ARCHIVE} on :{PORT} as {PUBLIC_URL}', flush=True)
    ThreadingHTTPServer(('0.0.0.0', PORT), Handler).serve_forever()


if __name__ == '__main__':
    main()
