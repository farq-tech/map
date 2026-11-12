"""CLI: serve | fetch | import | batch | export | check"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from . import collect, config, export as export_mod, quality, store, tiles
from .geo import lonlat_to_tile


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="annotator", description="أداة وسم دروب الصحراء — سَرى البارق")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve", help="تشغيل الواجهة")
    s.add_argument("--host", default="127.0.0.1")
    s.add_argument("--port", type=int, default=8791)
    f = sub.add_parser("fetch", help="جلب نافذة صور Mapbox z17@2x إلى عينة")
    f.add_argument("--lat", type=float, required=True)
    f.add_argument("--lon", type=float, required=True)
    f.add_argument("--tiles", type=int, default=3, help="عدد البلاطات في كل اتجاه (افتراضي 3 = 1536 بكسل)")
    f.add_argument("--fixture", action="store_true", help="عينة اختبار برمجية لا تُحتسب كبيانات المالك")
    i = sub.add_parser("import", help="استيراد GeoTIFF")
    i.add_argument("path")
    i.add_argument("--crop", help="lon0,lat0,lon1,lat1 لقص الصورة")
    b = sub.add_parser("batch", help="طلب الدفعة الحالي (أو إنشاء واحد)")
    b.add_argument("--status", action="store_true", help="حالة الأنواع فقط")
    e = sub.add_parser("export", help="تصدير بصيغة SAM-Road مع تقسيم مكاني وتقرير جودة")
    e.add_argument("--gsd", type=float, default=1.0)
    e.add_argument("--tile", type=int, default=400)
    e.add_argument("--include-fixtures", action="store_true")
    e.add_argument("--keep-empty", action="store_true")
    e.add_argument("--seed", type=int, default=0)
    e.add_argument("--block-km", type=float, default=5.0)
    e.add_argument("--buffer-m", type=float, default=500.0)
    e.add_argument("--label")
    c = sub.add_parser("check", help="جودة عينة واحدة")
    c.add_argument("sample_id")
    a = ap.parse_args(argv)
    config.ensure_dirs()

    if a.cmd == "serve":
        import uvicorn
        print(f"الواجهة: http://{a.host}:{a.port}")
        uvicorn.run("annotator.api:app", host=a.host, port=a.port, log_level="warning")
    elif a.cmd == "fetch":
        fx, fy = lonlat_to_tile(a.lon, a.lat, config.NATIVE_ZOOM)
        x0, y0 = int(round(fx - a.tiles / 2)), int(round(fy - a.tiles / 2))
        print(f"طلبات جديدة متوقعة: {tiles.count_missing(config.NATIVE_ZOOM, x0, y0, a.tiles, a.tiles)}")
        meta, existed = store.create_from_mosaic(config.NATIVE_ZOOM, x0, y0, a.tiles, a.tiles, fixture=a.fixture)
        print(("موجودة مسبقًا: " if existed else "أُنشئت: ") + meta["sample_id"])
    elif a.cmd == "import":
        cr = tuple(float(v) for v in a.crop.split(",")) if a.crop else None
        meta, existed = store.create_from_geotiff(Path(a.path), crop_lonlat=cr)
        print(("موجودة مسبقًا: " if existed else "أُنشئت: ") + meta["sample_id"])
    elif a.cmd == "batch":
        if a.status:
            print(json.dumps(collect.summarize(collect.analyse()), ensure_ascii=False, indent=1))
        else:
            b = collect.current_batch()
            print(collect.batch_markdown(b) if "windows" in b else json.dumps(b, ensure_ascii=False, indent=1))
    elif a.cmd == "export":
        root = export_mod.run_export(gsd=a.gsd, tile=a.tile, include_fixtures=a.include_fixtures, keep_empty=a.keep_empty,
                                     seed=a.seed, block_km=a.block_km, buffer_m=a.buffer_m, label=a.label)
        print(f"التصدير: {root}")
        print((root / "quality_report.md").read_text())
    elif a.cmd == "check":
        print(json.dumps(quality.check_sample(a.sample_id), ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
