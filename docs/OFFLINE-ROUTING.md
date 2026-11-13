# طريق المدينة بدون نت: دراسة الجدوى والتصميم

آخر تحديث: 2026-11-11. دراسة وتصميم فقط، بلا كود.
المسارات نسبتها إلى `apps/ios/SaryAlbarq/` ما لم يُذكر غير ذلك. أرقام الأسطر من `origin/main` اليوم، وما يخص «طريق الرجعة» و«جاهز للبر» من فرع `claude/offroad-next`، وقد تتزحزح.

**الفكرة في سطر:** نحفظ على الجوال «بلاطات التوجيه» (routing tiles) من Mapbox لطريق المدينة قبل الخروج من التغطية. وقتها يحسب `MapboxNavigationCore` أسرع طريق في المدينة بلا نت، بالواجهة نفسها التي نستعملها اليوم. السبب أن الموجّه الافتراضي في SDK v3 «هجين» (`hybrid`)، وهو أصلًا يلجأ إلى الحساب على الجهاز متى وجد البلاطات. ينقصنا فقط أن ننزّلها.

**مفتاح الثقة في هذه الوثيقة:**
- **[مؤكد]** = قرأته في كود الـSDK نفسه بالنسخة التي نستعملها (`mapbox-navigation-ios` عند الوسم `v3.27.3`)، أو في وثائق Mapbox الرسمية.
- **[افتراض]** = استنتاج أو تقدير لم أتحقق منه، ويحتاج قياسًا أو سؤال Mapbox.

ملاحظة عن المصادر: نطاقا `docs.mapbox.com` و`www.mapbox.com` محجوبان في جلسة البحث هذه. لذلك نُقلت نصوص الوثائق من نتائج البحث (مقتطفات من الصفحات الرسمية)، أما الكود فقُرئ من مستودع الـSDK مباشرة. الروابط في آخر الوثيقة.

---

## (أ) ما نستعمله اليوم بالضبط

| الحزمة | النسخة | أين ثُبّتت |
|---|---|---|
| `mapbox-maps-ios` (`MapboxMaps`) | **11.27.3** (`exactVersion`) | `project.yml` السطر 17، و`Package.resolved` |
| `mapbox-navigation-ios`، المنتجان `MapboxNavigationCore` و`MapboxDirections` | **3.27.3** (`exactVersion`) | `project.yml` السطر 22 و75–77 |
| `mapbox-navigation-native-ios` | 324.27.3 | `Package.resolved` (تبعية) |
| `mapbox-common-ios` (فيه `TileStore` و`OfflineSwitch`) | 24.27.3 | `Package.resolved` |

إذن نحن على **Navigation SDK v3** (`MapboxNavigationCore`)، لا v2. لا نستعمل `NavigationViewController`: عندنا واجهتنا الخاصة فوق خريطتنا.

### كيف نوجّه اليوم

- **`MapboxNavCore`** (`Sources/Navigation/MapboxNav.swift:22–60`): يُنشأ `MapboxNavigationProvider` واحد عند أول «ابدأ الملاحة». في إعداده:
  - `RoutingConfig(... routeRefreshPeriod: 120)` و`prefersOnlineRoute = true`. **لا يُضبط `routingProviderSource`، فيبقى على الافتراضي `.hybrid`** [مؤكد: `RoutingConfig.swift:47–51`، «Default value is `RoutingProviderSource/hybrid`»].
  - `predictiveCacheConfig: nil` (السطر 53)، أي لا تخزين تنبّئي.
  - لا يُضبط `tilestoreConfig`، فيبقى `.default`. معناه أن الملاحة والخريطة تشتركان في `TileStore.default` نفسه [مؤكد: `TileStoreConfiguration.swift`، `.default` = `navigatorLocation: .default, mapLocation: .default` → `TileStore.default`].
- **`MapboxNavRoutingProvider.routes`** (`MapboxNav.swift:146`) يستدعي `MapboxNavCore.navigation.routingProvider().calculateRoutes(options:)`. وثيقة الـSDK تقول عن هذه الدالة: «This may be online or offline route, depending on the configuration and network availability» [مؤكد: `RoutingProvider.swift:9–11`].
- **`SwitchingRouteProvider`** (`FarqValhallaRouteProvider.swift:183`) يختار بين Mapbox وValhalla فرق (على خادمنا). في «تلقائي» يسأل Mapbox أولًا.
- **`DesertAwareRouteProvider`** (`NavRouting.swift:50`) يلفّ أيًّا منهما:
  - يأخذ طريق الشوارع حتى `roadEnd` (نهاية طريق الشوارع).
  - ثم يكمل بشبكة البر (`DesertGrid` / `DesertTileStore`) بنجمة A* على الجهاز.
  - وإن لم تكتمل شبكة البر يُبقي طريق الشوارع ويعطي سهم اتجاه من نهايته.
- **`NavSession`** (`NavSession.swift:470–520`): لو رجع `NavRoutingError.offline` يعرض «سهم اتجاه» (`goDirect`) مع `fallback = .offline`، ويعيد المحاولة كل فترة (`scheduleRetry`).

### أين تُنزَّل الخرائط بدون نت

- `Sources/Map/OfflineMaps.swift` (`OfflineMaps`):
  - `OfflineManager` يحمّل حزمة الستايل (style pack).
  - و`TileStore.default.loadTileRegion` يحمّل منطقة واحدة لكل «منطقة محفوظة» (`sary-<epoch>`).
  - المحتوى: واصفة `TilesetDescriptor` للستايل، مع `mapbox-terrain-dem-v1` و`mapbox-streets-v8`، والطبوغرافي اختياريًا. الزوم 11–16، وأقصى ضلع 60 كم، والسقف الكلي 1 GiB (`OfflinePlan`).
- بعد نجاح التنزيل تُحفظ معه «دروب البر»: `DesertTileStore.shared.prefetch(area)` (السطر 211).
- الواجهة: `Sources/Screens/OfflineMapsView.swift` (فيها التقدير `estimate` ومفتاح الطبوغرافي).
- **لا توجد واصفة توجيه** (navigation tileset descriptor) في أي مكان من التطبيق. هذا هو النقص كله.

### الخطاف المنتظر (فرع `claude/offroad-next`)

- `ReturnRoute.roadRouting(online:offlineRoadGraph:)` في `Sources/Core/TripProgress.swift:532` يرجع `online || offlineRoadGraph`.
- يُستدعى اليوم في موضعين فقط، وكلاهما بلا `offlineRoadGraph`، فتبقى `false` دائمًا:
  - `LiveOutingController+Trip.swift:177` عند بدء «طريق الرجعة» على الجوال؛
  - والسطر 240 في `handOverReturnToRoad` عند الوصول إلى الملتقى (junction).
- `ReturnRoute.cityLeg` يحوّل الـ`Bool` إلى `.fastestRoad(to: home)`، فيُستدعى `navLongPressed(home…)` ← `NavSession` ← المزوّد أعلاه. وإلا فإلى `.outboundTrail` (نعيد طريق الذهاب).
- صف «جاهز للبر» هو `DesertReadiness` (`TripProgress.swift:703–745`) و`DesertReadinessRow` (`Plan/PlanSections.swift:119`)، وأجزاؤه اليوم: «الخريطة» و«الدروب» و«طريق الرجعة».

---

## (ب) هل يدعم Mapbox Navigation SDK v3.27.3 التوجيه بدون نت؟

**نعم، والدعم موجود في النسخة التي عندنا.** التفاصيل:

### ١. الموجّه الهجين (الحساب على الجهاز)

- `RoutingProviderSource` له ثلاث قيم: `.online` و`.offline` و`.hybrid`. نص `.hybrid` في الكود: «Attempts to use online with fallback to offline» [مؤكد: `Routing/RoutingProvider.swift:20–43`].
- وتقول `.offline`: «proper navigation data should be available offline».
- دليل الانتقال إلى v3 يصف الشيء نفسه: يطلب الطريق من Directions API إن وُجد اتصال، «و**يولّد الطريق محليًا على الجهاز** إن سنحت للـSDK فرصة تخزين موارد التوجيه» [مؤكد: Mapbox، Migrate to Navigation SDK v3].
- إعادة التوجيه (reroute) أثناء الملاحة تمر بالموجّه نفسه، فتعمل بلا نت أيضًا. وثيقة Offline الرسمية تقول إن المستخدم إذا خرج عن الطريق يستطيع الـSDK إعادة توجيهه دون اتصال [مؤكد: Mapbox iOS Navigation, Offline guide].
- `prefersOnlineRoute = true` (مضبوط عندنا): إذا رجع النت يحاول الـSDK الانتقال إلى نسخة «أونلاين» من الطريق نفسه، ليأخذ الزحمة [مؤكد: `RoutingConfig.swift:53–61`، `MapboxNavigator.swift:1167`].

### ٢. بلاطات التوجيه في منطقة محفوظة (`TileStore` + `TilesetDescriptor`)

- **الـAPI بالضبط** [مؤكد: `MapboxNavigationProvider.swift:113–125`]:
  ```swift
  public func getLatestNavigationTilesetDescriptor() -> TilesetDescriptor
  ```
  تعليقها في الكود: «It is intended to be used when creating off-line tile packs». ترجع واصفة لنطاقي `navigation` و`navigationHD`.
- **طريقة الاستعمال** في مثال Mapbox الرسمي `Examples/AdditionalExamples/Examples/Offline-Regions.swift` عند `v3.27.3` [مؤكد]: تُضاف الواصفة إلى `TileRegionLoadOptions` بجانب واصفة الخريطة، في المنطقة نفسها:
  ```swift
  TileRegionLoadOptions(geometry: …, descriptors: [mapsDescriptor,
      mapboxNavigationProvider.getLatestNavigationTilesetDescriptor()], …)
  ```
  ثم `tileStore.loadTileRegion(forId:loadOptions:progress:completion:)`، ثم `routingProvider().calculateRoutes(options:)` بعد قطع النت.
- الـ`TileStore` المقصود هو `coreConfig.tilestoreConfig.navigatorLocation.tileStore`، وهو عندنا `TileStore.default` نفسه الذي تستعمله `OfflineMaps`. **فلا نحتاج مخزنًا ثانيًا** [مؤكد].
- في v2 كان المصنع `TilesetDescriptorFactory.getLatest(...)`. في v3 حلّت محله الدالة أعلاه. وثائق v2 لا تنطبق علينا.
- **ملفات تعريف البيانات (dataset profile):** منذ 3.27.0 صار يوجد `RoutingConfig.datasetProfileIdentifier`، وقيمته الافتراضية `automobileAvoidingTraffic`. نص سجل التغييرات: «It is important to set this value before initializing `MapboxNavigationProvider` and use the same value for the following `ProfileIdentifier` in route requests options» [مؤكد: `CHANGELOG.md`، 3.27.0].
  - عندنا `NavRouteSpec` يرسل أحيانًا `.automobile` بدل `.automobileAvoidingTraffic`.
  - **[افتراض]** الطلب بملف تعريف لا يطابق البلاطات قد يفشل على الجهاز. لذلك نرسل `automobileAvoidingTraffic` دائمًا للحساب بلا نت.

### ٣. «التخزين التنبّئي» (predictive cache)

- `CoreConfig.predictiveCacheConfig: PredictiveCacheConfig?` (عندنا `nil`). الجزء الخاص بالملاحة هو `PredictiveCacheNavigationConfig.locationConfig`، وقيمه الافتراضية [مؤكد: `PredictiveCacheLocationConfig.swift`]:
  - 2000 م حول موقعي؛
  - 500 م حول الطريق النشط؛
  - 5000 م حول الوجهة.
- جزء الخريطة لا يعمل إلا إذا سُجّلت خريطة عبر `predictiveCacheManager.updateMapControllers(mapView:)` [مؤكد: `PredictiveCacheManager.swift:41`]. نحن لا نسجّل خريطتنا، فسيعمل جزء الملاحة وحده.
- **حدوده لحالتنا:**
  - يعمل حول الطريق الذي نسلكه فعلًا أثناء جلسة ملاحة، فيغطي في الغالب **طريق الذهاب نفسه**، لا البدائل الأسرع.
  - يخزّن في الذاكرة المؤقتة المحيطة (ambient cache) التي قد تُمسح.
  - لا يعمل إلا وجلسة الملاحة جارية (ونحن لا نشغّل Free Drive، لأنه يُحسب رحلة مستقلة).
- **الخلاصة:** مكمّل مجاني ومفيد، لكنه لا يُعتمد عليه وحده [افتراض مبني على الإعدادات أعلاه].

### ٤. `OfflineManager` ومنطقة تجمع الخريطة والتوجيه

- `OfflineManager` يخص حزم الستايل وواصفات الخريطة فقط.
- المنطقة نفسها تُحمَّل عبر `TileStore`، وتقبل خليطًا من الواصفات (مثال Mapbox أعلاه).
- فالجواب: **منطقة `TileRegion` واحدة يمكن أن تجمع بلاطات العرض وبلاطات التوجيه** [مؤكد].

### ٥. التكلفة والفوترة

| البند | ما نعرفه | الثقة |
|---|---|---|
| نموذج Navigation SDK v3 | «رحلات بالعدّاد» (metered trips): يُحسب المستخدم النشط شهريًا (MAU) ويُحسب كل رحلة توجيه نشط (Active Guidance). تعليق الفوترة في `MapboxNav.swift:9–19` يشرح متى تبدأ الرحلة وتنتهي عندنا | مؤكد (وثائق Pricing) |
| الأسعار المنشورة | ‎$0.30 لكل MAU بعد أول 100، و‎$0.08 لكل رحلة بعد أول 1,000، وتنزل مع الحجم | منقولة من صفحة الأسعار عبر نتائج البحث، فتحقق منها في لوحة الحساب |
| الطلبات أثناء الجلسة | «Requests made by the Navigation SDK during an Active Guidance or Free Drive navigation session are included free of charge» | مؤكد (وثائق Android Pricing، والنموذج واحد) |
| التنزيل بدون نت عمومًا | «resources downloaded for offline use are included in the regular MAU billing» | مؤكد لخرائط Maps SDK. **غير مؤكد** لبلاطات التوجيه تحديدًا |
| تنزيل بلاطات التوجيه **خارج** جلسة ملاحة (من شاشة الخطة) | لم أجد نصًا يقول إنه مجاني أو مدفوع منفصلًا | **[افتراض]** يدخل ضمن MAU. يجب التحقق من صفحة Statistics بعد تنزيل تجريبي، أو سؤال Mapbox |
| رحلة توجيه **بلا نت** | تبقى رحلة Active Guidance، فتُحسب كأي رحلة | **[افتراض]** أحداث الفوترة تُرسل عند عودة الاتصال |
| حساب طريق على الجهاز | لا يمر بـDirections API، فلا يُحسب طلبًا | **[افتراض]** معقول لأنه لا يصل لخادم |

**قيود شروط الخدمة:**

1. **لا تجميع مسبق في التطبيق** [مؤكد: iOS Maps Offline Concepts]: «Users of the SDK must retrieve Mapbox data intended for offline use from Mapbox servers — the data may not be preloaded, bundled or otherwise redistributed». معناه:
   - لا نضع بلاطات التوجيه داخل حزمة التطبيق؛
   - ولا ننسخها من جوال إلى جوال (مثل الشبكة القريبة `NearbyMesh`).
   - كل جوال ينزّلها بنفسه من Mapbox.
2. **حد 750 حزمة بلاطات** (tile packs) لكل التطبيق على الجهاز [مؤكد: Maps Offline concepts / مثال `offline-manager`]: «If this limit is reached, any `loadRegion` call will fail until excess regions are deleted».
   - **[افتراض]** النص يقول «maps tile packs»، فلا أعرف هل تُحسب حزم التوجيه ضمن الحد.
   - حجم مناطقنا (≤ 60 كم) بعيد عن الحد في الحالتين.
3. **البيانات ملك Mapbox، لا ملكنا.** قاعدة ملكية البيانات في `CLAUDE.md` تخص بيانات أطلس (ملكنا) وOSM وGoogle. بلاطات Mapbox نستعملها عبر الـSDK كما يسمح ترخيصها.
   - **[افتراض، بقراءتي لشروط Mapbox العامة]** لا يجوز استخراج شبكة طرق منها لبناء موجّه خاص بنا. فالبديل في (هـ) يُبنى من OSM أو أطلس، **لا** من `mapbox-streets-v8` الذي يقرؤه `RoadSnap`.

---

## (ج) الأحجام

### ما هو منشور رسميًا

وثائق Mapbox Navigation (Android, Offline / predictive cache) تعطي أمثلة بستايل Streets [مؤكد]:

| المنطقة | بيانات الملاحة | بلاطات الخريطة |
|---|---|---|
| برلين، نصف قطر 15 كم | 42 MB | — |
| شيكاغو، 15 كم | 43 MB | — |
| لندن، 15 كم | 90 MB | — |
| أتلانتا، نصف قطر 100 ميل (≈ 81,000 كم²) | **156 MB** | **659 MB** |

وتقول وثيقة «Estimating offline usage» إن الحجم يعتمد على المساحة وكثافة الطرق. أما Maps SDK v11 ففيه `TileStore.estimateTileRegion` الذي نستعمله أصلًا في `OfflineMaps.estimate`.

### تقديراتنا للمملكة [كلها افتراض، وتحتاج القياس في (و)]

**المنطق:**
- بيانات التوجيه في أتلانتا نحو ربع بلاطات خريطة Streets.
- خرائطنا المحفوظة أثقل بكثير من Streets، لأنها قمر صناعي (raster) مع تضاريس وStreets على الزوم 11–16.
- فطبقة التوجيه نسبتها إلى خرائطنا أصغر، ونقدّرها بنحو 5–15%.
- بلاطات التوجيه قطع كبيرة. منطقة صغيرة تجرّ بلاطة كاملة، ولهذا كثافة برلين لكل كم² عالية.

| النطاق | المساحة التقريبية | التوجيه (تقدير) | للمقارنة: العرض بأسلوبنا |
|---|---|---|---|
| الرياض: صندوق 60×60 كم (حد منطقتنا) | 3,600 كم² | **40–100 MB** | عدة مئات MB حتى 1 GB تقريبًا (القمر الصناعي حتى الزوم 16 هو الأثقل) |
| الرياض وما حولها حتى أطراف البر (نصف قطر ~120 كم) | ~45,000 كم² | **80–200 MB** | لا يتسع له سقفنا (1 GiB) بأسلوبنا الحالي |
| المدن الرئيسية: الرياض، جدة–مكة، الدمام–الخبر، المدينة، القصيم، أبها–خميس، كلٌّ بصندوق مدينته | — | **250–500 MB** مجتمعة | — |
| المملكة كاملة | 2.15 مليون كم²، أغلبها فارغ | **0.5–1.2 GB** (ثقة منخفضة) | غير عملي بأسلوبنا |

**الخلاصة العملية:**
- طريق المدينة لرحلة واحدة (ممر من البيت إلى الملتقى، مع صندوق المدينة) يقع في حدود **عشرات الميغابايت**. هذا مقبول جدًا بجانب منطقة العرض.
- تنزيل المملكة كلها لا يلزمنا.

---

## (د) كيف يدخل في كودنا

### ١. ماذا ننزّل، ومتى

**المشكلة:** المنطقة المحفوظة اليوم هي صندوق **الوجهة في البر**، لا المدينة. ورجعة المدينة تمشي من الملتقى (junction) إلى نقطة البداية (`PhonePlan.home`)، وهذه خارج ذلك الصندوق غالبًا. فإضافة واصفة التوجيه إلى المنطقة الحالية وحدها **لا تكفي**.

**المقترح:** منطقة توجيه مستقلة لكل طلعة، بمعرّف `sary-nav-<outingId>`:

- **الهندسة:** خط الطريق المخطط من نقطة البداية إلى الوجهة (`LineString`)، مع صندوق صغير حول نقطة البداية (نحو 10 كم). `TileRegionLoadOptions.geometry` يقبل أي `Geometry`، والـSDK ينزّل البلاطات التي تلمسها [افتراض: الواجهة تقبل `Geometry` عامة، والقطع الكبيرة تجعل الممر يغطي البدائل القريبة تلقائيًا].
- **الواصفات:** `[navProvider.getLatestNavigationTilesetDescriptor()]` فقط، بلا بلاطات عرض (فهي في منطقة الوجهة، أو تُعرض من الذاكرة المؤقتة).
- **البيانات الوصفية (metadata):**
  - `{"kind": "nav", "outing": id, "line": [...], "home": [lng, lat], "created": t}`؛
  - تبقى على الجهاز فقط. نقطة البداية قد تكون البيت، وهي بيانات شخصية، فلا تُرسل لأي خادم.
- **الحجم:** يُعرض بـ`estimateTileRegion` قبل التنزيل، ويُحسب ضمن سقف `OfflinePlan.totalCapBytes`.
- **الحذف:** بعد 14 يومًا من نهاية الطلعة، أو مع «احذف الكل». القيمة اقتراح.

**متى ننزّل:**

1. **تلقائيًا وأنت على نت** في هذه المواضع:
   - عند فتح الخطة أو «جاهز للبر» لطلعة لها وجهة؛
   - عند بدء ملاحة الذهاب (`startActiveGuidance`)؛ ننزّل على طول `NavRoute.coordinates` حتى `roadEnd`؛
   - عند حفظ الملتقى (`OutboundJunctionStore`) ونحن ما زلنا في التغطية؛ ننزّل على طول المسار المسجّل حتى الملتقى. هذا يغطي من غيّر طريقه عن المخطط.

   الحجم صغير، فلا نسأل. لكن نحترم «البيانات الخلوية المنخفضة» (Low Data Mode)، فنستعمل `networkRestriction: .disallowExpensive` عند الحاجة.
2. **يدويًا مع «احفظ الخريطة بدون نت»:** نضيف تبديلًا جديدًا تحت تبديل الطبوغرافي في `OfflineMapsView`، اسمه «طريق المدينة للرجعة»، ويكون مفعّلًا افتراضيًا. يضيف منطقة التوجيه من موقعي الحالي إلى المنطقة.
3. **التخزين التنبّئي:** نفعّل `PredictiveCacheConfig(predictiveCacheNavigationConfig: .init())` في `MapboxNavCore`، وجزء الخريطة لا يعمل لأننا لا نسجّل `updateMapControllers`. يزيد تغطية طريق الذهاب مجانًا أثناء الملاحة. التعليق الحالي في `MapboxNav.swift:52` يحتاج تعديلًا: البلاطات هنا لازمة لنا.

**ملاحظة:** `getLatestNavigationTilesetDescriptor()` دالة على `MapboxNavigationProvider`. فالتنزيل من شاشة الخطة يُنشئ الـprovider قبل أول «ابدأ الملاحة».
- **[افتراض]** هذا لا يُحسب رحلة، لأن الرحلة تبدأ مع `startActiveGuidance` بحسب تعليقنا في `MapboxNav.swift:11`.
- لكن يجب التأكد أن إنشاءه لا يشغّل الموقع أو Free Drive. نتحقق في (و).

### ٢. كيف يستدعي `roadRouting(online:offlineRoadGraph:)` الموجّه على الجهاز

**مبدأ التصميم:** لا نبني «موجّهًا ثانيًا». الـSDK يحسب على الجهاز من المسار نفسه (`calculateRoutes` على الموجّه الهجين). ودور الخطاف أن يقرر سلفًا هل نجرّب أسرع طريق أو نعيد طريق الذهاب.

```
offlineRoadGraph = NavTilesCoverage.covers(home: plan.home, from: junction-or-me)
```

- **`NavTilesCoverage`:** قاعدة صافية قابلة للاختبار (pure rule) بجانب `OfflinePlan`. تقرأ مناطق `sary-nav-*` المكتملة (`completed >= required`) وبياناتها الوصفية، وترجع `true` إذا كانت نقطة البداية ونقطة الانطلاق كلتاهما داخل ممر محفوظ (خط مع هامش، أو صندوق البيت).
- **الربط:** في الموضعين (`+Trip.swift:177` و`:240`) يصير الاستدعاء:
  `ReturnRoute.roadRouting(online: online, offlineRoadGraph: NavTilesCoverage.shared.covers(...))`.
- **ضمان لا يترك السائق بلا توجيه:** القرار المسبق قد يخطئ (بلاطة ناقصة، أو ملف تعريف لا يطابق). لذلك:
  - إذا فشل `navLongPressed(home…)` بلا نت (`NavSession.fallback == .offline / .routeFailed`) خلال ثوانٍ، يرجع `ReturnGuide` إلى `.outboundTrail(plan.cityTrail)` مع `cityTrailNote`.
  - هذا يحتاج إشارة من `NavSession` إلى الكونترولر (callback صغير)، ولا يغيّر `ReturnRoute` الصافي.
- **إصلاحان لازمان في المزوّدات:**
  1. في `SwitchingRouteProvider.routes`، مع اختيار `.farq`: خطأ Valhalla بلا نت يكون `NavRoutingError.offline`، لا `FarqRoutingError`، فيُرمى مباشرة ولا يصل أبدًا إلى Mapbox الذي يحسب على الجهاز (`FarqValhallaRouteProvider.swift:126` و`:222`). يجب أن يمر `.offline` إلى `viaMapbox`.
  2. في `MapboxNavRoutingProvider.options`: بلا نت نرسل `automobileAvoidingTraffic` دائمًا ليطابق ملف تعريف البلاطات (انظر ب-٢). لن تكون هناك زحمة على أي حال.
- **ما يبقى كما هو:**
  - `DesertAwareRouteProvider`: الرجعة في المدينة طريق شوارع يصل إلى هدفه، فلا يُطلب أي جزء بري (`offRoadLeft == false`).
  - `NavSession`، و`MapboxRoutesBox`، والتوجيه، والصوت المحلي (`ttsConfig: .localOnly`)، وإعادة التوجيه.
- **مخاطرة «نت ضعيف» (إشارة واحدة على أطراف البر):** الموجّه الهجين يجرّب الطلب الأونلاين أولًا، فقد ينتظر مهلة الشبكة قبل الحساب على الجهاز.
  - **[افتراض]** لا يوجد ضبط لكل طلب في v3: `routingProviderSource` إعداد عام عند الإنشاء.
  - نقيس المهلة في (و). إذا طالت نعرض «نحسب طريق المدينة من جوالك…» بدل الصمت.

### ٣. ماذا تقول الواجهة

**صف «جاهز للبر»** (`DesertReadiness`): نضيف جزءًا رابعًا اسمه `cityRoads: Bool?`:
- `nil` إذا لم تكن للطلعة نقطة بداية معروفة.
- **لا يمنع `ready`**: إعادة طريق الذهاب ما زالت توصلك البيت، فلا نخوّف أحدًا.

| الحالة | السطر | التلميح |
|---|---|---|
| محفوظ | «جاهز للبر: الخريطة ✓ الدروب ✓ طريق الرجعة ✓ طريق المدينة ✓» | «طريق المدينة محفوظ على جوالك» |
| ينزل الآن | «… طريق المدينة …» مع مؤشر | «نحفظ طريق المدينة على جوالك…» |
| غير محفوظ | «… طريق المدينة ✗» | «افتح التطبيق وأنت على نت قبل تطلع، عشان ترجع بأسرع طريق في المدينة بدون نت» |

**عند الملتقى بلا نت:**
- مع البلاطات: نص جديد مقابل `fastestRoadNote` هو «ما فيه نت · طريق المدينة محفوظ على جوالك: نكمل بأسرع طريق». ونعدّل `desertNote(_:roadRouting:)` ليصير: «ما فيه نت · نرجع على نفس دربك في البر، وبعده أسرع طريق في المدينة من جوالك».
- بدون البلاطات: يبقى `cityTrailNote` كما هو.

**`OfflineMapsView`:** سطر الطبقات (`parts`، السطر 125) يضيف «+ طريق المدينة» للمناطق التي معها توجيه. وتظهر مناطق `sary-nav-*` في القائمة بحجمها، باسم «طريق المدينة · <اسم الطلعة>».

---

## (هـ) البدائل إن لم يصلح Mapbox

متى لا يصلح: فوترة تنزيل غير مقبولة، أو حجم أكبر بكثير من التقدير، أو جودة أسوأ في المملكة، أو قيد في الشروط.

### بديل ١: Valhalla على الجهاز (`valhalla-mobile`)

- **ما هو** [مؤكد من README المستودع `Rallista/valhalla-mobile`]:
  - يبني Valhalla مكتبةً ثابتة لـiOS، كحزمة Swift اسم منتجها `Valhalla`، والنسخة 0.6.4.
  - الحد الأدنى iOS 16.4، ونحن على 17.0.
  - يشغّل `route` وغيرها «entirely against the tiles on the device».
  - و«`route` can also answer in the OSRM format … returned as raw JSON on iOS».
- **لماذا يناسبنا:**
  - خادمنا يشغّل Valhalla أصلًا على شبكة الخليج.
  - `FarqValhallaRouteProvider` يفك استجابة OSRM (مع `bannerInstructions` و`voiceInstructions`) إلى `RouteResponse`. **فالمفكّك نفسه يعمل على استجابة الجهاز.**
  - ثم إما `NavigationRoutes(routeResponse:routeIndex:responseOrigin: .customExternal)` (وهي SPI داخلية في 3.27.3، نستعملها اليوم)، وإما `LocalGuidanceEngine`.
- **البيانات:** OSM أو أطلس (ملكنا). يجب إظهار «© OpenStreetMap contributors» على الخريطة. **لا شيء من صفوف `gm:` أبدًا.** وتُقصّ البلاطات من شبكة خادم فرق نفسها، فيتطابق التوجيه أونلاين وأوفلاين.
- **الحجم [افتراض]:** بلاطات Valhalla للمملكة (طرق فقط، بلا ارتفاعات) بضع مئات MB. صندوق الرياض 20–60 MB. وتكبر المكتبة حجم التطبيق، وأقدّر 15–30 MB.
- **الجهد:**
  - الخادم: قصّ بلاطات Valhalla حسب الصندوق، وتقديمها بـmanifest وsha256 مثل `/desert/`. لكن خدمة Valhalla في مستودع `FARQ-B2B` ولا صلاحية دفع عليه (انظر `docs/HANDOFF-mac-agent.md:114`). 12–20 ساعة.
  - التطبيق: 16–24 ساعة.
  - الاختبار: 8 ساعات.
  - **المجموع نحو 40–55 ساعة.**
- **ما يحتاج تحققًا:** رخصة `valhalla-mobile` (ملف `LICENSE` غير موجود بهذا الاسم في المستودع، وValhalla نفسه MIT)، ونضج المشروع.

### بديل ٢: شبكة طرق مضغوطة وA* خاص بنا (مثل موجّه البر)

- **البناء:** في `apps/tiles` (يبني بلاطات البر ويقدّمها أصلًا) نضيف مرحلة تبني شبكة الطرق من مستخرج OSM للمملكة، أو من شوارع أطلس:
  - نحتفظ بالطرق القابلة للقيادة (نفس فئات `RoadSnap.drivable`)، مع الاتجاه الواحد (oneway) والسرعة التقديرية حسب الفئة والاسم؛
  - وقيود الالتفاف (turn restrictions) إن أمكن.
- **الصيغة:** بلاطات 0.5° بمحتوى ثنائي، وتُحمَّل بنمط `DesertTileStore` نفسه (manifest مع sha256، وقرص، ثم الخادم).
- **الحجم [افتراض، حساب تقريبي]:**
  - العقدة: 8 بايت (int32 لخط الطول والعرض).
  - الحافة: نحو 10 بايت (الهدف 4، الطول 2، الفئة والاتجاه 1، فهرس الاسم 3).
  - المملكة: نحو 2 مليون تقاطع و5 ملايين حافة، أي ~65 MB خامًا و~30–40 MB بعد الضغط، مع جدول الأسماء العربية.
  - الرياض: 5–15 MB.
- **الخوارزمية:** A* ثنائي الاتجاه على الشبكة، مثل `DesertRouter` (عندنا `MinHeap` جاهز). مدينة بحجم الرياض أقل من ثانية على الجوال [افتراض].
- **التعليمات:** نولّد المناورات من زوايا التقاطعات وتغيّر أسماء الطرق، ونخرجها `NavRoute` بـ`NavStep`، و`LocalGuidanceEngine` يتبعها.
  - أضعف من Mapbox وValhalla: بلا مسارات (lanes)، وقيود الالتفاف ناقصة، وتعليمات الدوّارات أبسط.
- **الجهد:**
  - خط البيانات: 12–16 ساعة.
  - الشبكة وA* والمناورات بالعربي: 24–32 ساعة.
  - الاختبارات والميدان: 10 ساعات.
  - **المجموع نحو 45–60 ساعة**، وجودة أقل.

### المقارنة

| | Mapbox على الجهاز | Valhalla على الجهاز | شبكتنا وA* |
|---|---|---|---|
| جهد التطبيق | **~30 ساعة** | ~40–55 ساعة | ~45–60 ساعة |
| جودة التعليمات | الأفضل (نفس ما نسمعه أونلاين) | جيدة (نفس خادمنا) | الأضعف |
| البيانات | Mapbox (ترخيصهم) | OSM أو أطلس (ملكنا مع إسناد OSM) | OSM أو أطلس |
| حجم رحلة واحدة | عشرات MB | عشرات MB، وحجم التطبيق +15–30 MB | بضع MB |
| الفوترة | ضمن MAU والرحلات (يحتاج تأكيدًا للتنزيل) | لا شيء | لا شيء |
| المشاركة عبر الشبكة القريبة | ممنوعة بالشروط | ممكنة | ممكنة |
| يعيد التوجيه بلا نت | نعم، من الـSDK | عبر `LocalGuidanceEngine` أو SPI | عبر `LocalGuidanceEngine` |

---

## (و) التوصية

**نبدأ بتوجيه Mapbox على الجهاز.** المسار في كودنا جاهز تقريبًا: الموجّه هجين افتراضيًا، والـ`TileStore` مشترك، والتوجيه والصوت وإعادة التوجيه كلها تعمل على `NavigationRoutes` الناتجة. ينقصنا التنزيل وقرار التغطية والواجهة. ويبقى Valhalla على الجهاز خطة ثانية إن فشلت بوابة القياس أدناه.

### المراحل والجهد

| # | العمل | ساعات |
|---|---|---|
| 0 | **بوابة قياس (spike) في DEBUG:** `estimateTileRegion` للتوجيه على صندوق الرياض 60 كم، وممر رياض إلى ثمامة، وجدة. تنزيل فعلي ثم `-SaryMapboxOffline` وحساب طريق. فحص صفحة Statistics في حساب Mapbox بعد يوم. التأكد أن إنشاء الـprovider لا يبدأ رحلة | 2–3 |
| 1 | `OfflineMaps`: منطقة `sary-nav-<outing>` (ممر وصندوق البيت)، وتقدير وتقدم وحذف وسقف | 6–8 |
| 2 | التنزيل التلقائي: الخطة / بدء ملاحة الذهاب / حفظ الملتقى، مع احترام Low Data، وتفعيل التخزين التنبّئي للملاحة | 4–6 |
| 3 | `NavTilesCoverage` (قاعدة صافية) وربطها بموضعي `roadRouting`، والرجوع إلى طريق الذهاب إن فشل الحساب | 3–5 |
| 4 | إصلاح `.farq` بلا نت في `SwitchingRouteProvider`، وتثبيت ملف التعريف بلا نت | 1–2 |
| 5 | الواجهة: `cityRoads` في «جاهز للبر»، والتبديل في `OfflineMapsView`، والنصوص | 3–4 |
| 6 | الاختبارات (وحدة وواجهة) | 4–6 |
| 7 | اختبار ميداني | 4 |
| | **المجموع** | **27–38 ساعة** |

### المخاطر

1. **فوترة تنزيل بلاطات التوجيه خارج الجلسة غير موثقة** عندي. المرحلة 0 تكشفها، وإلا نسأل Mapbox.
2. **الحجم الفعلي قد يخالف التقدير**، لأن كثافة الطرق في المملكة غير معروفة لنا. المرحلة 0 تقيسه.
3. **ملف التعريف:** طلب `.automobile` على بلاطات `driving-traffic` قد يفشل. نثبّت ملف التعريف بلا نت.
4. **الشبكة الضعيفة:** مهلة الطلب الأونلاين قبل الحساب على الجهاز.
5. **`getLatestNavigationTilesetDescriptor` يشمل `navigationHD`.** [افتراض] لا بيانات HD في المملكة غالبًا، فلا أثر يذكر على الحجم.
6. **قِدم البلاطات:** `getLatest` ينزّل أحدث نسخة. والـSDK كان يحذف النسخ القديمة تلقائيًا ويرجع لنسخة أقدم موجودة (سجل v2). **[افتراض]** يبقى السلوك نفسه في v3. نحدّث المنطقة إذا مر عليها أكثر من 30 يومًا ونحن على نت.
7. **قيد الشروط:** لا تجميع ولا مشاركة للبلاطات بين الأجهزة. هذا يغلق فكرة «جوال واحد ينزّل للقافلة كلها».
8. **حد 750 حزمة:** إن كانت حزم التوجيه تُحسب ضمنه فمناطقنا بعيدة عنه، لكن نعرض الخطأ `tileCountExceeded` بالعربي كما هو اليوم.

### خطة الاختبار

**وحدة (`Tests/`):**
- `NavTilesCoverage.covers` لهذه الحالات:
  - البيت داخل الصندوق؛
  - الملتقى على الممر؛
  - الملتقى خارج الممر؛
  - منطقة ناقصة (`completed < required`)؛
  - منطقة طلعة أخرى.
- `ReturnRoute.cityLeg(…, roadRouting: roadRouting(online: false, offlineRoadGraph: true)) == .fastestRoad`. الاختبار موجود جزئيًا في `TripProgressTests.swift:540`.
- `DesertReadiness`:
  - السطر مع «طريق المدينة» ودونه؛
  - `ready` لا يتأثر بـ`cityRoads == false`.
- `SwitchingRouteProvider` مع `.farq` وخطأ `.offline` من فرق: يجب أن يصل إلى Mapbox.
- الرجوع: `NavSession` يفشل بلا نت فيتحول `ReturnGuide` إلى `.cityTrail` مع `cityTrailNote`.

**واجهة / محاكي (UITest):**
- نزّل منطقة توجيه صغيرة في الرياض على نت، ثم أعد التشغيل بـ`-SaryMapboxOffline` (`SaryAlbarqApp.swift:143`، يقطع مكدّس Mapbox كله عن الشبكة عبر `OfflineSwitch`) مع `-SaryClearAmbient`.
- اطلب طريقًا داخل المنطقة. المتوقع: طريق بتعليمات عربية، لا سهم اتجاه، و`fallback == nil`.
- ثم خارج المنطقة. المتوقع: `.offline` أو `.routeFailed`، والرجوع إلى طريق الذهاب.

**ميداني (الأهم):**
1. على نت في الرياض: خطة طلعة إلى طرف البر (مثل الثمامة). تأكد أن «جاهز للبر» يقول «طريق المدينة ✓»، وسجّل الحجم المعروض.
2. اذهب بالملاحة حتى البر مع «سجّل مساري». يُحفظ الملتقى.
3. في البر: **وضع الطيران** (والموقع شغال).
4. «طريق الرجعة». المتوقع:
   - في البر: نفس الدرب (BackTrack) مع النص الجديد؛
   - عند الملتقى: «طريق المدينة محفوظ على جوالك: نكمل بأسرع طريق».
5. في المدينة، ما زلت على وضع الطيران:
   - تحقق أن الطريق **ليس** طريق الذهاب حيث يوجد أسرع منه؛
   - خذ منعطفًا خطأ عمدًا. المتوقع إعادة توجيه بلا نت خلال ثوانٍ؛
   - تحقق من الصوت العربي وأسماء الشوارع.
6. أطفئ وضع الطيران قبل البيت. المتوقع أن ينتقل الـSDK إلى الطريق الأونلاين نفسه (`prefersOnlineRoute`) دون قفزة في المسار.
7. كرّر الخطوة 4 وجوالٌ آخر بلا منطقة توجيه. المتوقع إعادة طريق الذهاب مع `cityTrailNote`، بلا تعليق ولا سهم أعمى.
8. كرّر على إشارة ضعيفة (Network Link Conditioner بخسارة 100%، أو إشارة واحدة فعلًا على طرف البر). قِس الزمن حتى ظهور الطريق.
9. بعد يوم: صفحة Statistics في Mapbox. هل ظهر التنزيل أو الرحلة بلا نت؟ وكيف حُسبا؟

---

## المصادر

**كود الـSDK** (`mapbox/mapbox-navigation-ios`، الوسم `v3.27.3`):
- `Sources/MapboxNavigationCore/MapboxNavigationProvider.swift` (`getLatestNavigationTilesetDescriptor`)
- `Sources/MapboxNavigationCore/Routing/RoutingProvider.swift` (`RoutingProviderSource`)
- `Sources/MapboxNavigationCore/Settings/RoutingConfig.swift`
- `Sources/MapboxNavigationCore/Settings/TileStoreConfiguration.swift`
- `Sources/MapboxNavigationCore/PredictiveCache/*`
- `Examples/AdditionalExamples/Examples/Offline-Regions.swift`
- `CHANGELOG.md` (3.27.0: `datasetProfileIdentifier`)
- رابط المستودع: https://github.com/mapbox/mapbox-navigation-ios/tree/v3.27.3

**وثائق Mapbox** (نُقلت عبر نتائج البحث، لأن النطاق محجوب في الجلسة):
- [Navigation SDK v3 iOS: Offline](https://docs.mapbox.com/ios/navigation/guides/advanced/offline/)
- [Navigation SDK v3 iOS: Offline regions example](https://docs.mapbox.com/ios/navigation/examples/offline-navigation/)
- [Navigation SDK v3 iOS: Pricing](https://docs.mapbox.com/ios/navigation/guides/pricing)
- [Navigation SDK Android: Pricing](https://docs.mapbox.com/android/navigation/guides/pricing/) (الطلبات أثناء الجلسة مجانية)
- [Navigation SDK Android: Migrate to v3](https://docs.mapbox.com/android/navigation/guides/migration-from-v2/) (الموجّه الهجين)
- [Navigation SDK Android: Offline](https://docs.mapbox.com/android/navigation/guides/advanced/offline/) (أحجام برلين وشيكاغو ولندن وأتلانتا)
- [Maps SDK iOS: Offline concepts and constraints](https://docs.mapbox.com/ios/maps/guides/offline/concepts/) (منع التجميع المسبق، والفوترة ضمن MAU)
- [Maps SDK iOS: Offline manager example](https://docs.mapbox.com/ios/maps/examples/offline-manager/) (حد 750)
- [Help: Estimating offline usage](https://docs.mapbox.com/help/troubleshooting/estimating-offline-usage/)
- [Mapbox pricing](https://www.mapbox.com/pricing)

**البدائل:**
- [Rallista/valhalla-mobile](https://github.com/Rallista/valhalla-mobile) (قُرئ README وPackage.swift مباشرة)
- [Valhalla](https://github.com/valhalla/valhalla)
