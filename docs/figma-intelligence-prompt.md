# Figma Make / GPT — Prompt 1: Farq Intelligence («الذكاء» / من الأقوى؟)

Copy **one** of the two blocks below (Arabic or English) into Figma Make or GPT.  
Do not invent screens, metrics, trends, or logos that this prompt does not list.  
Data source is only `GET /api/intelligence/*`. Scoring is server-side (`category_provider_score_v1_1`). Never remint `place_id`. Never invent lat/lon, demand, or market share.

---

## Arabic — انسخ هذا بالكامل

```text
صمّم شاشة منتج فرق «الذكاء» (من الأقوى؟) كمنتج عربي RTL فاخر — brand-900 (#043434) + mint-500. ليست خريطة مطاعم وليست نسخة من خرائط جوجل. هي عدسة حي × فئة × مزود على نواة فرق.

المسار: /intelligence
علم الميزة: intelligence_ui
- في Vite DEV يعمل تلقائياً
- في الإنتاج يحتاج VITE_FEATURE_FLAGS=intelligence_ui
- إيقاف: localStorage.farq_flag_intelligence_ui = "0"
- تشغيل: localStorage.farq_flag_intelligence_ui = "1"
شريط الاكتشاف (سطح المكتب فقط، يظهر فقط إذا العلم شغّال): الرئيسية · الذكاء · الخريطة · قارن
قارن يفتح مقارنة فرق الحقيقية (الصفحة الرئيسية) وليس شبكة وهمية.

البيانات فقط من:
GET /api/intelligence/health
GET /api/intelligence/meta
GET /api/intelligence/categories
GET /api/intelligence/neighborhoods/:neighborhoodId/categories/:categoryId
GET /api/intelligence/neighborhood-category?category=&city=&provider=&min_confidence=
GET /api/intelligence/providers/:providerId/lens
GET /api/intelligence/opportunities
GET /api/intelligence/alerts
إيقاف الـ API: FARQ_INTELLIGENCE_API_ENABLED=0
لا تحسب النقاط في الواجهة. لا تختلق اتجاهات أسبوعية إذا الـ API ما رجّع تقلّبات.

1) شريط التنبيهات / قائمة المتابعة (أعلى الصفحة، خلفية كهرمانية فاتحة)
- عنوان: قائمة المتابعة (أو watchlist_headline_ar من الـ API)
- إذا ux_mode=watchlist_only أو single_snapshot: نص صريح «لقطة واحدة فقط إلى الآن — نعرض قائمة المتابعة، ومو تقلّب أسبوعي.»
- لا تصمم رسم بياني للترند إذا ما فيه أسابيع كافية
- شرائح أفقية قابلة للتمرير من alerts.items (حتى 12) بنص message_ar / label
- فجوة صادقة: إذا الـ API ما رجّع winner_changes فلا تخترع «من فاز هذا الأسبوع»

2) بطل الهيرو (تدرج brand-700 → brand-900)
- عنوان ضخم: من الأقوى في حيّك؟
- وصف: اكتشف أفضل تطبيق توصيل لكل فئة في حيّك — بالأرقام والثقة. وين أكبر فرق؟
- بحث حي مع أيقونة بحث + datalist (الياسمين، الملقا…) + شارة «الحي المختار»
- قائمة مدينة: الكل (الجاهز) + المدن الجاهزة + بذور الزحف موسومة «غير جاهزة بعد»
- لا تعرض إحداثيات بذور الزحف. أسماء مدن فقط.

3) شريط التصنيفات (كل كتالوج N×C×P، مو برغر/بيتزا فقط)
- عنوان: الفئات المتاحة للتحليل / اختر الفئة
- مجموعات قطاع → فئة من category_groups:
  طعام / بقالة / خدمات (أو ما يرجع الـ API)
- كل مجموعة: اسم القطاع + عدد الفئات + شرائح Chip بلون mint
- الشريحة المحددة = الفئة الحالية في الـ URL (?category=)
- تحتها: عدسة المزود — قائمة providers من الـ meta + شعار المزود عبر getProviderLogo / ProviderLogoMark (أصول فرق المحلية فقط، لا تختلق روابط CDN)

4) فلتر الثقة العالية (high-only) كما هو محدد في المنتج
- في شاشة الذكاء: البطل يظهر فقط إذا promote_in_consumer_ui=true (ثقة ≥ MEDIUM)
- شارة «ثقة عالية» تظهر فقط إذا winner.confidence === HIGH
- لا يوجد توغل بطل وهمي عند LOW / INSUFFICIENT_DATA
- واجهة الـ API تدعم min_confidence على /neighborhood-category
- على الخريطة يوجد مفتاح منفصل «فروقات كبرى فقط» — لا تخلطه مع فلتر الثقة هنا
- إذا البيانات غير كافية: بطاقة تحذير، بدون منصة ذهبية

5) تخطيط منقسم (سطح المكتب عمودان، الجوال عمود واحد)
العمود الرئيسي:
أ. بطاقة السؤال الواحد
   - شارة «السؤال»
   - question_ar من الـ API مثل: وين أكبر فرق، ومن الأقوى في [الفئة] بحي [الحي]؟
   - إذا winner موجود و promote_in_consumer_ui=false:
     بطاقة تحذير (أيقونة مثلث) «تحذير بيانات»
     نص المستهلك من الـ API أو: بيانات غير كافية - لا يمكن تحديد الفائز
     جملة أمانة: ما نعرض بطل وهمي عند الثقة المنخفضة.
   - إذا promote_in_consumer_ui=true:
     شعار المزود الفائز + الاسم العربي + consumer_message_ar + الدرجة الإجمالية كبيرة
   - إذا لا تفاصيل: «استخدم شرائح التصنيف وبحث الحي أعلاه.»

ب. رسائل المستهلك الثابتة (استخدمها كما هي، لا تعيد صياغتها):
   INSUFFICIENT_DATA → ما عندنا بيانات كافية نحدد الأقوى هنا بعد
   LOW               → تقدير أولي — البيانات محدودة
   MEDIUM            → بناءً على بيانات فرق المتاحة
   HIGH              → بناءً على عينة قوية في هذا الحي

ج. نواة فرق (intelligence-farq-signal) — «وين أكبر فرق؟»
   - رسالة signal.message_ar
   - الأرخص المعروف + شعار المزود إذا available
   - إذا winner_is_cheapest: «وهو الأقوى أيضاً»
   - عيّنات بقالة أسبوعية (grocery_week_samples) فقط إذا رجعت من الـ API:
     اسم المنتج + شعار الأرخص + مبلغ الفرق. حبة المدينة-الأسبوع، ليست فائز حي.
   - CTA مطعم → /?category=&q=&vertical=restaurant
   - CTA بقالة → /grocery
   - نصوص CTA من الـ API: قارن الأسعار في فرق / قارن أسعار البقالة في فرق
   - حاشية: نفس مقارنة فرق — بدون سكّ place_id.

د. المنصة (Podium) — فقط إذا promote_in_consumer_ui و winner.podium موجود
   - عنوان: تصنيف القوة في الحي
   - ثلاثة أعمدة: ٢ / ١ / ٣ (RTL: الثاني، البطل الحالي، الثالث)
   - العمود الأوسط (الأول) أطول وبلون brand-900
   - شعار + اسم عربي + درجة لكل مرتبة
   - إذا ما فيه منصة في الـ API: لا ترسم درجات فارغة مزيفة

هـ. شرائح الأبعاد (تغطية / سعر / تنوع / توفر / توصيل) من dimension_chips
   - كل شريحة: label_ar + شعار المزود إن وُجد
   - لا تخترع أبعاد غير موجودة في الـ payload

و. لماذا تفوق الفائز؟ (أكورديون evidence_bullets)
   - يظهر فقط مع promote
   - شارة mint «ثقة عالية» فقط عند HIGH
   - نقاط الدليل من الـ API كما هي

العمود الجانبي:
ز. مجهر التطبيقات (عدسة المزود)
   - إذا لم يُختر مزود: «اختر مزوداً لعرض الفوز / المركز الثاني / الضعف»
   - تبويبات: يفوز / #٢ / ضعيف / فجوات مع أعداد من lens.counts
   - قائمة أحياء×فئات قابلة للنقر (تحدّث البحث)
   - تبويب فارغ: «لا عناصر في هذا التبويب.»

ح. فجوات التغطية (B2B)
   - شارة حمراء: فجوة تغطية
   - عنوان: فجوات التغطية المرصودة
   - تنويه إلزامي: فجوة تغطية — ليست طلب سوق. ممنوع «حصة سوق».
   - بطاقات من opportunities.results (headline_ar + body_ar)
   - فارغ: «لا فرص مطابقة للفلتر الحالي.»

6) مدينة غير جاهزة
- حالة فارغة: ما عندنا تغطية كافية في [المدينة] بعد
- الجسم: نحتاج إحداثيات المزودين الحقيقية قبل ما نحدد الأقوى في الأحياء. فرق ما تختلق خطوط طول وعرض.
- قائمة crawl_seeds بأسماء المدن + note_ar فقط

7) خطأ / إعادة المحاولة
- عنوان: ما قدرنا نحمّل «من الأقوى؟»
- زر إعادة المحاولة
- تحميل: نحمّل ذكاء الحي…

8) تذييل أمانة
- score: category_provider_score_v1_1
- مصدر CSV مسبق الحساب · يخدم نواة فرق · لا يعيد سكّ place_id

ما لا تصممه:
- فسيفساء أحياء / كوروبليث
- بطل وهمي عند بيانات غير كافية
- ترندات أسبوعية إذا الـ API في وضع watchlist_only
- إحداثيات مختلقة لجدة أو غيرها
- شعارات تطبيقات مخترعة أو روابط CDN
- خريطة مطاعم داخل شاشة الذكاء (الخريطة مسار /map منفصل)
- إعادة سكّ place_id أو «ف» كمعادلة أسعار
```

---

## English — copy this entire block

```text
Design Farq Intelligence («الذكاء» / Who’s strongest?) as a premium Arabic-first RTL product screen. Brand: brand-900 (#043434) + mint-500. This is NOT a restaurant map and NOT a Google Maps clone. It is a Neighborhood × Category × Provider lens on the Farq nucleus.

Route: /intelligence
Feature flag: intelligence_ui
- On automatically in Vite DEV
- Production needs VITE_FEATURE_FLAGS=intelligence_ui
- Kill switch: localStorage.farq_flag_intelligence_ui = "0"
- Enable: localStorage.farq_flag_intelligence_ui = "1"
Discovery chrome (desktop only, only when the flag is on): Home · Intelligence · Map · Compare
Compare opens live Farq compare (home), not a placeholder grid.

Data ONLY from:
GET /api/intelligence/health
GET /api/intelligence/meta
GET /api/intelligence/categories
GET /api/intelligence/neighborhoods/:neighborhoodId/categories/:categoryId
GET /api/intelligence/neighborhood-category?category=&city=&provider=&min_confidence=
GET /api/intelligence/providers/:providerId/lens
GET /api/intelligence/opportunities
GET /api/intelligence/alerts
Disable API with FARQ_INTELLIGENCE_API_ENABLED=0
Do not score in the UI. Do not invent week-over-week trends if the API did not return flips.

1) Alerts / watchlist strip (top, amber)
- Headline: Watchlist (or API watchlist_headline_ar)
- If ux_mode=watchlist_only or single_snapshot: explicit copy “Only one snapshot week so far — watchlist, not week-over-week flips.”
- HONEST GAP: if the API has no winner_changes, do not draw a fake trend chart
- Horizontal chips from alerts.items (up to 12)

2) Hero (brand-700 → brand-900 gradient)
- H1: Who’s strongest in your neighborhood?
- Sub: See the strongest delivery app per category nearby — with numbers and confidence. Where’s the biggest difference?
- Neighborhood search + datalist + “Selected” badge
- City select: All (ready) + ncp_ready_cities + crawl seeds labeled “not ready yet”
- Crawl seeds are city NAMES only — never show seed lat/lon

3) Full N×C×P category strip (not a hardcoded burgers/pizza set)
- “Categories available” / “Pick a category”
- Sector → category groups from meta.category_groups (Food / Grocery / Services or whatever the API returns)
- Mint chips; selected chip = ?category=
- Provider lens select under the chips; logos via getProviderLogo / ProviderLogoMark (Farq-owned local assets only — never invent CDN URLs)

4) High-only / confidence gate (as specified)
- Champion UI only when promote_in_consumer_ui=true (confidence ≥ MEDIUM)
- “High confidence” mint badge only when winner.confidence === HIGH
- Never crown a fake champion on LOW / INSUFFICIENT_DATA
- API supports min_confidence on /neighborhood-category
- The map’s “Big gaps only” toggle is a different control — do not merge it into this screen
- Insufficient data → caution card, no gold podium

5) Split view (two columns on desktop, one on mobile)

Main column:
A. One-question hero card
   - Label “The question”
   - question_ar from API, e.g. “وين أكبر فرق، ومن الأقوى في [category] بحي [hood]؟”
   - If winner && !promote_in_consumer_ui: caution card “Data caution” + consumer_message_ar + “We never show a fake champion on low confidence.”
   - If promote: winner logo + Arabic name + consumer_message_ar + large overall score
   - Else: “Use the category chips and neighborhood search above.”

B. Consumer messages (use verbatim):
   INSUFFICIENT_DATA → ما عندنا بيانات كافية نحدد الأقوى هنا بعد
   LOW               → تقدير أولي — البيانات محدودة
   MEDIUM            → بناءً على بيانات فرق المتاحة
   HIGH              → بناءً على عينة قوية في هذا الحي

C. Farq nucleus card (“Where’s the biggest difference?”)
   - signal.message_ar
   - Known cheapest + logo if available; “also the coverage winner” if winner_is_cheapest
   - Grocery week samples ONLY if API returns grocery_week_samples (city-week grain — not a neighborhood winner)
   - Restaurant CTA → /?category=&q=&vertical=restaurant
   - Grocery CTA → /grocery
   - API CTA copy: قارن الأسعار في فرق / قارن أسعار البقالة في فرق
   - Footer: Same Farq compare — no new place_id

D. Podium ONLY if promote_in_consumer_ui && winner.podium
   - Title: Neighborhood strength podium
   - Columns 2 / 1 / 3; center (#1) tallest, brand-900
   - Logo + Arabic name + score
   - If podium missing: omit — do not invent ranks

E. Dimension chips from dimension_chips (coverage / price / selection / availability / delivery)
   - label_ar + provider mark if present
   - Do not invent extra dimensions

F. Why accordion (evidence_bullets) only when promoted
   - High-confidence mint badge only on HIGH

Side column:
G. Provider microscope
   - Empty: “Pick a provider to see wins, #2, weak spots, and coverage gaps.”
   - Tabs: Wins / #2 / Weak / Gaps with lens.counts
   - Clickable neighborhood×category rows
   - Empty tab: “Nothing in this tab.”

H. Coverage-gap opportunity cards (B2B)
   - Badge: Coverage gap
   - Disclaimer required: Coverage gap — not market demand. Never “market share”.
   - Cards from opportunities.results
   - Empty: “No matching coverage-gap cards for this filter.”

6) City not ready
- Empty: Not enough coverage in this city yet
- Body: We need real provider coordinates before we can name a neighborhood winner. Farq does not invent lat/lon.
- List crawl seeds by city name + note_ar only

7) Error / retry / loading
- “ما قدرنا نحمّل «من الأقوى؟»” + Try again
- Loading: Loading neighborhood intelligence…

8) Honesty footer
- score: category_provider_score_v1_1
- Precomputed CSV · serves Farq nucleus · no place_id reminting

Do NOT design:
- Neighborhood mosaic / choropleth
- Fake champion on insufficient data
- Trend charts when API is watchlist_only (honest gap: no multi-week flips)
- Invented Jeddah (or other) coordinates
- Invented app logos or CDN URLs
- A restaurant map inside Intelligence (that is /map)
- Reminted place_id or a fake «ف» mark meaning “equal prices”
```
