# أدوات فحص ملف OBF (Rahal export) — بحث/تجهيز بيانات فقط

ثلاثة سكربتات لقياس مدى «جِدّة» ملف `.obf` (OsmAnd) مقارنةً ببيانات OSM عندنا. **لا بيانات طرف ثالث في git**: الملف الأصلي ومخرجاته (GeoJSON، البطاقات) تبقى خارج المستودع.

| السكربت | الوظيفة |
|---|---|
| `extract_obf.py` | يقسم المملكة إلى بلاطات 0.5° ويشغّل `BinaryInspector` (MapCreator) على كل بلاطة عند zoom 16، ويحلل الإخراج كتدفق إلى `tracks.geojson.gz` و`fayad_wadi_sabkha.geojson.gz` و`manifest.json`. يملك كل كائنٌ بلاطةً واحدة (بإحداثيه الأول) فلا تكرار؛ استئناف تلقائي؛ Java واحد بـ `-Xmx3g` و`nice`. |
| `compare_osm.py` | يقارن المسارات بـ OSM (pbf عبر pyosmium): اختبار المعرّف، اتفاق الوسوم، تغطية هندسية عند 15/30 م، واختبار معاكس مع لقطة OSM القديمة. |
| `make_cards.py` | يبني بطاقات مراجعة لأداة track-annotator (`review-import-batch`) من مسارات غير موجودة في لقطتنا (≥500 م، صحراوية، ≤200 بطاقة). |

```bash
python3 extract_obf.py --obf <file.obf> --inspector-dir <MapCreator dir> --work <out dir outside git>
python3 compare_osm.py --tracks <out>/tracks.geojson.gz --water <out>/fayad_wadi_sabkha.geojson.gz \
    --osm-pbf gcc-states-latest.osm.pbf --weak-labels <saudi_osm_desert_tracks_weak_labels.geojson> --out <out>/compare
python3 make_cards.py --tracks ... --scored <out>/compare/tracks_scored.json.gz --weak-labels ... --out rahal_new_cards.json
```

الخلاصة المقيسة (ملف Saudi-arabia_asia.obf، edition 2026-11-01): الملف خريطة OSM قياسية بصيغة OsmAnd؛ 99.91% من مساراته (67,622) لها way مطابق في OSM، و99.83% من لقطتنا القديمة موجودة فيه، ولا أنواع مخصّصة في قاموس الأنواع. ما يخص «رحّال» هو أنماط العرض لا البيانات. الحقوق: `owner-declared: explicit permission`.
