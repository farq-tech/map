# دمج «الاستكشاف» في الخريطة الواحدة: الجرد، قائمة التكافؤ، وخطة الـPRات

المرحلة ١ (وثيقة فقط، **ما تغيّر أي ملف Swift في هذا الـPR**). المصدر: `origin/main` عند `4857cf20` (بعد S1 حتى S6 من `docs/ONE-MAP-UNIFICATION.md`).
المسارات نسبتها إلى `apps/ios/SaryAlbarq/Sources/` إلا إذا ذُكر غير ذلك. أرقام الأسطر تقريبية (±٥) وتتحرك مع كل PR.
اللغة: عربي، وأسماء الكود بالإنجليزي. الوسم **[كود]** = قرأته في الملف، **[استنتاج]** = تحليل ما جرّبته على الجهاز.

## ١. قرار المالك (الاتجاه النهائي، بصيغته)

- «مود الاستكشاف ليس له داعي. هو نفسه الخريطة حقت النافيجيشن.» ثم توضيحان لاحقان:
  1. الخريطة الوحيدة التي تبقى هي **خريطة التنقل/الطلعة الغنية** (`OutingMapboxView` داخل `LiveOutingScreen`): فيها الطقس والصور العالية والكشتة وطرق Farq والملاحة. خريطة الرئيسية (`PlanMapView` داخل `MapHomeScreen`) الأفقر **لا تكون هي الباقية**؛ تُمتص كـ**وضع خامل (idle)** للخريطة نفسها: بحث، تصنيفات، أماكن محفوظة، بطاقة الطلعة القادمة تصير محتوى ورقة سفلية فوق نفس المضيف.
  2. المالك **يحب الاستكشاف لأنه دقيق** ولا يريد ضياع أي ميزة منه. أول خريطة يراها عند فتح التطبيق هي خريطة بدرجة الاستكشاف، بكل ميزاته، وفوقها محتوى الرئيسية.
  3. **توضيح أخير (لقطتا TestFlight)**: خريطة الرئيسية (قمر صناعي مسطّح + شرائح + ورقة) **ليس لها داعي**. الباقية هي خريطة التنقل **كما تظهر في لقطة الملاحة**: ميل ثلاثي الأبعاد، إضاءة دافئة شبه شمسية (`SandGrade`/`MapVisualsDirector`)، صور عالية الوضوح حادة، مباني وتسميات. وفي حال عدم وجود رحلة أو تنقل (الخامل = الرئيسية اليوم) **نفس الخريطة تُعرض بأعلى دقة**، لا بمظهر الرئيسية المسطّح.
- التسمية: **لا زر ولا وضع اسمه «الاستكشاف»** كوجهة مستقلة. قدراته (طبقات، طقس، كشتة، دروب، إحداثية وارتفاع، حفظ…) **دائمة التشغيل** على الخريطة الواحدة.
- معيار القبول للهجرة كلها: **قائمة التكافؤ (§٤) ١٠٠٪ خضراء على الخريطة الواحدة قبل حذف مدخل الاستكشاف أو واجهته القديمة.** أي ميزة يُقترح حذفها تُكتب في §٤.٤ بملاحظة صريحة للمالك ولا تُحذف بصمت.

القيود من `ONE-MAP-UNIFICATION.md` (تبقى سارية): تدريجي لا إعادة كتابة، اختبارات قبل وبعد، لا حذف قبل إثبات البديل، PR واحد لكل خطوة، **لا خريطة جديدة، لا منتقي طبقات جديد، لا منطق أعمال في ملفات الواجهة**، لا يُعلن أن ميزة بصرية تعمل دون لقطة بكسل من المحاكي (متغير واحد في كل مقارنة).

## ٢. ما هو «الاستكشاف» اليوم (لب الجرد)

الاستكشاف **ليس شاشة**، هو حالة داخل الطلعة المباشرة:
- المفتاح: `LiveOutingController.exploreActive` [كود `Live/LiveOutingController.swift:228`]، ويُشتق منه `LiveContext.exploring` (`Live/LiveContext.swift:9`، قاعدة الحل `LiveContextRule.resolve:84`: القيادة الفعلية تغلبه دائمًا).
- لأنه حالة داخل `LiveOutingScreen`، **يحتاج جلسة** (`model.session != nil`): بدون طلعة ما في استكشاف أصلًا. لهذا الرئيسية فقيرة: ما تقدر تدخله.
- ما يفعله `exploring` في الشاشة: يظهر `ExploreTopBar` بدل رأس الرحلة، `ExploreCrosshair` على الخريطة، عمود جانبي خاص (`exploreSide`)، تلميح سفلي، وتُخفى الصف السريع. وعلى الخريطة: **يفتح بوابات** كانت مقفولة: الطبقة المختارة (`layer: exploring ? mapLayer : .satellite`، `Views/LiveOutingScreen:86-89`)، التضاريس ٣D، طبقات الطقس (`WeatherOverlayRequest(active: explore.active)`، `Map/OutingMapboxView.swift:237`)، سطح الصور العالية (`HiResHosts.swift:10` `surface: exploring ? .exploration`)، تسميات الصور النظيفة، مسارات OSM (`OffroadTracks.visible(exploring:)` في `Map/Motion/MotionFX.swift:214`)، ورسم المسارات والأماكن المحفوظة (`ExploreMapDrawer`).
- **الخلاصة التصميمية**: معظم «ميزات الاستكشاف» هي في الحقيقة **قدرات في الخريطة الغنية مقفولة ببوابة `exploring`**. الهجرة في أغلبها = **فتح البوابة دائمًا** (مع حماية الأداء والقيادة) + نقل أزرارها من شريط الاستكشاف إلى المقابض الدائمة، وليست إعادة كتابة رسم.

### مداخل الاستكشاف الحالية [كود]
| المدخل | الملف:السطر | ملاحظة |
|---|---|---|
| بلاطة «استكشف الخريطة» في «+»/أدوات (`outing-explore`) | `Views/LiveActionSheet.swift:139` ← `performAction("explore")` `Live/LiveOutingController+Declutter.swift:289` | يختفي كمدخل منفصل |
| صف «صور عالية الوضوح» (`hires`) يدخل الاستكشاف ثم يفتح الطبقات | `+Declutter.swift:304` | يتحول لفتح الورقة مباشرة |
| الدخول التلقائي بسحب الخريطة أبعد من ٥ كم عن كل السيارات وأنت واقف | `Explore/LiveOutingController+Explore.swift:22` (`autoEnterM`) و`:102` `applyMapCenter` | يزول (الخريطة دائمًا بدرجة الاستكشاف) |
| `-SaryExplore` / `-SaryExploreAt lat,lng` (DEBUG: لقطات واختبارات) | `Live/LiveOutingController.swift:363-370` | تبقى كأعلام اختبار بمعنى «ابدأ حرّ الكاميرا» |
| «ارجع للطلعة» (`explore-exit`) | `Explore/ExploreViews.swift:650` ثم `exitExplore:77` | يزول مع الوضع |
| الخروج الإجباري عند القيادة أو بدء توجيه أو متابعة مسار | `exploreDrivingCheck:86`، `+Follow.swift:13`، استدعاءات في `LiveOutingController.swift:462,664,689` | يصير: عند القيادة ترتفع قيود (§٥) لا «خروج» |
| «البر» في الرئيسية (`HomeTool.menu`: الطقس هنا، القبلة، اقترح كشتة، دروب) | `Home/HomeTools.swift:6-` + `HomeDesertToolsMenu` | **نسخة موازية** لأدوات البر داخل الاستكشاف، تُدمج في ورقة واحدة |

### فروع كود ميتة أو مكررة [كود]
- `ExploreHeader` (`ExploreViews.swift:7`)، `ExploreReadout` (`:111`) و`ExploreLayerSections` (`:239`): **لا أحد يستدعيها** عدا `ExploreLayersSheet` القديمة (`:186`) التي تبقى فقط خلف `-SaryLegacyLayersSheet` (DEBUG، `MapLayersSheetModel.swift:105`). تُحذف في الخطوة الأخيرة.
- `ExploreTopBar` فيه منتقي الطبقة الأساسية الثلاثي (`:648-690`) وزر الطبقات في العمود الجانبي يفتح نفس الخيارات: التكرار D2 من الوثيقة الأم.

## ٣. الخريطة الباقية والوضع الخامل (التصميم المختصر)

```
RootView
 └─ MapScreen (= LiveOutingScreen اليوم)    ← الخريطة الباقية، مضيف واحد
     ├─ وضع idle   : لا جلسة طلعة. ورقة سفلية = محتوى الرئيسية (بحث، تصنيفات، طلعاتي، دعوة، بطاقة مكان)
     ├─ وضع outing : جلسة طلعة جماعية (أصدقاء، SOS، لاسلكي)
     ├─ وضع navigate: توجيه (فردي = جلسة solo محلية، أو ضمن طلعة)
     └─ وضع follow : اسلك مسارًا
   قدرات الاستكشاف (طبقات/طقس/كشتة/دروب/إحداثية/حفظ…) = ثابتة في كل الأوضاع، مع حماية القيادة
```
- **جودة العرض في الوضع الخامل (معيار إلزامي، لا تفصيل شكلي)**: الخامل يرث إعدادات خريطة التنقل نفسها لا إعدادات `PlanMapView`: (أ) الصور العالية الوضوح مفعّلة افتراضيًا (`HiResSettings.userOn` افتراضه `true` أصلًا، `HiResSettings.swift:28`، والسطح `exploration` يفتحها في الخامل)؛ (ب) ميل افتراضي معقول للخامل (٤٠° مقترح، يغيّره المستخدم بسحب بإصبعين) بدل ٠° (`OutingMapboxView.swift:171` كاميرا ابتدائية مسطّحة)؛ (ج) إضاءة `SandGrade` ومؤثرات `MapVisualsDirector` كما في الملاحة؛ (د) تسميات حادة، مباني، Farq. **حرس الأداء والبطارية**: وضع الطاقة المنخفضة أو الحرارة العالية يوقف الصور العالية (`HiResGate.swift:79` `.paused` موجود) فيرجع الخامل لقمر صناعي عادي مع ميل أقل، وبلا إنترنت يُستعمل ما هو محفوظ مع ملاحظة صادقة (`offlineNote`). السقوط الاحتياطي يُوثَّق ويُقاس بلقطة لكل حالة.
- **الوضع الخامل بلا جلسة سيرفر**: الجلسة الفردية `OutingSession.solo` أصلًا **محلية بالكامل** (`kind.isLocal`، لا إرسال ولا SOS سيرفر، `App/OutingSession.swift:105-118,1700`) وهي مسار «اتجه» اليوم (`App/AppModel.swift:954 openSolo`). فالخريطة الغنية تقدر تقوم بجلسة محلية خاملة بدون لمس `OutingSession` ولا قواعد الخصوصية. **[استنتاج]**: التحقق من أن جلسة خاملة لا تظهر كطلعة في «طلعاتي»/الإشعارات/`ShareMemory` شرط داخل الخطوة EM2 (§٦).
- قواعد السلامة الباقية بلا تغيير: لا تعديل في `OutingSession` (سباقات SOS و«أخفِ موقعي»، طابور الأفعال دون اتصال)، CarPlay يقرأ `NavSession`/`LiveOutingController` فلا تُعاد تسمية خصائص يقرأها بلا غلاف توافق، الدعوات (مساران اليوم: `RootView:63` و`LiveSheet:80`) تبقى كما هي، `openSolo` يبقى.

## ٤. قائمة التكافؤ (Parity Checklist): كل ميزة استكشاف وأين تعيش في الخريطة الواحدة

العمود الأخير هو **شرط القبول**: لا يُعلَّم «✓» إلا بعد اختبار يمر **وصورة محاكي** على الخريطة الواحدة (وضع idle ووضع outing). الحالة الأولية للكل: ☐.
الاختصارات: **U** وحدة، **UI** XCUITest، **S** لقطة محاكي، **Reg** يمر عبر `MapLayerRegistry`/`MapLayersSheet` (S1-S6 المدموجة).

### ٤.١ الدخول والحالة والكاميرا
| # | الميزة | الكود | من يستعملها غيره | مكانها في الخريطة الواحدة | اختبار/إثبات يُنقل أو يُضاف |
|---|---|---|---|---|---|
| P01 | مدخل «استكشف الخريطة» + دخول الصور العالية | `LiveActionSheet:139`, `+Declutter:289,304` | `ReachabilityUITests.testActionSheetHoldsEveryAction` | يُحذف المدخل؛ الصف يفتح ورقة الطبقات مباشرة (ملاحظة للمالك: §٤.٤) | UI `ExploreUITests.testEnterFromToolsAndExitInOneTap` يُعاد كتابته: «قدرات الاستكشاف موجودة دون دخول» |
| P02 | الدخول التلقائي ببعد ٥ كم + رسالة «ارجع للطلعة» | `+Explore:22,102`, `ExploreRules.farFromGroup` | `Tests/ExploreTests.testFarFromGroupNeedsALiveReference` | **يزول** (لا حاجة: القدرات دائمة). المنطق النقي يبقى إن لزم لـ«شوف الكل» | U تُنقل أو تُحذف بملاحظة |
| P03 | الخروج «ارجع للطلعة» + إعادة تأطير المجموعة | `+Explore:77` `exitExplore`, `ExploreViews:650` | `RealisticUITests.testEnterAndExitFromExploration` | زر «شوف الكل» الموجود في «أدوات» (`fit`) + كاميرا حرة تلقائيًا | UI جديد: بعد سحب الخريطة، «شوف الكل» يرجع التأطير |
| P04 | الخروج الإجباري عند القيادة/التوجيه/متابعة المسار | `+Explore:86`, `+Follow.swift:13` | CarPlay لا يقرأه [كود: لا ذكر في `CarPlay/`] | قيود القيادة: المقابض الثقيلة (إحداثية، حفظ، درون، واقعي، ٣D) تُخفى أثناء القيادة؛ الطبقات وطقسها تبقى | U قاعدة نقية جديدة `MapCapabilityRules` + UI `LayersButtonUITests.testVisibleInStoppedDrivingExploring` |
| P05 | الطبقة الأساسية تُطبَّق فقط عند الاستكشاف (خارجه ثابتة قمر صناعي) | `LiveOutingScreen:86-93` | `HomeFlowUITests.testHomeFollowsChosenBase` | تُطبَّق دائمًا من السجل (قرار #١ في §١٠ الوثيقة الأم: تتذكر الآخر) | UI `LayersToggleUITests.testBaseLayerSwitchStillWorksAndPersists` في الوضعين |
| P06 | الكاميرا لا تلاحق المجموعة أثناء الاستكشاف (`keepGroup=false`) | `Map/OutingMapboxView.swift:695` | – | تُشتق من «سحب المستخدم» (`userPannedMap`) لا من وضع | U `FollowCameraTests` + حالة جديدة |
| P07 | سلوك السياق: إخفاء الصف السريع والقمة المصغّرة في الاستكشاف | `LiveSheet:45`, `+Declutter:66,128,167` | `LiveCalmTests`, `DeclutterTests`, `LiveDeclutterTests` | في idle: محتوى الرئيسية بدل الصف السريع | U تُحدَّث (6+5+1 إشارة لـ`explor`) |
| P08 | أعلام DEBUG `-SaryExplore`, `-SaryExploreAt` | `LiveOutingController:363-370` | `DeclutterShotsUITests`, `LayersShotsUITests`, `ExploreTapsUITests`, … | تبقى بالمعنى الجديد (كاميرا حرة/مركز) حتى تُهاجر الاختبارات | كل UI يستعملها يمر قبل/بعد |

### ٤.٢ عناصر الواجهة
| # | الميزة | الكود | من يستعملها غيره | مكانها في الخريطة الواحدة | اختبار/إثبات |
|---|---|---|---|---|---|
| P09 | شريط الطبقة الثلاثي (قمر/طبوغرافي/عادي) `explore.layer.*` | `ExploreViews:648-690` | `ExploreTapsUITests`, `ExploreUITests.testEnterFromActionsAndSwitchLayers`, `testTopoScreenshot` | يتحول لاختصار مصغّر يقرأ `MapLayerRegistry` فوق الخريطة، والورقة المشتركة هي الأصل (القاعدة ٢) | UI نفسها بمعرّفات ثابتة + S |
| P10 | شريحة «الكشتة» `explore.camp` | `ExploreViews:700` ← `performAction("camp")` | `ExploreTapsUITests`, `CampSitesUITests.testSuggestTopFiveWithWindReasonsAndGo` | شريحة في ورقة «البر» الموحدة + صف في الطبقات (موجود) | `CampSitesUITests` تمر على idle وouting |
| P11 | شريحة «دروب البر» `explore.desertRoute` | `ExploreViews:701`, `+Declutter:292` | `DesertGazetteerUITests.testNufudChipListsRealPlacesAndStartsATrip` | نفسها، وبطاقة المكان الموحدة تعرضها للمكان الصحراوي | UI + `Tests/DesertRouterTests` |
| P12 | بطاقة الإحداثية: عرض عشري/DMS، الارتفاع، نسخ، حفظ (`explore.coordinate/elevation/coord-format/save`) | `ExploreCoordinateBar:734`, `ExploreRules`, `+Explore:120,138` | `ExploreUITests.testSavePlaceAndListIt`, `Tests/ExploreTests` (٣ اختبارات) | بطاقة صغيرة ثابتة تحت العلوي (تُخفى أثناء القيادة) تتبع علامة الوسط | S + UI نفسه + U للتنسيق |
| P13 | علامة الوسط (Crosshair) + قراءة المركز المستقرة | `ExploreCrosshair:83`, `OutingMapboxView.onCenter`, `ExploreReadingModel` | – | دائمة في idle والاستكشاف الحر؛ مخفية أثناء التوجيه | S |
| P14 | الارتفاع من Terrain-DEM (لا يُخترع أبدًا) | `ExploreRules.elevationText:34`, `MapCenterReading` | `ExploreTests.testElevationIsNeverInvented` | بطاقة P12 | U موجود |
| P15 | تلميح «اضغط على أي مكان…» `explore.hint` | `LiveOutingScreen:306-318` | `ExploreUITests` | يظهر في idle فقط عند ورقة مصغّرة | UI |
| P16 | العمود الجانبي: الطبقات `map.layers`، أماكني، موقعي، درون، واقعي | `exploreSide:494`, `SaryMapControlItem.explore:172` | `ReachabilityUITests.testExplorationToolsWithinTwoTaps`, `LayersButtonUITests`, `ScreensUITests.testExploreControlsAnswer` | عمود المقابض الدائم (`map.layers` و`locate` موجودان بالفعل في الطلعة والرئيسية بعد S5/S6)؛ «أماكني» و«درون» و«واقعي» تنضم بقاعدة «واقف فقط». عمود الخامل بعد إزالة القبلة: الطبقات، موقعي، (أماكني)، «المزيد» | UI + قاعدة «زرين كحد أقصى» في `LiveCalmTests` تتعدل بقرار مكتوب |

### ٤.٣ محتوى الخريطة
| # | الميزة | الكود | من يستعملها غيره | مكانها في الخريطة الواحدة | اختبار/إثبات |
|---|---|---|---|---|---|
| P17 | طبقات الطقس: سحاب/مطر/رياح/ربيع + فترة المطر ٣/٥/٧ أيام | `Weather/WeatherOverlay.swift:25`, `WeatherLayers.swift:106`, بوابة `OutingMapboxView:237` | `LayersToggleUITests.testWeatherLayersToggleAndRainPeriodAreReachable`, `WeatherCardUITests`, `Tests/WeatherLayersTests` | `MapLayerRegistry` (S3 مدموج) + بوابة `active` تصير دائمة | UI موجود + S مع/بدون المطر على idle |
| P18 | مواقع الكشتة على الخريطة + بطاقة الموقع عند اللمس | `CampSites/CampSitesMapLayer.swift:9`, `LiveOutingScreen:132` `campSite` | `CampSitesUITests.testLayerToggleInLayers` | طبقة سجل + نفس البطاقة | UI + S |
| P19 | «اقترح لي مكان كشتة» أحسن ٥ + سبب الريح + الرجوع الآمن | `CampSites/CampSuggestSheet.swift`, `CampSites.swift` | `CampSitesUITests` (٧ اختبارات), `Tests/CampSitesTests` | ورقة «البر» الموحدة | الاختبارات نفسها |
| P20 | مخطط دروب البر (مسارات مقترحة من الأقمار) + «امشِ عليه» | `CampSites/DesertRouter.swift`, `DesertRouteSheet.swift:5`, `DesertToolsHost` | `Tests/DesertRouterTests`, `TrackFollow*` | بطاقة المكان + ورقة «البر» | U + UI |
| P21 | مسارات OSM الصحراوية | `Map/Motion/OffroadTracks.swift:14`, `MotionFX:214` | `Tests/MapLayerDataTests` | طبقة سجل (`osmTracks`) تصير دائمة حسب المفتاح | U + S |
| P22 | قاموس الأماكن الصحراوية (طبقة الأسماء/المضلعات) | `DesertGazetteer/DesertGazetteerMapLayer.swift:17` | **الرئيسية تستعمله أصلًا** (`MapHomeScreen:838`، `HomeDesert`) | تنتقل مع بحث الرئيسية إلى الخريطة الواحدة | `DesertGazetteerUITests` + `Tests/DesertGazetteerTests` |
| P23 | الصور عالية الوضوح (شارة + سطح استكشاف) | `Map/AIEnhance/HiResImagery.swift:21`, `HiResHosts.swift:10`, `HiResViews.swift:12` | `HiResImageryUITests` (٤، منها `testBadgeInExplorationThenActiveNavigation` فاشل معروف) | سجل (S3) + سطح يُشتق دائمًا لا من `exploring` | UI + `Tests/HiResImageryTests` |
| P24 | ~~القبلة (شعاع على الخريطة + زر ▲)~~ **أُزيلت بقرار المالك (٢٠٢٦-١١-١٣)**: «إذا شغلته يطلع الخط المتقطع… هذا أصلًا ما نحتاجه». حُذف الزر من الرئيسية والخامل وخريطة الطلعة، وحُذف رسم الخط (`QiblaMapOverlay`) وصف طبقة القبلة من الورقة المشتركة (`MapLayerCatalog.qibla`). المفتاح `sary.map.qibla.visible.v1` يبقى ثابتًا بلا قارئ فلا يعيد الخط أبدًا. **البوصلة نفسها (شاشة القبلة) باقية** في «البر» وفي «طقس واتجاه» داخل أدوات الطلعة. | `Qibla/Qibla.swift` (`QiblaView`) | — | **لا شيء على الخريطة** | `QiblaTests` (البوصلة) تبقى؛ `HomeFlowUITests.testHomeMapHasNoQiblaButtonAndTheCompassIsInTheTools` | ✓ مُزال |
| P25 | التضاريس ثلاثية الأبعاد | `controller.terrain3D`, `OutingMapboxView.setTerrain3D`, `ExploreViews:288` | `ExploreUITests.testTracksSheetAndTerrain` | سجل (جلسة) + قيد «واقف فقط» | UI + S |
| P26 | الطبقات الأساسية: قمر/طبوغرافي/عادي + ملاحظة العمل بلا إنترنت الصادقة | `Explore/MapLayer.swift:7`, `ExploreRules.offlineNote:48` | `Tests/MapLayersSheetModelTests`, `ExploreTests.testOfflineNotesAreHonest` | `MapLayersSheet` (موجودة) | U + UI + S (خطر: أوفلاين، §٥) |
| P27 | الخرائط بلا إنترنت (صف في الورقة يفتح منتقي المنطقة) | `MapLayersSheet:228` `explore-offline`, `Screens/OfflineMapsView.swift:271` | الإعدادات | صف الورقة نفسه (يبقى غطاء منفصل بقرار الوثيقة الأم) | UI `LayersToggleUITests` |
| P28 | الأماكن المحفوظة: رسم + قائمة + إضافة من الوسط + تعديل أيقونة + حذف + ملاحة + درون + عرض على الخريطة | `Explore/SavedPlaces.swift`, `ExploreViews:315-470`, `ExploreMapDrawer.swift`, `+Explore:126,144,157` | الرئيسية (`favorites`/اختصارات)، `RealisticUITests.testFromSavedPlaces` | ورقة «أماكني ومساراتي» (من أي وضع) + رسمها دائم | `ExploreUITests.testSavePlaceAndListIt` + `Tests/ExploreTests.testSavedPlaces` |
| P29 | مكتبة مسارات GPX: استيراد/تصدير/مشاركة/إظهار/إخفاء/اسلك | `Explore/TrackLibrary.swift`, `ExploreViews:472-600` | `TrackFollow*`, تفاصيل المسار | نفس الورقة | `ExploreUITests.testTracksSheetAndTerrain` + `Tests/ExploreTests` (٢) |
| P30 | درون: طيران استكشافي حول علامة الوسط | `exploreSide:496`, `controlTapped:558`, `MapVisualsHub.fly` `Map/Visuals/VisualEffectsSettings.swift:185` | `VisualsUITests.testDroneButtonInPointCardFliesAndStopsOnTouch` | مقبض جانبي (واقف فقط) + زر بطاقة المكان | `VisualsUITests` (٢ درون + لقطات) |
| P31 | الوضع الواقعي (MapKit) + عرض المدينة بنفس الكاميرا | `Realistic/RealisticEntry.swift:8`, `LiveOutingScreen:480-492,557` | `RealisticUITests` (٦), `VisualsUITests.testCityTiltOffersRealisticAtTheSameCamera` | مقبض جانبي + صف الطبقات (موجود) | UI نفسها |
| P32 | مؤثرات الصورة (توهج، غبار، نجوم) تعرف `exploring` | `MotionFX.swift:53`, `MapVisualsDirector.swift:11,161` | `Tests/MapVisualsTests`, `VisualsUITests` اللقطات | الإشارة تُشتق من «كاميرا حرة وواقف» | U + S |
| P33 | تسميات الصور النظيفة عند الطبقة قمر صناعي | `LiveOutingScreen:93` | – | قاعدة `labels` تُشتق من الطبقة لا من `exploring` | S (متغير واحد) |
| P34 | بريف المكان عند لمس الخريطة (ومقبض الضغط المطوّل للتخطيط) | `Plan/LivePlaceBrief.swift:24` `mapTappedEmpty`, `Plan/LivePlan.swift:44` `planLongPress` | `PlaceBriefUITests`, `Tests/PlaceBriefTests` | بطاقة المكان الموحدة (S18) | UI موجود |
| P35 | حفظ وقراءة إعدادات: مفتاح الطبقة، صيغة الإحداثية، المسارات المعروضة (ويُمسحون عند حذف الحساب) | `App/AccountDeletion.swift:89`, `ExploreRules.formatKey`, `sary.tracks.shown.v1` | `AccountDeletionTests` | مفاتيح السجل نفسها؛ **الهجرة لا تغيّر قيمة مخزنة** | U `LayerMigrationTests` |
| P36 | ورقة الطبقات المشتركة `explore.layers.sheet` (+ القديمة خلف علم) | `Map/Layers/MapLayersSheet.swift`, `ExploreLayersSheet:186` | S2-S6، `LayersSheetUITests` | الورقة الوحيدة؛ القديمة تُحذف (§٦) | UI موجود |

**العدد: ٣٦ ميزة/سلوك استكشافي في قائمة التكافؤ (P01-P36) + ٩ بنود من الرئيسية (H01-H09) + ٧ معايير جودة عرض (R01-R07)** (٨ دخول وحالة وكاميرا، ٨ واجهة، ٢٠ محتوى خريطة). منها ما ينتقل كما هو (طبقات السجل، الأماكن، المسارات)، وما يتحول (شريط الطبقة، البطاقة)، وما يزول بتصميم (P02 الدخول التلقائي، P01 المدخل، P03 «ارجع للطلعة»).

### ٤.٤ ما يُقترح تغييره وليس حذفه (ملاحظات صريحة للمالك، لا شي يُنفَّذ بدون موافقة)
1. **P02 الدخول التلقائي** لا معنى له حين تكون الخريطة بدرجة الاستكشاف دائمًا. تزول معه رسالة «وضع الاستكشاف · ارجع للطلعة». يتأثر نص واحد فقط.
2. **P01** بلاطة «استكشف الخريطة» في «أدوات» تُحذف؛ ما يلزم بديلها لأن الطبقات وأدواتها على الخريطة.
3. **P16** قاعدة «زرين كحد أقصى في عمود الخريطة» (`LiveCalmRules`) لا تتسع لـ: طبقات + أماكني + موقعي + درون + واقعي. المقترح: الطبقات وموقعي ظاهران دائمًا، والبقية (أماكني/درون/واقعي) داخل «الطبقات» أو صف أدوات يظهر والجوال واقف. **قرار تصميم يحتاج موافقة المالك قبل التنفيذ**.
4. لا ميزة استكشاف أخرى مقترح حذفها.

### ٤.٥ ما تضيفه الرئيسية (تصير طبقات واجهة فوق نفس الخريطة في الوضع الخامل)
| # | ميزة الرئيسية | الكود | مكانها في الخامل |
|---|---|---|---|
| H01 | شريط البحث + نتائج (`PlaceSearch`، «دليل البر» أولًا بلا إنترنت) | `Home/MapHomeScreen.swift:571,772` | الورقة السفلية الخاملة؛ مكوّن بحث واحد (`LiveSearchSheet` الموجودة هي الأساس، S18) |
| H02 | شرائح التصنيفات: **البر، مطاعم، مقاهي، مساجد، محطات** | `:182,193,215` | شريط شرائح عائم على الخريطة نفسها في الخامل فقط، يختفي أثناء الطلعة الحية (قرار #٣)؛ «البر» تفتح ورقة «البر» الموحدة (EM6) |
| H03 | الأماكن المحفوظة والاختصارات (بيت/عمل…) | `:631`, `Home/HomeShortcuts.swift`, `Explore/SavedPlaces.swift` | الورقة الخاملة؛ نفس مخزن P28 |
| H04 | **«طلعة جديدة»** و**«انضم برابط»** | `:140,550` (`CreateOutingWizard`, `JoinByLinkSheet`) | صفّان ثابتان في الورقة الخاملة |
| H05 | طلعاتي: نشطة/قادمة/ابدأ/فشل/دعوة | `:430-570,711` | بطاقات الورقة الخاملة (النشطة تفتح الطلعة) |
| H06 | بطاقة المكان (`placeCard`) وإجراءاتها (اتجه، أنشئ طلعة، أضف لطلعة، احفظ) | `:887,939` | بطاقة موحدة (`PointCard`) S11/S18 |
| H07 | **موقعي** + الطبقات (زر القبلة أُزيل بقرار المالك ٢٠٢٦-١١-١٣؛ بوصلة القبلة في «البر») | `:235,249` | العمود الدائم: `map.layers` ثم `locate`؛ المساحة المحرَّرة لأزرار ٢D/٣D وتأثيرات الطقس (فرع `camera-3d-nosun`) |
| H08 | «اتجه» → طلعة فردية | `:1218` ← `AppModel.openSolo:954` | تبقى؛ بلا هدم الخريطة (S17) |
| H09 | الملف الشخصي والإعدادات (`ProfileSheet` ثم `HomeRoute`) | `:1230`, `Screens/HomeView.swift` | زر الملف في الورقة الخاملة يفتح ورقة الملف؛ الدفع إلى الإعدادات يحتاج غلاف تنقل (EM3) |

### ٤.٦ معيار جودة العرض (R): الخامل بدقة خريطة التنقل
نفس الموقع ونفس التقريب، **متغير واحد** في كل مقارنة. لقطات قبل/بعد: «الرئيسية المسطحة» (`PlanMapView`) مقابل «الخامل بدرجة التنقل».
| # | المعيار | كيف يُقاس | الحالة |
|---|---|---|---|
| R01 | الصور عالية الوضوح تعمل افتراضيًا في الخامل (شارة/جودة مرئية) | S: خامل `-SaryHiRes on` مقابل `off` **عند تقريب تعمل فيه**؛ UI شارة الصور | ◐ مثبت على المحاكي في البر عند z18 (لقطات `docs/explore-merge-shots/em4-r01-*`)؛ المدينة: يصل z19 بالتشغيل فقط؛ الجهاز غير مثبت |

**نتيجة تحقيق R01 (لماذا كانت اللقطتان متطابقتين)**: التحسين على الجهاز (Real-ESRGAN) لا يُطلب إلا من تقريب **١٦ في البر و١٨ في المدن** (`HiResZoom.desertMinZoom/cityMinZoom`، `HiResGate.swift`)، والخامل يفتح على تقريب ~١٥، فلا طبقة محسّنة أصلًا فكانت المقارنة بين صورتين بلا تأثير. وسقف تقريب القمر الصناعي نفسه يرتفع من ~١٨ إلى ١٩ فقط مع التشغيل (`MapLayer.maxZoom`)، فمقارنة المدينة عند z19 ليست بمتغير واحد: «بدون» تُقصّ عند السقف. عند Huraymila z18 (بر): الشارة «مُحسّنة» تظهر وفي اللقطة «مع» نباتات وتضاريس أحدّ بوضوح (فرق ~١٫٤٪ من البكسلات: التحسين جزئي وقت اللقطة). **نتيجة تصميمية**: الدقة العالية لا تُرى عند التقريب الافتراضي للخامل؛ ما يحسّن الشاشة الأولى هو Farq والإضاءة والميل والمباني، والصور العالية عند الاقتراب. **على الجهاز يلزم**: زمن الاستدلال على Neural Engine، الحرارة والطاقة المنخفضة، الشبكة الحقيقية، وبوابة السرعة (١٥ كم/س).
| R02 | ميل افتراضي للخامل ومضاعف بسحب بإصبعين، لا يثبّت | S: ميل ٠° مقابل الافتراضي؛ U `IdleMapRules.pitch` | ☐ |
| R03 | إضاءة `SandGrade` ومؤثرات `MapVisualsDirector` كما في الملاحة | S: نفس الكاميرا، الخامل مقابل الملاحة | ☐ |
| R04 | مباني ثلاثية الأبعاد وتسميات حادة وطرق Farq | S في مدينة (الرياض) وصحراء | ☐ |
| R05 | حرس البطارية: الطاقة المنخفضة/الحرارة توقف الصور العالية وتخفض الميل، بلا كسر الشاشة | U على `HiResPolicy` موجود + U للميل + S | ☐ |
| R06 | بلا إنترنت: مناطق محفوظة تظهر، وملاحظة صادقة بدل بلاط فارغ | S `-SaryOffline` | ☐ |
| R07 | الأداء: `PerfSignpost launchToMap` لا يسوء بما يتجاوز عتبة يحددها المالك | جهاز حقيقي فقط (**غير مثبت في المحاكي**) | ☐ |

## ٥. المخاطر (وكيف تُحمى)

| المنطقة | الخطر [استنتاج من الكود] | الحماية |
|---|---|---|
| **أوفلاين** | الطبقة العادية تحتاج إنترنت دائمًا، الأقمار/الطبوغرافي تعمل فقط في المناطق المحفوظة (`offlineNote`). فتح الطبقات دائمًا على الخريطة الأولى قد يعرض بلاطًا فارغًا بلا شبكة. الرئيسية تُحمّل اليوم `ArabicBasemap.cachedJSON`. | P26 يمر بلقطة مع `-SaryOffline`؛ الطبقات `needsNetwork` تظهر معطّلة بسبب بالعربي (الوثيقة الأم §٦). لا تغيير في مصدر البلاط في خطوة تكافؤ. |
| **طبقات السحاب/المطر** | تجلب إطارات من API حي، وتزيد الذاكرة/الشبكة إذا فُتحت دائمًا على الشاشة الأولى. `WeatherCardUITests` يعتمد على stub (`-SaryCloudFramesStub`). | الطبقات تبقى **مطفأة افتراضيًا** (المفتاح كما هو)، فلا شبكة جديدة إلا بتشغيل المستخدم. قياس `PerfSignpost` (`launchToMap`) قبل/بعد. |
| **مواقع الكشتة / الدروب** | بيانات محلية ومولّد مسارات ثقيل (`DesertRouter` ٩٥١ سطر). نقل البوابة قد يشغّله مبكرًا. | تبقى كسولة (تحميل عند التشغيل أو فتح الورقة). |
| **جلسة خاملة** | الخريطة الغنية تحتاج `OutingSession`. جلسة خاملة قد تُحسب «طلعة» (`model.session != nil`) فتغيّر `RootView` (الدعوة تُعرض من `LiveSheet` لا من الجذر `RootView:63`)، `outboxNotice`، `offerNotifications`، `ShareMemory`، وPush. | الخطوة EM2 تعرّف الجلسة الخاملة **خارج** `model.session` (مضيف خامل يملك جلسة محلية لا يعلنها)، مع اختبارات: لا تظهر في القوائم، لا إرسال، الدعوة تُعرض مرة واحدة. |
| **الطلعة الفردية** | `openSolo` يغلق الفردية السابقة ويحفظ ملخصها (`soloSnapshots`). اتجه من الوضع الخامل يجب أن ينتقل إلى جلسة فردية فعلية دون هدم الخريطة. | إبقاء `openSolo` كما هو؛ في أول خطوات الانتقال يُهدم المضيف الخامل ويقوم الفردي (كما اليوم)، وحذف الهدم يؤجل لـS17. |
| **CarPlay** | يقرأ `LiveOutingController`/`NavSession` عبر `CarPlayFeatureSource` (`CarPlay/CarPlayWiring.swift:123`). أي نقل لخصائص `exploreActive`/`mapLayer` يكسره بصمت. | `CarPlayWiringTests`, `CarPlayPresenterTests`, `CarPlayManeuverTests` قبل وبعد كل خطوة تلمس المتحكم؛ [كود] CarPlay اليوم لا يشير إلى `exploreActive`. |
| **SOS و«أخفِ موقعي»** | خارج الجلسة الخاملة (محلية، `safetyBackend=nil`) لا SOS سيرفر ولا إخفاء. | يبقى `OutingSession` مقدّسًا؛ لا خطوة تلمسه. `SOSAlwaysUITests`, `HideLocationTests` ضمن الدخان. |
| **الدعوات والروابط** | مساران للدعوة اليوم؛ في الخامل يلزم مسار واحد دون ضياع. | `JoinFlowTests`, `PersonalInvitesUITests` + اختبار «دعوة أثناء الوضع الخامل». |
| **الأداء/الذاكرة/البطارية** | خريطة غنية بصور عالية وميل كأول شاشة = ستايل Farq + مباني + طبقات + نموذج صور عالية. الرئيسية أخف بكثير. حرس: `HiResGate` يوقفها في الطاقة المنخفضة/الحرارة. | `PerfSignpost launchToMap` قبل/بعد على جهاز (لا يُقاس في المحاكي بثقة). **غير مثبت**. |
| **الاختبارات** | ٣٦ بندًا تعتمد على أعلام `-SaryExplore` ومعرّفات `explore.*`. | تبقى المعرّفات حتى آخر خطوة (كما فعل S2-S6)؛ تُنقل الاختبارات لا تُحذف قبل مرور بديلها. |

## ٦. الخطوات المرتبة (PR واحد لكل خطوة، كل واحدة تُشحن لحالها)

كل خطوة: اختبارات وحدة + دخان UI، لقطات محاكي بمتغير واحد، تعليق صادق على الـPR بنتائج مقارنة بـ`docs/TEST-BASELINE.md`. الأعلام: `sary.oneMap` (UserDefaults + `-SaryOneMap` في DEBUG) هو العلم الداخلي من قرار #٤، **مطفأ افتراضيًا** حتى اجتياز القائمة.

| # | الخطوة | يلمس | الإثبات (قبل الحذف) |
|---|---|---|---|
| **EM0** | هذا الـPR: الوثيقة فقط | `docs/EXPLORE-MERGE.md` | مراجعة المالك |
| **EM1** | **الوضع الخامل خلف العلم**: مضيف يعرض خريطة التنقل بدون طلعة (جلسة فردية محلية خاملة بمخزن معزول لا تُعلن في `model.session` ولا تحفظ مسارًا)، **بدقة التنقل (صور عالية + ميل افتراضي + إضاءة)**، قدرات الاستكشاف مفتوحة، ورقة سفلية بمحتوى الرئيسية الأدنى (بحث عبر المكوّن الموجود، طلعاتي، «طلعة جديدة»)، وزر طبقات مشترك. الشرائح وموقعي/البوصلة تُنقل في EM3. `RootView` يختار المضيف الخامل فقط حين العلم مفعّل. القديم هو الافتراضي | جديد `Home/IdleMapHost.swift`, `Home/IdleSheet.swift`؛ تعديل صغير في `RootView`, `LiveOutingController` (علم `idleHome`) | U قواعد نقية + UI `OneMapIdleUITests` + لقطات: الرئيسية القديمة مقابل الخامل (متغير واحد: العلم) — **هذا هو PR المرحلة ٢** |
| EM2 | تثبيت الجلسة الخاملة: لا تظهر كطلعة، لا إرسال، الدعوة مرة واحدة، `openSolo` من الخامل، تمرير أخطاء الشبكة والموقع | `AppModel`+`IdleMapHost` | `ParkedSessionTests`, `JoinFlowTests`, `BackgroundShareTests` + اختبارات خاملة جديدة |
| EM3 | محتوى الرئيسية الكامل (H01-H09: الشرائح العائمة، موقعي/البوصلة، «انضم برابط»، الملف) في الوضع الخامل عبر نماذج بلا واجهة (`HomeMapModel` من S9): شرائح، اختصارات، نتائج، بطاقة مكان (S11)، بطاقات الطلعة | `MapHomeScreen` (استخراج) | `HomeFlowTests`, `HomeFlowUITests`, `BilingualSearch*` |
| EM4 | فك البوابات: استبدال `exploring` بقاعدة قدرات نقية `MapCapabilityRules` (طبقة، ٣D، طقس، سطح الصور، تسميات، مسارات OSM) تُشتق من «واقف/قيادة/توجيه» | `LiveOutingScreen`, `OutingMapboxView` (استدعاءات)، `HiResHosts`, `MotionFX` | U للقاعدة + كل `Layers*UITests`, `HiResImageryUITests`; **S**: الطلعة العادية تعرض الطقس/الكشتة الآن |
| EM5 | نقل أزرار الاستكشاف للمقابض الدائمة: بطاقة الإحداثية (P12) دائمة، شريط الطبقة المصغّر، أماكني/درون/واقعي (قرار المالك على P16) | `ExploreViews`, `LiveOutingScreen`, `SaryMapControls` | `ExploreUITests`, `ScreensUITests`, `LiveCalmTests` المعدّلة، `OverlapUITests` (S13) |
| EM6 | ورقة «البر» الموحدة (طقس، قبلة، كشتة، دروب، أماكني) تحل محل `HomeTool.menu` وصف `explore` في «أدوات» | `HomeTools`, `LiveActionSheet`, `LiveSheet` | `CampSitesUITests`, `DesertGazetteerUITests`, `ReachabilityUITests` |
| EM7 | **التحويل**: العلم يصير مفعّلًا افتراضيًا في الداخلي، `RootView` يفتح الخريطة الغنية أولًا، `PlanMapView` تبقى للمعاينات فقط | `RootView`, `HomeView` | قائمة التكافؤ §٤ **١٠٠٪ ✓** على اللقطات + الحزمة الكاملة ليلًا + مراجعة المالك على TestFlight الداخلي |
| EM8 | **إزالة الاستكشاف**: حذف مدخل `explore`، `enterExplore/exitExplore/exploreAuto/autoEnter`، `ExploreTopBar`، `ExploreHeader/Readout/LayerSections/ExploreLayersSheet` الميتة، ما صار بلا مستدعٍ؛ وهجرة/حذف `ExploreUITests` وأعلام `-SaryExplore*` وإعادة تسمية المعرّفات `explore.*` | `Explore/*`, `LiveOutingController*`, اختبارات | قائمة التكافؤ ما زالت ١٠٠٪؛ الدخان + الحزمة الكاملة؛ **PR منفصل لا يخلط ميزة** |
| EM9 | حذف `PlanMapView` كخريطة رئيسية و`MapHomeScreen` القديمة بعد استقرار بناءين | حسب S19 | الحزمة الكاملة ليلًا |

الأولوية والمخاطر: EM1 الأقل خطرًا (علم مطفأ، لا يغيّر مسار المستخدم الحالي)، EM4 هو الأحساس (يغيّر ما تعرضه الطلعة العادية) فيُدمج بعد ثبات الخامل.

## ٧. خرائط الاختبارات (ما يُهاجَر)

| الملف | ما يغطي | مصيره |
|---|---|---|
| `UITests/ExploreUITests.swift` (٦) | دخول/خروج، طبقات، طقس، حفظ مكان، مسارات وتضاريس، طبوغرافي | تُعاد كتابة الدخول/الخروج (P01/P03)، والبقية تنتقل بمعرّفاتها إلى الوضعين EM5 |
| `UITests/ScreensUITests.swift` `ExploreTapsUITests` | كل أزرار الاستكشاف تستجيب | تُنقل بعد EM5 |
| `UITests/CampSitesUITests.swift` (٧) / `Tests/CampSitesTests` | الكشتة | تمر كما هي على الوضعين EM6 |
| `UITests/LayersToggleUITests.swift` (٣) / `LayersSheetUITests` / `LayersButtonUITests` / `LayersShotsUITests` | الورقة المشتركة | تمر كما هي؛ تعتمد على `-SaryExplore` فتُحدَّث في EM8 |
| `UITests/VisualsUITests.swift` | درون، لقطات، واقعي المدينة | EM4/EM5 |
| `UITests/RealisticUITests.swift` (٦) | واقعي من الاستكشاف/النقطة/الأماكن/المسار | EM5 |
| `UITests/HiResImageryUITests.swift` | شارة الصور (فيه فاشل معروف) | EM4 |
| `UITests/ReachabilityUITests.swift` | وصول الأدوات خلال نقرتين (فيه فاشل معروف) | EM5/EM6 |
| `UITests/HomeFlowUITests.swift` | زر الطبقات في الرئيسية | يبقى ويتسع للخامل |
| `Tests/ExploreTests.swift` (٧) | قواعد نقية: بعد ٥ كم، الارتفاع، الصيغ، الملاحظات، الأماكن، المسارات | تبقى (القواعد ما زالت مستعملة) ما عدا `farFromGroup` حسب P02 |
| `Tests/LiveCalmTests`, `DeclutterTests`, `LiveDeclutterTests`, `MapLayer*Tests`, `RealisticTests` | إشارات لـ`exploring` | تُحدَّث مع EM4/EM5 |

## ٨. حدود هذا الجرد (أمانة)
- مبني على قراءة الكود، لا على تجربة جهاز. لم أشغّل الاختبارات في هذه المرحلة (وثيقة).
- افتراض «الجلسة الخاملة المحلية لا تظهر كطلعة» **غير مثبت** [استنتاج]؛ هو شرط EM2 ومخاطرته مدرجة.
- لم أقِس الأداء ولا الذاكرة للخريطة الغنية كشاشة أولى.
- لم أراجع `Widgets/` و`ShareExtension/`.
- الفاشلة المعروفة من `docs/TEST-BASELINE.md` (القبلة بإذن الموقع، `HiResImageryUITests.testBadgeInExplorationThenActiveNavigation`، القافلة، `DesertGazetteerUITests.testNufudChip…`، أذونات الموقع) تمس بنودًا هنا (P23, P24, P11)؛ لا تُحسب خضراء إلا بعد إصلاحها أو إثبات يدوي بلقطة.
