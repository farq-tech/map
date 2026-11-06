"""Fetch the Farq Atlas inputs from the Atlas project's S3-compatible bucket (read only).

Uses the same bucket variables as the Atlas service (BUCKET, ENDPOINT, REGION, ACCESS_KEY_ID, SECRET_ACCESS_KEY);
on Railway they are reference variables to the farq-targeting service, so no key is copied anywhere.

    BUILDINGS_OBJECT   the normalized building layer (the Atlas's FARQ_BUILDINGS_OBJECT)
    PLACES_OBJECT      the golden directory; when unset, the newest object named targets.parquet in the bucket

Usage: python3 fetch_atlas.py <dest-dir>   → writes places.parquet / buildings.parquet there and prints what it got.
Each file is downloaded beside its target and moved into place only when complete; a missing input is skipped,
never fatal (the roads still build).
"""
from __future__ import annotations

import os
import sys


def client():
    import boto3
    return boto3.client('s3', endpoint_url=os.environ.get('ENDPOINT') or None, region_name=os.environ.get('REGION') or None,
                        aws_access_key_id=os.environ.get('ACCESS_KEY_ID') or None,
                        aws_secret_access_key=os.environ.get('SECRET_ACCESS_KEY') or None)


def newest(c, bucket: str, name: str) -> str | None:
    """Key of the most recently modified object whose file name is `name` (e.g. releases/<id>/targets.parquet)."""
    best = None
    for page in c.get_paginator('list_objects_v2').paginate(Bucket=bucket):
        for o in page.get('Contents', []):
            if o['Key'].rsplit('/', 1)[-1] == name and o.get('Size', 0) > 0:
                if best is None or o['LastModified'] > best['LastModified']:
                    best = o
    return best['Key'] if best else None


def download(c, bucket: str, key: str, target: str) -> bool:
    partial = target + '.download'
    try:
        c.download_file(bucket, key, partial)
        os.replace(partial, target)
        return True
    except Exception as e:  # noqa: BLE001 - an input that cannot be read is skipped, the roads still build
        print(f'tiles: could not fetch {key}: {type(e).__name__}', file=sys.stderr)
        return False
    finally:
        if os.path.exists(partial):
            os.remove(partial)


def main(dest: str, c=None) -> dict:
    bucket = os.environ.get('BUCKET', '').strip()
    got = {}
    if not bucket:
        print('tiles: no Atlas bucket configured; roads only')
        return got
    c = c or client()
    wanted = {
        'places': os.environ.get('PLACES_OBJECT', '').strip() or newest(c, bucket, 'targets.parquet'),
        'buildings': os.environ.get('BUILDINGS_OBJECT', '').strip() or None,
    }
    os.makedirs(dest, exist_ok=True)
    for name, key in wanted.items():
        if not key:
            print(f'tiles: no Atlas {name} object found; building without it')
            continue
        if download(c, bucket, key, os.path.join(dest, f'{name}.parquet')):
            got[name] = key
            print(f'tiles: Atlas {name} ← {key}')
    return got


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else '/data/inputs')
