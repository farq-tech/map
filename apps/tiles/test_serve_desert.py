"""The «دروب البر» endpoints of serve.py: manifest and route tiles, read-only, with caching headers."""
import http.client
import json
import os
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer

import serve


class DesertEndpointsTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        d = self.dir.name
        self.manifest = {'format': 'SARYRT1', 'version': 'test', 'tiles': [{'id': 't25_46', 'bytes': 5, 'sha256': 'x'}]}
        with open(os.path.join(d, 'manifest.json'), 'w') as f:
            json.dump(self.manifest, f)
        with open(os.path.join(d, 'routes-t25_46.bin'), 'wb') as f:
            f.write(b'\x78\x9c' + b'tile')
        with open(os.path.join(d, 'secret.txt'), 'w') as f:
            f.write('no')
        self.old = (serve.DESERT_DIR, serve.DESERT_PUBLIC_BASE)
        serve.DESERT_DIR, serve.DESERT_PUBLIC_BASE = d, ''
        self.httpd = ThreadingHTTPServer(('127.0.0.1', 0), serve.Handler)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        serve.DESERT_DIR, serve.DESERT_PUBLIC_BASE = self.old
        self.dir.cleanup()

    def get(self, path, headers=None, method='GET'):
        c = http.client.HTTPConnection('127.0.0.1', self.httpd.server_address[1], timeout=5)
        c.request(method, path, headers=headers or {})
        r = c.getresponse()
        body = r.read()
        c.close()
        return r.status, dict(r.getheaders()), body

    def test_manifest_is_served_without_an_archive(self):
        status, h, body = self.get('/desert/manifest.json')
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), self.manifest)
        self.assertEqual(h['Content-Type'], 'application/json')
        self.assertEqual(h['Cache-Control'], 'public, max-age=300')
        self.assertTrue(h['ETag'].startswith('"'))

    def test_tile_bytes_as_stored_with_long_cache_and_etag(self):
        status, h, body = self.get('/desert/tiles/t25_46.bin')
        self.assertEqual(status, 200)
        self.assertEqual(body, b'\x78\x9ctile')
        self.assertEqual(h['Content-Type'], 'application/octet-stream')
        self.assertIn('max-age=86400', h['Cache-Control'])
        status, _, body = self.get('/desert/tiles/t25_46.bin', {'If-None-Match': h['ETag']})
        self.assertEqual((status, body), (304, b''))
        status, h2, body = self.get('/desert/tiles/t25_46.bin', method='HEAD')
        self.assertEqual((status, body, h2['Content-Length']), (200, b'', '6'))

    def test_missing_tile_and_other_paths_are_404(self):
        for path in ('/desert/tiles/t26_46.bin', '/desert/tiles/../secret.txt', '/desert/secret.txt',
                     '/desert/tiles/t25_46.bin.bak', '/desert/tiles/x.bin', '/desert/'):
            self.assertEqual(self.get(path)[0], 404, path)

    def test_path_mapping_only_reaches_the_manifest_and_tile_names(self):
        self.assertEqual(serve.desert_file('/desert/tiles/t16_42.bin', '/d'), ('/d/routes-t16_42.bin', 86400))
        self.assertEqual(serve.desert_file('/desert/manifest.json', '/d'), ('/d/manifest.json', 300))
        self.assertIsNone(serve.desert_file('/desert/tiles/t1_2_3.bin', '/d'))
        self.assertIsNone(serve.desert_file('/desert/tiles/%2e%2e.bin', '/d'))

    def test_bucket_mode_redirects(self):
        serve.DESERT_PUBLIC_BASE = 'https://bucket.example/desert'
        status, h, _ = self.get('/desert/tiles/t25_46.bin')
        self.assertEqual(status, 302)
        self.assertEqual(h['Location'], 'https://bucket.example/desert/routes-t25_46.bin')
        status, h, _ = self.get('/desert/manifest.json')
        self.assertEqual((status, h['Location']), (302, 'https://bucket.example/desert/manifest.json'))


class FakeBucket:
    """download_file like boto3: writes the object to the target path, or raises when it is absent."""
    def __init__(self, objects):
        self.objects, self.calls = objects, []

    def download_file(self, bucket, key, target):
        self.calls.append((bucket, key))
        if key not in self.objects:
            raise FileNotFoundError(key)
        with open(target, 'wb') as f:
            f.write(self.objects[key])


class DesertBucketFillTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.d = self.dir.name

    def tearDown(self):
        self.dir.cleanup()

    def test_missing_tile_is_fetched_once_then_kept(self):
        b = FakeBucket({'desert/routes-t25_46.bin': b'tile'})
        f = os.path.join(self.d, 'routes-t25_46.bin')
        self.assertTrue(serve.desert_fill(f, client=b, bucket='grids'))
        self.assertTrue(serve.desert_fill(f, client=b, bucket='grids'))
        self.assertEqual(b.calls, [('grids', 'desert/routes-t25_46.bin')])
        with open(f, 'rb') as h:
            self.assertEqual(h.read(), b'tile')
        self.assertFalse(os.path.exists(f + '.part'))

    def test_absent_object_is_not_found(self):
        b = FakeBucket({})
        self.assertFalse(serve.desert_fill(os.path.join(self.d, 'routes-t20_40.bin'), client=b, bucket='grids'))

    def test_stale_manifest_is_refetched_and_a_failure_keeps_the_old_one(self):
        f = os.path.join(self.d, 'manifest.json')
        with open(f, 'w') as h:
            h.write('old')
        t = os.path.getmtime(f)
        b = FakeBucket({'desert/manifest.json': b'new'})
        self.assertTrue(serve.desert_fill(f, client=b, bucket='grids', now=t + 10))
        self.assertEqual(b.calls, [])  # still fresh
        self.assertTrue(serve.desert_fill(f, client=b, bucket='grids', now=t + 301))
        with open(f) as h:
            self.assertEqual(h.read(), 'new')
        down = FakeBucket({})
        self.assertTrue(serve.desert_fill(f, client=down, bucket='grids', now=os.path.getmtime(f) + 400))
        with open(f) as h:
            self.assertEqual(h.read(), 'new')

    def test_no_bucket_means_disk_only(self):
        self.assertFalse(serve.desert_fill(os.path.join(self.d, 'manifest.json'), bucket=''))


if __name__ == '__main__':
    unittest.main()
