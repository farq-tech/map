# Figma Make / GPT — Prompt 2: Farq Map (`/map`)

Copy **one** of the two blocks below (Arabic or English) into Figma Make or GPT.  
This is a **difference map**, not a Maps clone. Pins are real comparison coordinates. Never invent locations, logos, or meal photos.

---

## Arabic — انسخ هذا بالكامل

```text
صمّم شاشة فرق `/map` كمنتج فاخر RTL: خريطة فرق الأسعار فوق Mapbox، وليست خرائط جوجل وليست فسيفساء أحياء.

الأساس
- Mapbox Standard (خريطة) و Mapbox Standard Satellite (قمر صناعي)
- الإقلاع مرة واحدة فقط: كرة أرضية → الرياض (لا تعِد الحركة في كل إعادة تحميل)
- تضاريس ثلاثية الأبعاد + مباني 3D + ضباب/غسق (dusk)
- لا تتبع GPS حي. الكاميرا تتحرك فقط في المقدمة أو عند طلب تركيز واحد (دبوس أو «موقعي»)
- لا ارتداد للكاميرا (no snap-back) عند تحديث البيانات

طبقة البيانات
- الدبابيس من comparison.discovery_cards عبر GET /api/intelligence/map/places?layer=comparison
- إحداثيات مرصودة حياً فقط. ممنوع اختلاق lat/lng. ممنوع إعادة سكّ place_id
- الأحياء تُجلب للوحة الجانبية فقط — لا تُدهن كفسيفساء/كوروبليث
- عند الزوم < 14: تجمّعات (clusters). النقر على تجمّع = تقريب، لا يفتح قائمة
- حجم الدبوس = حجم الفرق (صغير / متوسط / كبير)
- الفائز (التطبيق الأرخص) كبير على الدبوس عبر getProviderLogo
- التطبيقات الأخرى شرائح صغيرة تحت الفائز من معرفات حقيقية فقط (الأغلى + العدد)
- إذا ما فيه cheapest_provider_id: الحرف الأول من اسم المطعم — ممنوع حرف «ف» كمعنى «الأسعار متساوية»

شريط علوي عائم (زجاج أبيض، ظل ناعم)
- علامة فرق: مربع brand-900 فيه «ف» mint + كلمة فَرْق على سطح المكتب
- مدينة (كل المدن الجاهزة من ncp_ready_cities)
- بحث: «ابحث عن مطعم أو مقهى…»
- فئة من category_groups
- مفتاح «فروقات كبرى فقط» / «فروقات كبرى» (يُخفي الدبابيس بلا فرق مرصود)
- تبديل الأسلوب: قمر صناعي | خريطة (brand-900 + mint للحالة النشطة)
- زر «موقعي»: GPS حقيقي أو موقع يدوي من نافذة الخريطة. ممنوع موقع وهمي. إذا ما فيه صلاحية افتح ملتقط الموقع. نقطة المستخدم نبضة فقط بعد GPS/يدوي حقيقي
- صندوق بحث Mapbox (أعلى يمين الخريطة) اختياري إذا التوكن يدعم Search

دليل الطبقة (بطاقة بيضاء أسفل الخريطة، تُخفى على الجوال عند فتح اللوحة)
- فائز: التطبيق الأرخص بفرق ملحوظ
- نقطة: مطعم فردي بدون فارق كبير
- تجمّع: تجمعات مطاعم (قم بالتقريب للرؤية)
- اقتباس أمانة: «دبابيس من طبقة المقارنة المباشرة. الإحداثيات مرصودة حياً. لا نختلق مواقع.»
- «حجم الدبوس = حجم الفرق»

لحظة المنتج عند نقر دبوس المقارنة — ليست infowindow خرائط جوجل
الجوال: لوحة/شيت تدخل من الأسفل (حافة علوية 28px، مقبض سحب، خلفية brand-900/25 تُغلق بالنقر)
سطح المكتب: لوحة جانبية 27rem تدخل من الجانب (من اليسار في RTL)
التسلسل البصري (إلزامي):
1) الفرق ضخماً: عدد يعدّ تصاعدياً (count-up) mint على brand-900 — «ر.س فرق» / Observed فرق
2) الوجبة: اسم المنتج المقارن (product_name). صورة فقط إذا الـ API رجّع image_url حقيقي (http/https أو مسار محلي). ممنوع اختراع روابط صور أو صور مخزون
3) التطبيقات: الأرخص مقابل الأغلى بشعارات getProviderLogo + شريط التوفير (mint رخيص / أحمر غالي)
4) اسم المطعم + المدينة + شارة الفئة
5) نضارة السعر من observed_at:
   اليوم: نقطة mint + «الأسعار محدثة آلياً قبل X دقيقة»
   هذا الأسبوع: برتقالي
   أقدم: رمادي
6) CTA أساسي «شف الفرق» → /merchant/restaurant/:id (نفس بطاقة الصفحة الرئيسية). لا يقفز النقر على الدبوس مباشرة للقائمة
إذا ما فيه فرق مرصود: بطاقة «ما رصدنا فرقاً بعد» — لا تخترع رقماً
إذا ما فيه image_url: لا تضع غلاف صورة فارغ مزيف؛ ابدأ بالفرق

لوحة الحي (سطح المكتب، إذا ما فيه دبوس محدد)
- تفاصيل الحي أو «تفاصيل الفرق»
- إذا promote_in_consumer_ui=false: تحذير «بيانات غير كافية — لا يمكن تحديد الفائز»
- إذا promote: درجة + شعار الفائز + منصة 1/2/3
- CTA احتياطي يفتح مقارنة فرق أو /grocery للفئات البقالة/التسوق — بدون سكّ place_id

حالات أخرى
- خطأ: «ما قدرنا نحمّل الخريطة حياً» + إعادة المحاولة
- تحميل: نحمّل الخريطة…
- توكن Mapbox ناقص: رسالة إعداد VITE_MAPBOX_ACCESS_TOKEN (للمستثمر/المهندس، ليست للمستهلك النهائي)

ملاحظات CORS / API عام للمستثمر
- الواجهة العامة للمقارنة والذكاء تُقرأ عبر /api/intelligence/map/places و /api/intelligence/map/places/:id و /api/intelligence/meta
- المتصفح يحتاج CORS_ORIGINS يشمل أصل الواجهة (farq.sa / localhost:5173). لا تصمم «خريطة تعمل بلا خلفية»
- لا تضع أسرار أو توكنات Mapbox داخل التصميم
- الإحداثيات والصور والفروقات تُعرض فقط إذا رجعت من الـ API

ما لا تصممه
- فسيفساء أحياء ملونة
- إحداثيات مزيفة أو دبابيس تجميلية
- نسخة خرائط جوجل (infowindow، اتجاهات، Street View، بحث أماكن عام كمنتج)
- اختراع شعارات تطبيقات أو صور وجبات
- حرف «ف» على الدبوس بمعنى تساوي الأسعار
- إعادة سكّ place_id
- الانتقال فوراً للقائمة عند النقر — اللوحة أولاً، ثم «شف الفرق»
```

---

## English — copy this entire block

```text
Design **Farq `/map`** as a premium RTL product: a **price-difference map** on Mapbox — not Google Maps, not a neighborhood mosaic.

Basemap
- Mapbox Standard (“Map”) and Mapbox Standard Satellite
- Intro once: globe → Riyadh (do not replay on every remount)
- 3D terrain + 3D buildings + dusk fog
- Camera does **not** follow live GPS. It moves only on the intro or a one-shot focus (selected pin or “My location”)
- **No snap-back** when pins refetch

Data layer
- Pins from `comparison.discovery_cards` via `GET /api/intelligence/map/places?layer=comparison`
- Observed lat/lng only. Never invent coordinates. Never remint `place_id`
- Neighborhood polygons are fetched for the **side panel only** — never painted as a choropleth mosaic
- Zoom < 14: clusters. Cluster tap = zoom in, does not open a menu
- Pin size = gap size (sm / md / lg)
- Winner (cheapest app) is **large** on the pin via `getProviderLogo`
- Other apps are small chips under the winner from **real ids only** (expensive + honest +N)
- If no `cheapest_provider_id`: restaurant-name initial — never a «ف» mark meaning “equal prices”

Floating overlay bar (white, soft shadow)
- Farq mark: brand-900 square with mint «ف» + wordmark فَرْق on desktop
- City (all ncp_ready_cities)
- Search: “Search a restaurant or café…”
- Category from `category_groups`
- “Big gaps only” switch (hides pins with no observed gap)
- Style toggle: Satellite | Map (active = brand-900 + mint)
- “My location”: real GPS or a user-picked manual point — never a fake location. If unset, open the location picker. User pulse only after real GPS/manual
- Optional Mapbox Search Box (top-right) if the token has Search scope

Legend (white card, bottom-start; hide on mobile while the sheet is open)
- Win: cheapest app with a noticeable gap
- Dot: individual restaurant without a large gap
- Cluster: restaurant clusters (zoom in to see)
- Honesty quote: “Pins from the live comparison layer. Coordinates are observed. We never invent locations.”
- “Pin size = gap size”

**Selected-place product moment** — NOT a Google Maps infowindow
Mobile: sheet enters from the **bottom** (28px top radius, drag handle, brand-900/25 backdrop dismisses)
Desktop: **side panel** ~27rem, enters from the inline end (from the left in RTL)
Visual hierarchy (required):
1) **Gap huge** — mint count-up on brand-900 (“SAR gap” / «ر.س فرق»)
2) **Meal** — compared `product_name`. Photo **only** if the API returned a real `image_url` (`http(s)` or site path). Never invent image URLs or stock food photos
3) **Apps** — cheapest vs expensive with `getProviderLogo` + savings bar (mint cheap / red expensive)
4) Restaurant name + city + category chip
5) Freshness from `observed_at`:
   today → mint dot + “Prices updated X min ago”
   this week → orange
   older → gray
6) Primary CTA **«شف الفرق»** → `/merchant/restaurant/:id` (same as a home card). Pin click does **not** jump straight to the menu
If no observed gap: caution “No observed price gap for this place yet.” — do not invent a number
If no `image_url`: do not paint a fake photo cover; start with the gap

Neighborhood panel (desktop, when no pin is selected)
- “Neighborhood detail” or “Farq difference”
- If `promote_in_consumer_ui=false`: caution “Insufficient data — no champion”
- If promote: score + winner logo + podium 1/2/3
- Fallback CTA opens live Farq compare or `/grocery` for grocery/shopping — no new `place_id`

Other states
- Error: “We couldn't load the live map” + retry
- Loading: “Loading map…”
- Missing Mapbox token: setup note for `VITE_MAPBOX_ACCESS_TOKEN` (investor/engineer, not a consumer empty state)

CORS / public API notes for an investor
- Public reads: `/api/intelligence/map/places`, `/api/intelligence/map/places/:id`, `/api/intelligence/meta`
- Browser needs `CORS_ORIGINS` to include the web origin (`https://farq.sa`, `http://localhost:5173`). Do not design a map that “works without a backend”
- Do not put Mapbox secrets in the design file
- Coordinates, photos, and gaps render only when the API returns them

Do NOT design
- Colored neighborhood mosaic
- Fake coordinates or decorative pins
- A Google Maps clone (infowindow, turn-by-turn, Street View, generic places search as the product)
- Invented app logos or meal photos
- A «ف» pin meaning equal prices
- Reminted `place_id`
- Instant navigation to the menu on pin tap — sheet first, then «شف الفرق»
```
