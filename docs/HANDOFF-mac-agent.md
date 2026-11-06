# تسليم لوكيل الماك: البحث، خريطة فرق، والملاحة (PR #111)

> اقرأ `CLAUDE.md` في جذر المستودع أولًا: الكلام مع المالك بالعربية، وبيانات فرق ملك لنا (عدا Google)، ولا أرقام جوال أو بريد في الخرائط والبحث.

- **الفرع:** `claude/eager-lovelace-suifzq` (PR: https://github.com/farq-tech/map/pull/111، مسودة)
- **التطبيق المعني:** سَرى البارق (`apps/ios/SaryAlbarq`)، وليس FarqNavigate.
- **الحالة:** كل الكود مكتوب ومرفوع. كود الخادم مختبر ومنشور. **كود Swift لم يُبنَ ولم يُختبر قط**، فقد كُتب في بيئة Linux بلا Xcode. هذه أول مهمة لك.

---

## 1. ما الذي تغيّر (باختصار)

| # | التغيير | الملفات |
|---|---|---|
| 1 | **البحث عن أي مكان في السعودية.** البحث كان Mapbox Geocoding فقط، وهو بلا محلات، فلا يجد «ماكدونالدز» ولا «شاليهات». صار يسأل ثلاثة مصادر معًا: Apple Maps (`MKLocalSearch`) حولك، وApple على مستوى المملكة، وMapbox للأحياء والعناوين. النتائج تُدمج ويُحذف المكرر، ثم تُرتَّب: الاسم المطابق أولًا، ثم القريب ضمن 50 كم بالأقرب، ثم بقية المملكة، ثم خارجها. | `Sources/Plan/PlaceSearch.swift`، `Sources/Plan/PointCard.swift`، `Sources/Create/CreateOutingWizard.swift` |
| 2 | **«ملاحة إلى هنا» تحمل اسم المكان.** صارت `navigateHere: (LngLat, String?)`، و`navLongPressed(_:name:)`. | `PointCard.swift`، `LivePlan.swift`، `LiveOutingController+Nav.swift` |
| 3 | **خريطة فرق فوق صورة القمر الصناعي.** `FarqTiles` يقرأ TileJSON من الخادم عند الإقلاع. **فقط إذا ردّ الخادم:** تُخفى شوارع Mapbox وأسماؤها (`showRoadsAndTransit=false`، `showRoadLabels=false`) وتُرسم شوارعنا، والتصاق السيارة بالطريق يتبع شوارعنا، ومباني المدن ثلاثية الأبعاد من الأطلس، وأماكن الأطلس قابلة للضغط. **إذا لم يرد:** الخريطة كما كانت تمامًا. | `Sources/Map/FarqTiles.swift` (جديد، ومضاف يدويًا إلى `project.pbxproj`)، `OutingMapboxView.swift`، `Visuals/CityBuildings.swift`، `Visuals/MapVisualsDirector.swift`، `SaryAlbarqApp.swift`، `Info.plist` (`FarqTilesURL`)، `Config/Base.xcconfig` (`FARQ_TILES_URL`) |
| 4 | **ملاحة فرق (Valhalla) هي الافتراضية.** القيمة الافتراضية لـ `NavProviderChoice` صارت `.auto` بعد أن كانت `.mapbox`. `.auto` يستخدم فرق متى قال الخادم `enabled`، وMapbox احتياطًا. | `FarqValhallaRouteProvider.swift`، `SettingsScreens.swift` |
| 5 | **الاختبارات.** `PlaceSearchTests` موسّع، و`FarqTilesTests` جديد (داخل `MapVisualsTests.swift` لتجنّب تعديل المشروع)، و`testDefaultChoiceIsAuto`. | `Tests/PlanTests.swift`، `Tests/MapVisualsTests.swift`، `Tests/NavigationTests.swift` |

---

## 2. مهامك بالترتيب

### المهمة 1: البناء

```sh
cd apps/ios/SaryAlbarq
xcodebuild -project SaryAlbarq.xcodeproj -scheme SaryAlbarq \
  -destination 'generic/platform=iOS Simulator' build-for-testing 2>&1 | xcbeautify
```

**هذه المواضع لم يرها مترجم Swift قط. افحصها أولًا إن فشل البناء:**

1. **`FarqTiles.swift`:**
   - `await MainActor.run { status = s; NotificationCenter... }`: إسناد `private(set) static var` من داخل closure.
   - `setStatusForTests` تحت `#if DEBUG`.
2. **`OutingMapboxView.swift`:**
   - `TapInteraction(.layer(FarqTiles.placeCircleId)) { place, ctx in ... }`، وقراءة الخصائص `if case let .string(v)?? = place.properties[k]`. Mapbox مثبّت على 11.27.3، فراجع توقيع `FeaturesetFeature.properties` فيه.
   - المتغيرات الجديدة `farqApplied` و`farqObserver` و`farqPlaceTap`، والدالة `applyFarqIfReady()`. تُستدعى من `updateUIView` ومن إشعار `FarqTiles.didBecomeAvailable`.
3. **`PlaceSearch.swift`:**
   - `async let` مع دوال `apple()` و`attempt()` الخاصة.
   - `catch let e as MKError where e.code == ...`.
   - `MKMapItem.placemark`: مُهمَل (deprecated) في iOS 26، لكن الحد الأدنى للنشر iOS 17، فالمتوقع ألا يظهر تحذير.
4. **`CityBuildings.swift`:** قيمة `"filter"` عبارة ثلاثية (`atlas ? [...] as [Any] : [...] as [Any]`) داخل قاموس `[String: Any]`.
5. **`Tests/MapVisualsTests.swift` (`FarqTilesTests`):** دالة `check` تُستدعى مع closure لاحقة (trailing closure) لمعامل `fetch`.

**إذا فشل البناء:** أصلح بأصغر تغيير ممكن، واحفظ السلوك الموصوف في الجدول أعلاه.

### المهمة 2: الاختبارات

```sh
xcodebuild -project SaryAlbarq.xcodeproj -scheme SaryAlbarq \
  -destination 'platform=iOS Simulator,name=iPhone 17' test \
  -only-testing:SaryAlbarqTests/PlaceSearchTests \
  -only-testing:SaryAlbarqTests/FarqTilesTests \
  -only-testing:SaryAlbarqTests/MapVisualsTests \
  -only-testing:SaryAlbarqTests/NavRoutingProviderTests
```

- بعد ذلك شغّل الحزمة كاملة وحدات وواجهة: `xcodebuild ... test`.
- **لا تعطّل اختبارًا لتنجح الحزمة.** هذه قاعدة.

### المهمة 3: تحقق يدوي في المحاكي (مع لقطات شاشة)

**التشغيل:**
- `-demo` يفتح طلعة تجريبية قرب الرياض.
- الموقع الوهمي: `xcrun simctl location booted set 24.7136,46.6753`.

**ما تتحقق منه:**

1. **البحث** («ابحث أو أدخل إحداثية» في الخريطة الحية، و«وين رايحين؟» عند إنشاء طلعة):
   - «ماكدونالدز»: فروع بأيقونة مطعم وبعد بالكيلومتر، والأقرب أولًا.
   - «شاليهات»، و«محطة بنزين»، و«العليا»، و«العلا»: نتائج منطقية.
   - قطع الإنترنت: رسالة «لا يوجد اتصال…» ولا يحدث انهيار.
2. **خريطة فرق:**
   - **مع الإنترنت:** على طبقة «قمر صناعي» يجب أن تظهر شوارعنا: ألوان فاتحة، وطرق البر خطوط متقطعة بلون رملي. شوارع Mapbox الأصلية مخفية.
     - موضع للمقارنة: تقاطع طريق الملك عبدالعزيز مع طريق الأمير محمد بن سلمان (24.7873، 46.6629). الشكل المتوقع في `docs/screenshots/farq-tiles-kaa-mbs-z15.png`.
   - **وضع القيادة:** تظهر أسماء الشوارع بالعربية.
   - **أماكن الأطلس:** نقاط زرقاء تظهر من zoom 15، والضغط على نقطة يفتح بطاقتها باسمها.
   - **المباني:** إمالة الكاميرا فوق مدينة تُظهر مباني ثلاثية الأبعاد. إذا كان الأرشيف يحوي طبقة `buildings` فمصدرها الأطلس، وإلا فمصدرها Mapbox.
   - **سقوط الخادم:** غيّر `FARQ_TILES_URL` إلى رابط خاطئ. يجب أن تعود الخريطة كما كانت بشوارع Mapbox.
3. **الملاحة:** من نتيجة بحث، اضغط «ملاحة إلى هنا». يجب أن يحمل التوجيه اسم المكان، وفي إعدادات الملاحة يظهر المزوّد «تلقائي».

### المهمة 4: الدفع

- ادفع الإصلاحات إلى الفرع نفسه، `claude/eager-lovelace-suifzq`.
- حدّث وصف PR #111 بنتيجة البناء والاختبارات، وأرفق لقطات الشاشة.

---

## 3. الخادم (منشور ويعمل، للعلم)

- **الخدمة:** `farq-map-tiles` على Railway، في مشروع `farq-targeting`، بيئة production. تُبنى من `apps/tiles` على فرع الـ PR.
- **الرابط:** https://farq-map-tiles-production.up.railway.app/farq.json، والقطع على `/tiles/{z}/{x}/{y}.mvt`.
- **الطبقات:**
  - `roads`: من OpenStreetMap، ويُعاد تنزيل نسخة السعودية في كل بناء.
  - `places`: من الدليل الذهبي `releases/atlas-2026-11-02-v12/inputs/targets.parquet` في مخزن الأطلس. بلا مغلق نهائيًا، وبلا مواقع تقريبية، وبلا صفوف Google، وبلا وسائل تواصل.
  - `buildings`: **غير موجودة بعد.** المخزن لا يحوي `buildings.parquet`، والمفتاح في `FARQ_BUILDINGS_OBJECT` (`inputs/buildings.parquet`) لا يُفتح. الملف موجود فقط على قرص خدمة الأطلس (`/app/data/.../buildings_ingest/normalized/buildings.parquet`)، ولا تقرؤه خدمة أخرى. إلى أن يُرفع، يرسم التطبيق مباني Mapbox تلقائيًا.
- **إعادة البناء:**
  - أسبوعيًا (`REBUILD_HOURS=168`)، وعند كل نشر (`BUILD_ON_START=always`).
  - تستغرق نحو دقيقتين، والأرشيف القديم يبقى يخدم حتى يكتمل الجديد.
- **الوصول للمخزن:** يقرأ مخزن الأطلس بمتغيرات مرجعية (`${{farq-targeting.*}}`)، فلا يُنسخ أي مفتاح.
- **الاختبارات:** `cd apps/tiles && pip install -r requirements-test.txt && python3 -m unittest test_build_tiles` (11 اختبارًا، كلها ناجحة).

**بعد دمج الـ PR:** حوّل مصدر الخدمة في Railway من الفرع إلى `main`. هذا قرار المالك أو من يملك صلاحية Railway.

---

## 4. ما لم يُنجز وسببه

| البند | السبب | المطلوب |
|---|---|---|
| **إعادة بناء شبكة Valhalla من نسخة OSM نفسها**، لتمشي الملاحة على شوارع الخريطة نفسها | الخدمة في مستودع `FARQ-B2B` (`services/valhalla`)، ورُفضت صلاحية الدفع عليه من الجلسة السحابية | عند صلاحية B2B: مهمة دورية تبني `valhalla_tiles` من `saudi_arabia.osm.pbf` وتضعها على قرص `farq-valhalla` (مشروع `humble-fulfillment`) |
| **مباني الأطلس على الخريطة** | ملف المباني ليس في مخزن الأطلس (انظر القسم 3) | رفع `buildings.parquet` من قرص خدمة `farq-targeting` إلى المخزن مرة واحدة، تحت أي مسار ينتهي بـ`buildings.parquet`. البناء التالي يلتقطه وحده، ويمكن تشغيله فورًا بإعادة نشر `farq-map-tiles` |
| **CI على GitHub** | كل التشغيلات، و`main` أيضًا، تفشل خلال ثانيتين بلا runner (`runner_id: 0`) | على المالك فحص Billing / Actions usage في GitHub. خطوة اختبارات `apps/tiles` مضافة إلى `ci.yml` |
| **إضافة قاعدة ملكية البيانات إلى `FARQ-B2B/CLAUDE.md`** | نفس سبب Valhalla: لا صلاحية دفع | إضافة القاعدة نفسها الموجودة في `CLAUDE.md` هنا |
| **خلفية عرض الشوارع في الويب** (`apps/web`) | خارج النطاق المطلوب، فالمطلوب كان تطبيق الرحلات | لاحقًا: نفس الطبقات فوق خريطة الويب |

---

## 5. قرارات المالك المسجّلة

- كل بيانات فرق أطلس ملك لفرق، وعرضها في التطبيقات مسموح.
- بيانات Google (`gm:`) لا تُعرض.
- بيانات OSM تُعرض مع «© OpenStreetMap».
- لا أرقام جوال أو واتساب أو بريد في الخرائط والبحث العام.
- اللغة مع المالك عربية.
