# توحيد الأسطح: جرد كل بطاقة وتنبيه وورقة، وتصميم «سطح واحد لكل مجال»

المرحلة ١ (جرد وتصميم فقط، **ما تغيّر أي ملف Swift في هذا الـPR**). المصدر: `origin/main` عند `73bbb951`.
المسارات نسبتها إلى `apps/ios/SaryAlbarq/Sources/` إلا إذا ذُكر غير ذلك. أرقام الأسطر تقريبية (±٥) وتتحرك مع كل PR.
اللغة: عربي، وأسماء الكود بالإنجليزي. **[كود]** = قرأته في الملف. **[استنتاج]** = تحليلي، ما جرّبته على جوال حقيقي.

طلب المالك (بصيغته): «وحّد كل شيء الآن. وحّد الطقس وأي شيء يخص الطقس صفحته، لا يطلع لي بطايق ثانية. وحّد التوجيه والإشارات، وحّد كل شيء. أبغى أشياء تتوحد مع بعض، ما أبغى تكرار.»

القيود الباقية من الوثيقتين السابقتين (`ONE-MAP-UNIFICATION.md` §١١ و`EXPLORE-MERGE.md` §١): (١) تدريجي لا إعادة كتابة، (٢) اختبارات قبل وبعد، (٣) لا حذف قبل إثبات البديل بلقطة، (٤) PR واحد لكل خطوة، (٥) لا خريطة جديدة ولا منتقي طبقات جديد ولا منطق أعمال في ملفات الواجهة؛ وقاعدة إثبات المظهر: لا نقول «يعمل» دون لقطة بكسل من المحاكي، ومتغير واحد في كل مقارنة.

---

## ١. الخلاصة

| المجال | أسطح ظاهرة للمستخدم اليوم | تكرارات مكتشفة | الهدف |
|---|---|---|---|
| الطقس | ١٦ سطحًا في ٩ ملفات | **١٠** | صفحة واحدة + شريحة حالة واحدة على الخريطة |
| التوجيه | ٣٦ سطحًا (بدون CarPlay) | **١٨** | شريط علوي واحد + شريط سفلي واحد |
| الإشارات والتنبيهات | ٣٥ سطحًا و**٩ آليات** عرض رسائل مؤقتة | **٢٠** | مركز تنبيهات واحد (صف واحد + صندوق وارد) |
| الأماكن | ١٢ | **٥** | بطاقة مكان واحدة |
| الناس | ١٥ | **٤** | لوحة مجموعة واحدة |
| الأدوات والإعدادات | ١٤ | **٦** | قائمة «المزيد» واحدة + ورقة طبقات واحدة |
| **المجموع** | | **٦٣ تكرارًا** | |

اكتشافات مهمة تغيّر الخطة:
- **لا يوجد في الكود أي سطح لكاميرات ساهر أو الخطر أو تحذير البطارية** على `main` [كود: بحث عن ساهر/saher/hazard/battery]. كاميرات ساهر في PR #122 (مفتوح). لذلك مركز التنبيهات يجب أن يستقبلها كنوع جديد (`camera`) بدل أن تضيف سطحًا رابعًا.
- التنبيه المؤقت (`toast`) **لا يدخل سجل الجرس** [كود `Live/AlertQueue.swift:75` يرجع nil للـ`.toast`]، بينما تعليق في `Views/LiveOutingScreen.swift:729` يقول إنه «في السجل». فتنبيه تجاوز السرعة ورسائل «نكمل لما يرجع النت» تضيع بلا أثر أثناء القيادة مع وجود بطاقة.
- `pushAlert` قد يطرد تنبيهًا عالي الأولوية: يضيف في الفهرس ٠ ويقصّ المصفوفة إلى ٦ من الذيل بغض النظر عن الأولوية [كود `Live/LiveOutingController.swift:925-932`]. فيض من الـtoasts يطرد بطاقة «مغرّز» أو «صامت».
- كود ميت: `LiveWeatherCard` (`Weather/WeatherViews.swift:382`) و`TripPeekStrip` (`Views/TripViews.swift:28`) لا يستدعيهما أحد؛ `.drift` في `AlertQueue.swift:23` بلا منتج [استنتاج: لم أبحث كل بناء `drift(`].

---

## ٢. جرد الطقس (٢.١ ما هو موجود)

| # | السطح | النوع والملف:السطر | الشرط (متى يظهر) | أين يظهر | من يكرره |
|---|---|---|---|---|---|
| W1 | **بطاقة السحاب على الخريطة** (شريط / موسّعة / زر استرجاع) | `WeatherLegendCard`، `Weather/WeatherOverlay.swift:640`، يُركَّب كـUIHostingController فوق `MapView` (`WeatherOverlay.swift:100`) ويُوضع في `layoutLegend()` (`:561`) | `effectiveKind != .none` (الطبقة شغّالة، وتُفتح بوابتها بالاستكشاف) | أعلى الخريطة، تحت الرأس | W6 (نفس اختيار الطبقة)، W11 |
| W2 | حالة البطاقة (٣ أوضاع) محفوظة | `WeatherCardMode`، `WeatherOverlay.swift:589`، مفتاح `sary.map.weather.card.v1` | دائمًا | – | – |
| W3 | تحكم تشغيل/إيقاف حركة السحاب + شريط الزمن + عمر الصورة | داخل W1 (`:690`، `:733`) | `kind == .clouds` | داخل W1 | – |
| W4 | مفتاح الألوان (legend) + سطر المصدر | داخل W1 (`:748-790`) | الطبقة شغّالة | داخل W1 | `WeatherLayersSection.footer` (نفس نص المصدر) |
| W5 | **سطر الاتجاه/الوصول** «السحاب يتجه…» (CloudOutlook) | `CloudOutlookRow`، `WeatherOverlay.swift:831`، يغذّيه `CloudOutlookPresenter` (`Weather/CloudOutlook.swift:60`) | `outlook != nil` (ثقة كافية) | داخل W1 الموسّعة فقط | **يختفي حين تُخفى البطاقة** رغم أن الطبقة شغّالة |
| W6 | **منتقي الطقس على الخريطة** «بدون / السحاب الآن / وين نزل مطر / وين ربّع / رياح» + فترة المطر (١/٣/٧) | ثلاث نسخ: (أ) `MapLayersSheet` مجموعة «الطقس» (`Map/Layers/MapLayersSheet.swift:136-151`)، (ب) `WeatherLayersSection` (`Weather/WeatherLayersSection.swift:5`)، (ج) `ExploreLayersSheet` القديمة التي تستدعي (ب) (`Explore/ExploreViews.swift:249`) | زر الطبقات | ورقة الطبقات | بعضها بعضًا |
| W7 | **خطوط حركة السحاب** على الخريطة | `CloudFlowHost`/`CloudFlowView`، `Weather/CloudFlow.swift:85` | `legend.flow != nil` | فوق الخريطة، لا تلتقط لمسًا | – (طبقة رسم، تبقى) |
| W8 | **شريحة الطقس في رأس الرحلة** (درجة + رمز + المكان + عمر) | `WeatherChipView`، `Weather/WeatherChip.swift:99`؛ `LiveWeatherChip` (`:150`) غير مستعملة؛ الاستعمال الحقيقي داخل `TripHeader` (`Views/TripHeader.swift:176`, id `weather.chip`) | `weather.phase != .unavailable` | رأس الرحلة | W1 (شريحتان للطقس على نفس الشاشة) |
| W9 | **ورقة الطقس الكاملة**: بطاقة الوجهة 24 س، بطاقة الوصول + الانطلاق، بطاقة المنطقة، السيول والأودية، رابط المركز الوطني، خصوصية Open-Meteo | `WeatherSheet`، `Weather/WeatherViews.swift:218`؛ تُفتح بـ`controller.modal = .weather` (`Views/LiveSheet.swift:183`) ومن `DetailsWeatherSection` (`:435`) | شريحة W8، بلاطة «الطقس» في «+» (`Views/LiveActionSheet.swift:135`, `Live/LiveOutingController+Declutter.swift:283`)، «البر» في الصف السريع (`Views/LiveSheet.swift:350`)، تنبيه الطقس عند النقر (`LiveOutingController.swift:994`)، `-SaryLiveModal weather` | الجميع يفتح هذه |
| W10 | **ورقة «الطقس هنا»** لنقطة | `WeatherPointSheet`، `WeatherViews.swift:351`؛ `modal = .weatherAt` (`LiveSheet.swift:192`) و`HomeToolSheet` (`Home/HomeTools.swift:145`) | زر «الجو هناك» في بطاقة المكان (`Home/MapHomeScreen.swift:975`)، قائمة «البر» (`HomeTools.swift:83`) | ورقة ثانية بنفس البطاقة ونفس رابط المركز الوطني ونص الخصوصية | W9 (ورقتان للطقس بتصميم متشابه ومداخل مختلفة) |
| W11 | **بطاقة الطقس** (الدرجة، الحقائق، شريط الساعات، الذيل) | `WeatherCardView`، `WeatherViews.swift:34`، تُستعمل في ٥ أماكن: `WeatherSheet` ×٣ (`:236,239,241`)، `WeatherPointSheet` (`:362`)، `LiveWeatherCard` ×٢ (`:390,392`، ميت)، `DetailsWeatherSection` ×٢ (`:424,429`)، `CreateOutingWizard` (`Create/CreateOutingWizard.swift:680`) | – | – | نفس المكوّن، لكن تفتح كل منها شيئًا مختلفًا عند النقر |
| W12 | **قسم الطقس في تفاصيل الطلعة** (بطاقة + شريط «الوجهة على هذا الجوال فقط» + ورقة W9) | `DetailsWeatherSection`، `WeatherViews.swift:402`؛ `Screens/OutingDetailsView.swift:69` | شاشة التفاصيل | شاشة التفاصيل | W9 |
| W13 | **طقس الوجهة في معالج «طلعة جديدة»** (بطاقة + بطاقة وصول + تنبيهات كلافتة) | `CreateOutingWizard.swift:678-690` | خطوة الوجهة | المعالج | W9 (بطاقة وصول ثانية تحسب الوصول) |
| W14 | **أيقونة+درجة صغيرة لوجهة الطلعة** | `DestinationWeatherBadge`، `WeatherChip.swift:163`؛ `Screens/HomeView.swift:161`، `Home/MapHomeScreen.swift:977` | صف طلعة / بطاقة مكان | القوائم | W8 (نفس القراءة بمصدر طقس مستقل `WeatherStore`) |
| W15 | **بطاقة تنبيه الطقس** (رياح، غبار، مطر، سيل) في حارة التنبيهات | `.weather` من `OutingWeather.onAlert` (`LiveOutingController.swift:359`)؛ `WeatherAlertLeading` (`WeatherViews.swift:190`) في `SaryAlertLane.swift:170` | تقييم `WeatherAlerts.evaluate` + بوابة المعدّل | حارة التنبيهات | علامة التحذير في W8، وبطاقات W9 |
| W16 | **طقس المكان في بريف المكان** | `PlaceBriefSection`، `Plan/PlaceBriefView.swift:14` (يغذّيه `PlaceBriefModel`، `Weather/PlaceBriefStore.swift:103`) | داخل `PointCard` (`:135`) و`LivePlan.swift:108` | بطاقة النقطة | W10 و W14 (ثلاثة مسارات جلب لطقس نقطة) |
| W17 | **أقرب محطات** | `NearestStationsView`، `LiveSheet.swift:994` | `modal = .stations` | ورقة | – (ليست طقسًا، لكنها تُفتح من مسار الطقس؛ تُبقى) |

### ٢.٢ تكرارات الطقس (١٠)
1. **ثلاثة منتقين لنفس الطبقة**: W6 أ/ب/ج.
2. **ورقتان للطقس** W9/W10 بنفس البطاقة ونفس رابط المركز الوطني (`WeatherViews.swift:329` و`:373`) ونفس نص خصوصية Open-Meteo.
3. **خمسة مداخل لـW9 وثلاثة لـW10** (راجع الأعمدة)، وبلاطتان بنفس المعنى في «+» وفي الصف السريع.
4. **شريحتان للطقس على شاشة واحدة**: W8 في الرأس وشريط W1 على الخريطة.
5. **`WeatherCardView` في ٥ مضيفات**، ولكل مضيف نقرة مختلفة (`tap`).
6. **ثلاثة مسارات لجلب طقس نقطة**: `OutingWeather` (الطلعة)، `WeatherStore` (W10/W14)، `PlaceBriefModel` (W16).
7. **بطاقة الوصول** في W9 (`arrivalCard`) وفي W13 (`CreateOutingWizard.arrivalCard`).
8. **سطر الاتجاه W5 حبيس W1**: إذا أخفيت البطاقة تفقد معلومة الاتجاه رغم أن الطقس ما زال ظاهرًا.
9. **كود ميت**: `LiveWeatherCard` و`LiveWeatherChip`.
10. **تنبيه الطقس W15 + علامة الشريحة + بطاقات الورقة**: ثلاث طرق لإخبار المستخدم بنفس التحذير.

### ٢.٣ تصميم الطقس الموحَّد
**صفحة الطقس** (`WeatherPage`): ورقة واحدة (sheet) تفتح من **شريحة حالة واحدة** على الخريطة. لا بطاقة طقس أخرى تطلع على الخريطة أو في ورقة أخرى.

```
شريحة الحالة على الخريطة (واحدة)          صفحة الطقس (ورقة واحدة، ثلاث تبويبات داخلية = أقسام قابلة للتمرير)
  ┌────────────────────────┐                ┌───────────────────────────────────────────┐
  │ ☁︎ ٣٢° منطقة الطلعة   ⚠︎│  ← tap  ──▶    │ الطقس                           [حدّث] [خلاص]│
  │ أو: ☁︎ السحاب الآن ١٢:٤٠ │                │ ١ الآن: النقطة المختارة / الوجهة / منطقتي │
  └────────────────────────┘                │   (بطاقة واحدة + ساعات + وصول/انطلاق)       │
                                            │ ٢ الخريطة: [بدون|سحاب|مطر|رياح|ربيع] + فترة │
                                            │   المطر + ▶︎/⏸ + شريط الزمن + مفتاح الألوان │
                                            │   + اتجاه حركة السحاب والوصول (CloudOutlook)│
                                            │ ٣ تحذيرات: سيول/أودية + تنبيهات الطقس       │
                                            │   + رابط المركز الوطني + المصدر والخصوصية  │
                                            └───────────────────────────────────────────┘
```
- **الشريحة**: تعرض درجة المكان الحالي (W8) وتتحول عند تفعيل طبقة إلى «اسم الطبقة · الوقت/العمر» مع سهم الاتجاه (محتوى W1 المصغّر) وعلامة ⚠︎ إن وُجد تنبيه. نقرها تفتح الصفحة. **لا أزرار تشغيل ولا بطاقات** على الخريطة. خطوط حركة السحاب (W7) تبقى لأنها رسم الخريطة نفسه.
- **مصدر النقطة**: النقطة المختارة على الخريطة (بطاقة مكان / `PointCard`) ← الوجهة ← منطقة الطلعة ← موقعي. «الجو هناك» و`WeatherPointSheet` تصير **فتح الصفحة على تلك النقطة** (`WeatherPage(point:)`).
- **مدخل واحد**: الشريحة. بلاطة «الطقس» في «+» وفي «البر» وتنبيه الطقس و«الجو هناك» وقسم التفاصيل: كلها تستدعي `WeatherPage` نفسها (نفس `modal`)، لا ورقة ثانية.
- **ورقة الطبقات**: صف واحد «الطقس» يعرض الحالة (مثلًا «سحاب») ويفتح الصفحة، بدل المجموعة المكررة (يُنفَّذ في خطوة لاحقة W3 بعد إثبات التكافؤ؛ المعرّفات `weather.layer.*` تنتقل للصفحة كما هي حتى لا ينكسر أي اختبار).
- **التنبيهات**: بطاقة تنبيه الطقس (W15) تبقى لحظية في مركز التنبيهات (§٤) وتفتح الصفحة، ولا تكرر محتواها.
- **كاش الأمان**: قاعدة «غياب التنبيه ليس أمانًا» (نص السيول) تبقى حرفيًا في قسم ٣.

---

## ٣. جرد التوجيه (٣.١ ما هو موجود)

مصطلحات الشرط: `nav` = `controller.nav` (`NavSession`، `phase`: idle/planning/guiding/offRoad/arrived). `guidingHUD` = `nav.phase == .guiding && !exploring && !ended` (`Views/LiveOutingScreen.swift:246`، **لا يشمل `.offRoad`**). `bannerOnly` = `driving && (guidance || backTrackUI || followUI)` (`:614`).

### أ. المكدّس العلوي (`LiveTopStack`، `LiveOutingScreen.swift:587`)
| # | السطح | الملف:السطر | الشرط | من يكرره |
|---|---|---|---|---|
| G1 | شريط المناورة | `NavManeuverBanner`، `Navigation/NavGuidanceViews.swift:176` | `phase == .guiding` | PiP (`NavPictureInPicture.swift:63`)، Live Activity (`NavSession.swift:1027`)، CarPlay، `NavStepsSheet` (`:839`) |
| G2 | حالة إعادة الحساب داخل الشريط | `NavGuidanceViews.swift:198` | `nav.rerouting` | toast «مسار جديد» (`NavSession.swift:760`)، رسالة الفشل (`:767`)، Live Activity (`:1030`)، CarPlay (`CarPlayCoordinator.swift:718` بنص مختلف «نحسب طريق ثاني…») |
| G3 | صف «ثم» للمناورة التالية | `nextRow`، `:330` | `nextStep` | CarPlay `upcomingManeuvers` |
| G4 | مسارات الحارات | `NavLanesView`، `:416` | `lanes` غير فارغ و`distance < 1500` | CarPlay `CPLaneGuidance` |
| G5 | شريط كم الأسطح «زفلت ← ترابي ← بر» | `NavSurfaceKmStrip`، `NavOptionsSheet.swift:404`؛ يُستدعى `NavGuidanceViews.swift:274` | `remainingSurfaces` | `NavETARow` (`:398`) وبطاقة المسار (`NavOptionsSheet.swift:149`) ومفتاح `NavSurfaceLegend` (`:265`) |
| G6 | زر PiP | `NavGuidanceViews.swift:287` | دائمًا في الشريط | – |
| G7 | زر «حدّث موقع العضو» | `LiveOutingScreen.swift:802` | هدف عضو تحرّك | – |
| G8 | لوحة خارج الطريق «مافي طريق مزفلت: كمّل مع السهم» | `NavOffRoadPanel`، `:466`؛ استدعاؤها `LiveOutingScreen.swift:815` | `phase == .offRoad` ولا يُتبع مسار الخطة | ملاحظة ورقة المسارات (`NavOptionsSheet.swift:107,170`)، Live Activity (`NavSession.swift:1036`)، CarPlay (`CarPlayPresenter.swift:~348` بنص منفصل) |
| G9 | بوصلة الوجهة (البلاطة البرتقالية) | داخل G8، `:480`؛ `NavOffRoad.arrowDegrees` | `.offRoad` | سهم `FollowTrackPanel`/`BackTrackPanel` |
| G10 | صف ETA خارج الطريق | `NavETARow`، `:353` | `.offRoad` | `NavBottomBar.numbers` (`:628`) |
| G11 | لوحة اتبع المسار (بديل G8) | `FollowTrackPanel`، `Views/TrackViews.swift:161` | `.offRoad && followUI` | نفس اللوحة في `TrackFollowScreen` وفي الطلعة |
| G12 | بطاقة الوصول «وصلنا» | `NavArrivalCard`، `:522` | `phase == .arrived` | فرع `.arrived` في `NavBottomBar` (`:597`)، toast «وصلنا X» (`Live/LiveOutingController+Trip.swift:284`)، CTA «وصلنا» (`Core/OutingFlow.swift:188`)، سطر الرأس (`Views/TripHeader.swift:28`)، تنبيه CarPlay (`CarPlayCoordinator.swift:764`) |
| G13 | «ننتظر موقعك…» | `NavFixWaitRow`، `Navigation/LiveOutingController+FixWait.swift:110` | `fixWait != nil` | سطر الرأس (`TripHeader.swift:25`)، `StandaloneNavScreen.status` |
| G14 | سؤال «ابدأ التوجيه / استأنف» | `GuidancePromptRow`، `NavGuidanceViews.swift:931` | `guidancePrompt != nil` | `OutingCTA.resumeGuidance`، toast «أمير الطلعة بدأ التوجيه» (`LiveOutingController+AutoNav.swift:137`)، `NavStartChoiceSheet` (`:880`) |
| G15 | «طريق العودة» | `BackTrackPanel`، `LiveOutingScreen.swift:829` | `backTrackUI != nil` | CarPlay `.wayBack` |
| G16 | رأس الرحلة | `TripHeader`، `Views/TripHeader.swift:75` | `!exploring && !ended && !bannerOnly` | الشريط والشريط السفلي: السطر «إلى X · باقي · نوصل» يكرر الأرقام؛ عند رفع الورقة أثناء التوجيه يصير السياق `.stopped` فيظهر الرأس مع الشريط معًا |
| G17 | مؤشر «رجّعني للتوجيه» | `RecenterPill`، `LiveOutingScreen.swift:1086` | `recenterOffered` ونمط حرّ | بلاطة «رجّعني لسيارتي» (`NavGuidanceViews.swift:765`) وزر الكاميرا الجانبي (`FollowCamera.swift:21`) |
| G18 | أسهم الحواف | `EdgeArrowLayer`، `:1028` | أعضاء خارج الشاشة | – (أعضاء لا وجهة) |

### ب. الشريط السفلي والجانب
| # | السطح | الملف:السطر | الشرط | من يكرره |
|---|---|---|---|---|
| G19 | عنقود السرعة + حد السرعة | `NavSpeedCluster`، `NavGuidanceViews.swift:798`؛ `LiveOutingScreen.swift:421` | `guidingHUD && speed.everRead` | `LovableSpeedBubble` (`Views/LiveCalmChrome.swift:187`) |
| G20 | علامة حد السرعة وحدها | `NavSpeedLimitSign`، `:441`؛ `LiveOutingScreen.swift:431` | `guidingHUD && !everRead && limit != nil` | الحد داخل G19 (`:830`) وتنبيه التجاوز (`+Speed.swift:30`) |
| G21 | فقاعة السرعة العادية | `LovableSpeedBubble` | `driving && !guidingHUD` (فتعود في `.offRoad` وتفقد علامة الحد) | G19 |
| G22 | شريط القافلة | `ConvoyLinePill`، `LiveCalmChrome.swift:223` | `driving && nav.isActive` | صفوف المشاركين |
| G23 | الشريط السفلي (ETA، المسافة، «أوقف التوجيه»، «المزيد») | `NavBottomBar`، `NavGuidanceViews.swift:581`؛ `Views/LiveSheet.swift:26` | `nav.isActive` | سطر الرأس G16، Live Activity، `NavETARow` G10 |
| G24 | ملاحظة «الوجهة قديمة» | `NavBottomBar.numbers :659`، `NavOptionsSheet.swift:21`، `NavMapLayer.swift:~565` | `staleNote` | ثلاثة أماكن |
| G25 | بلاطات خيارات الرحلة + مشاركة ETA | `NavTripOptions`، `:730` | `isActive && detent != .peek` | زر الكاميرا |
| G26 | ورقة الخطوات | `NavStepsSheet`، `:839` | زر أو فتح تلقائي (`LiveOutingController+Nav.swift:439`) | الشريط و«ثم» |
| G27 | زر CTA الرئيسي «وين رايحين؟/وصلنا/استأنف» | `OutingPrimaryCTA`، `Views/OutingFlowViews.swift:8` | `flow.primary != nil` | G14، G12 |
| G28 | أزرار جانبية أثناء التوجيه | `navSideItems`، `LiveOutingController+Nav.swift:316` | `guidingHUD && peek` | `navControlItems` (`:329`) قائمة ثانية |

### ج. قبل التوجيه
| # | السطح | الملف:السطر | من يكرره |
|---|---|---|---|
| G29 | منتقي الهدف «إلى أين؟» | `NavTargetPicker`، `NavOptionsSheet.swift:191` | `WhereToSheet` (`Views/OutingFlowViews.swift:90`) |
| G30 | ورقة المسارات وبطاقاتها | `NavOptionsSheet`، `:5` (`routeRow` ~`:127`) | ملصقات زمن المسار على الخريطة `NavRouteLabel` (`NavMapLayer.swift:587`)، معاينة CarPlay |
| G31 | مفتاح «نوع الطريق» | `NavSurfaceLegend`، `:265` | شريط G5 |
| G32 | رسائل هجين/مباشر | `SaryInlineMessage` في `NavOptionsSheet.swift:107,120` | G8 |
| G33 | حالة التحميل والخطأ | `NavOptionsSheet.swift:95,100` | `StandaloneNavScreen.status` |
| G34 | «ابدأ للكل / لي فقط / لاحقًا» | `NavStartChoiceSheet`، `:880` | G14 |

### د. الشاشات المستقلة
| # | السطح | الملف:السطر | الحالة |
|---|---|---|---|
| G35 | `StandaloneNavScreen` | `Navigation/StandaloneNavScreen.swift:130` | خلف علم DEBUG `-SaryStandaloneNav` (`Home/HomeTools.swift:28`)؛ تعيد استعمال G1/G8/G12/G23/G19 وتضيف toast وبطاقة حالة وبطاقة إذن خاصة |
| G36 | `TrackFollowScreen` | `Views/TrackFollowScreen.swift:7` | لوحة G11 + حارة تنبيه وtoast خاصان |
| – | CarPlay (مناورة، تقديرات، معاينة، إعادة حساب، وصول، تنبيهات) | `CarPlay/CarPlayCoordinator.swift:632-782` | يقرأ `NavSession`، لا يُلمس (قاعدة السلامة) |
| – | `TripPeekStrip` | `Views/TripViews.swift:28` | **ميت** |

### ٣.٢ تكرارات التوجيه (١٨): راجع عمود «من يكرره»؛ أهمها
١) سطر الرأس يكرر الشريط (ETA والمسافة). ٢) الوصول بخمس طرق. ٣) شريط كم الأسطح بثلاثة أشكال. ٤) السرعة بأداتين تتبادلان حسب `guidingHUD` فتختفي علامة الحد في `.offRoad`. ٥) الحد بثلاث صيغ. ٦) تنبيه خارج الطريق بأربعة أماكن بنصوص مختلفة. ٧) إعادة الحساب بأربعة. ٨) بدء/استئناف التوجيه بثلاثة. ٩) «رجّعني للتوجيه» بثلاثة. ١٠) نص المناورة بخمسة. ١١) ملاحظة الوجهة القديمة بثلاثة. ١٢) أزمنة المسارات بمكانين. ١٣) «ننتظر موقعك» بثلاثة. ١٤) منتقيا الوجهة. ١٥) `StandaloneNavScreen`. ١٦) لوحة المسار بثلاثة مضيفات. ١٧) `TripPeekStrip` ميت. ١٨) تداخل قنوات toast والبطاقة.

### ٣.٣ تصميم التوجيه الموحَّد
**مبدأ**: التوجيه له **شريطان فقط**: شريط علوي واحد وشريط سفلي واحد. أي حالة جديدة تُرسم **داخلهما** كحالة، لا كبطاقة عائمة.

| الحالة | أين تظهر | كيف |
|---|---|---|
| مناورة (G1،G3،G4) | الشريط العلوي | كما هو؛ الحارات وصف «ثم» أقسام داخله |
| سرعة وحد السرعة (G19-G21) | الشريط السفلي (طرف) | أداة واحدة `GuidanceSpeed` تعمل في `.guiding` و`.offRoad` |
| إعادة حساب (G2) | الشريط العلوي | حالة داخل الشريط؛ لا toast مستقل (يدخل مركز التنبيهات فقط عند الفشل) |
| خارج الطريق/هجين (G8-G10،G32) | الشريط العلوي: يتحول لنفس الشريط بسهم الوجهة والسطر الواحد | نص واحد من `NavOffRoad`، تستهلكه الواجهة وCarPlay وLive Activity |
| كم الأسطح (G5،G31) | الشريط السفلي، سطر ثابت واحد | تُحذف نسخة الشريط العلوي و`NavETARow` |
| ETA والمسافة (G23،G10،G16) | الشريط السفلي فقط | الرأس يختفي كلما `nav.isActive` (حتى مع رفع الورقة) |
| وصول (G12) | الشريط السفلي ينقلب إلى «وصلنا» | تُحذف البطاقة العلوية وtoast والسطر المكرر؛ يبقى CTA واحد |
| «رجّعني للتوجيه» (G17) | زر واحد (زر الكاميرا الجانبي يتحول) | يُحذف المؤشر العائم والبلاطة |
| بدء/استئناف (G14،G34) | الشريط العلوي (حالة «قبل التوجيه») | CTA الدور الرئيسي يُحذف حين يوجد السؤال |
| طريق العودة/اتبع المسار (G11،G15،G36) | الشريط العلوي (حالة) | مضيف واحد بدل ثلاثة |
| ورقة المسارات والمنتقي (G29-G30،G33) | ورقة واحدة «إلى أين؟ + المسارات» | تدمج `WhereToSheet` و`NavTargetPicker` |

**CarPlay يبقى** لأنه سطح السيارة، لكنه يقرأ النصوص من نفس مصدر الحقيقة.

**تعارض مع عمل جارٍ**: PR #230 (`drive-v2`: بطاقة مناورة كبيرة، شريط توجيه واحد) و#225 (بوصلة الوجهة + كم الأسطح) و#227 (Home V2) مفتوحة وتلمس نفس الملفات. **خطوات التوجيه (G) تبدأ بعد دمجها**، ولا نكتب فوقها. ما قبل ذلك: الطقس والتنبيهات فقط.

---

## ٤. جرد الإشارات والتنبيهات «الإشارات»

### ٤.١ آليات عرض الرسائل المؤقتة (٩)
| # | الآلية | التعريف | عدد الاستدعاءات | عبر `AlertQueue`؟ |
|---|---|---|---|---|
| M1 | بطاقات `pushAlert` ← `AlertQueue` ← `SaryAlertLane`/`SaryAlertCard` (note, drift, voice, toast, safety, convoy, weather, silent, offTrack) | `Live/LiveOutingController.swift:925`، `UI/Components/SaryAlertLane.swift:7,100` | ~١٧ + `upsertAlert` (`Safety/LiveOutingController+Safety.swift:76`) | نعم |
| M2 | toast الحارة (كبسولة ٢٫٥ ث) | `LiveOutingController.swift:937`، يُرسم `LiveOutingScreen.swift:728` | **~١١٧** `toast(` في ٣٠ ملفًا | لا (يُصفّى `AlertQueue.swift:37,64`) ويشارك المصفوفة ذات الستة خانات |
| M3 | `SaryToast` | `Screens/ScreenKit.swift:243` | ٣: `Plan/PointCard.swift:76`، `Plan/PlanEditorView.swift:50`، `Story/StoryComposerView.swift:75` | لا |
| M4 | toast `StandaloneNavScreen` | `StandaloneNavScreen.swift:138,166,386` | ١ (DEBUG) | لا |
| M5 | مصفوفة `alerts` محلية في `TrackFollowScreen` | `Views/TrackFollowScreen.swift:46,121,123` | ٢ | عرض فقط |
| M6 | `SaryBanner` (شريط ملوّن) | `UI/Components/SaryStates.swift:119` | **٤١** في ~٢٢ ملفًا | لا |
| M7 | `SaryInlineMessage` | `UI/Components/SaryInputs.swift:76` | **٤٣** | لا |
| M8 | `notice` داخل النماذج بمؤقتات مستقلة (`MediaCenter` ١٥ ث، `OutingWalkieTalkie` ٢٫٥ ث، `VoiceNoteCenter` ٢٫٥ ث، `ChatStore`) | `Media/MediaCenter.swift:54,313`، `PTT/OutingWalkieTalkie.swift:33,616`، `VoiceNotes/VoiceNoteCenter.swift:84,453`، `Chat/ChatStore.swift:88` | ٤ خصائص | الوسائط فقط تُعدّ على الجرس |
| M9 | شريط صندوق الصادر الجذري + toast نفس المعنى | `Views/RootView.swift:58`، `App/AppModel.swift:703` مقابل `Core/PendingActionQueue.swift:463,470` ← `OutingSession.swift:1261` | ١ + ١ | لا |
| + | حوارات النظام | `.alert` ×١٣، `confirmationDialog` ×١٧ | ٣٠ | لا (تبقى) |

غير بصرية: لمسات (~٦٥ موضعًا، البوابة `SaryHaptics.allows` `UI/DesignSystem/SaryTokens.swift:582`، وبعضها يتجاوزها مباشرة `+Speed.swift:28`، `+ConvoyIntel.swift:56`)، صوت (`NavVoice`)، إشعارات محلية (`Notifier.post` `App/OutingSession.swift:1607`, `HideReminder`, `LocalReminderScheduler`).

### ٤.٢ جرد الإشارات
| # | الإشارة | الملف:السطر | الشرط | الأولوية | من يكررها |
|---|---|---|---|---|---|
| A1 | SOS صديق (شاشة كاملة) | `Views/SOSOverlay.swift:161` + `UI/Components/SarySOS.swift:507` | SOS صديق غير مؤكد | الأعلى (خارج الطابور) | شريط A2، إشعار push |
| A2 | شريط SOS صديق | `SarySOS.swift:446` | بعد التأكيد | الأعلى | A1 |
| A3 | شريط SOS لي | `SarySOS.swift:348` | SOS فعّال | الأعلى | زر SOS (٤ مواضع) |
| A4 | زر SOS | `SarySOS.swift:11`، `LiveCalmChrome.swift:169`، `SOSOverlay.swift:7`، `LiveSettingsPage.swift:91` | الرحلة شغّالة | – | **٤ مواضع لنفس الزر** |
| A5 | عدّ ٣ ث وتأكيد الإيقاف | `SarySOS.swift:152` | بعد ضغط ١ ث | – | `CarPlaySOSGuard` |
| A6 | إنجاد | `Safety/EnjadViews.swift:25` | فعل المستخدم | – | ٣ مداخل |
| A7 | أنا مغرّز | `Safety/SafetyViews.swift:172` | بلّغت | عالية | بلاطة، علامة اسم، `SafetySection` |
| A8 | صديق مغرّز | `SafetyViews.swift:28` عبر `upsertAlert` (`SafetyController.swift:409`) | بلّغ صديق | `.stuck` | ملاحظة mesh (`LiveOutingController.swift:520`) |
| A9 | مؤقّت العودة (لي/لصديق) | `SafetyController.swift:176,433`، حوار `SafetyViews.swift:~526`، `ReturnTimerCard :309`، إشعار | تجاوز الوقت | `.returnTimer` | **٤ أسطح** |
| A10 | غروب الشمس | `SafetyController.swift:510,569`، `SunsetWayBack.swift:100` | قرب الغروب | `.returnTimer` | الصوت يكرر البطاقة |
| A11 | عضو صامت | `UI/Components/SarySilentCard.swift:33`، `Live/LiveSilence.swift:91` | توقف الإرسال | `.silent` | شارة الاسم |
| A12 | تنبيهات القافلة (تفرّق، توقف غير متوقع، رجوع للتجمع) | `Live/LiveOutingController+ConvoyIntel.swift:16,41,46,80` | `ConvoyWatch` | `.convoy` | `FeatureViews.swift:190-196` |
| A13 | خارج المسار | `Live/LiveOutingController+Follow.swift:51` | >٥٠ م ولأكثر من ١٠ ث | `.convoy` | G11 |
| A14 | تنبيه الطقس | `LiveOutingController.swift:359` | تقييم الطقس | `.weather` | W8/W9 |
| A15 | ملاحظة صديق | `LiveOutingController.swift:651` | وصلت | `.note` | فقاعة الخريطة |
| A16 | مقطع صوتي | `SaryAlertLane.swift:267` | وصل | `.note` | `VoiceNoteStatusPill` |
| A17 | نقطة جديدة (خطر…) | `OutingFeaturesModel.swift:109` | صديق أضاف | toast | – |
| A18 | تجاوز السرعة | `Live/LiveOutingController+Speed.swift:28-30` | فوق الحد | toast، **يُخفى أثناء القيادة مع بطاقة** | G20 |
| A19 | وصول | `Live/LiveOutingController+Legs.swift:34` | – | toast | G12 |
| A20 | GPS ضعيف/لا إنترنت/موقع مغلق/دقة تقريبية | `UI/Contracts/LiveOutingContract.swift:39`، `LiveOutingPresenter.swift:146` | حالة الجهاز | – | `SaryOfflineStrip` (`Screens/ScreenKit.swift:191`)، `ShareBackgroundHintRow` (`LiveSheet.swift:804`)، `TripStatusCallout` (`:493`)، نص الطقس والبريف |
| A21 | إشارات الإخفاء | `Core/MemberPresence.swift:98-115` | «أخفِ موقعي» | – | شريط + حوار + toast + تذكير + شارة الدعوة |
| A22 | الصادر دون اتصال | `Core/PendingActionQueue.swift:463,470` | فشل إرسال | – | M9 |
| A23 | دردشة واردة | `Chat/LiveOutingController+Chat.swift:44-58` | رسالة والدردشة مغلقة | toast | `ChatBadge`، push |
| A24 | وسائط القناة | `Media/MediaViews.swift:57` | صديق بدأ فيديو | `.media` (الأدنى) | – |
| A25 | الجرس وسجل التنبيهات | `Views/LiveCalmChrome.swift:251`، `Views/TripHeader.swift:342` | ضغط الجرس | – | **لا يحتوي الـtoasts** |
| A26 | كاميرات ساهر | **غير موجود على `main`** (PR #122) | – | – | – |

### ٤.٣ تكرارات الإشارات (٢٠)
١) خمسة عارضات toast. ٢) ثلاثة نصوص لـ«نُسخ» (`Plan/PointCard.swift:218`، `Plan/LivePlan.swift:488`، `Explore/ExploreViews.swift:389`). ٣) ثلاثة مكوّنات لشريط ملوّن (M6/M7/`SaryOfflineStrip`). ٤) صادر/دون اتصال بخمس صيغ. ٥) أربعة مؤقتات `notice`. ٦) SOS أربع نسخ للزر وثلاث للصديق. ٧) «مغرّز» بخمسة. ٨) مؤقّت العودة بأربعة والغروب بصوت وبطاقة. ٩) قائمة «البر» بأربع نسخ. ١٠) شرائح التصنيف بنسختين. ١١) أزرار الخريطة الجانبية ثلاث تعريفات. ١٢) «المزيد» ثلاث قوائم. ١٣) ورقة الطبقات القديمة. ١٤) البطاقة/البحث. ١٥) الطقس عند المكان. ١٦) مفاتيح الإعدادات المكررة (بطارية، إشعارات، قافلة). ١٧) مقطع الصوت/الملاحظة. ١٨) الدعوة القديمة `InviteTab`. ١٩) الإخفاء بخمس إشارات. ٢٠) اللمسات الخام.

### ٤.٤ قواعد السلامة التي **لا تُلمس** (من التعليقات في الكود)
| القاعدة | المكان |
|---|---|
| SOS يتجاهل «أخفِ موقعي» ويحمل الموقع الحقيقي دائمًا | `Core/SendGate.swift:33,46-48`، `App/OutingSession.swift:1439-1441,1480` |
| SOS لا يُكتم بإعداد اللمس | `UI/DesignSystem/SaryTokens.swift:582-584` |
| وصول SOS مؤكَّد وليس فوريًا، وليس في الطابور عمدًا | `OutingSession.swift:1241-1245,1441` |
| «أنا بخير» أو إخفاء في الطابور لا يهبط بعد SOS جديد فيلغيه | `OutingSession.swift:1474-1480,1492-1530` |
| نافذة SOS فوق كل ورقة | `Views/SOSOverlay.swift:3-5`، `LiveOutingScreen.swift:125-134` |
| SOS الصديق ليس ورقة ولا غطاء (نافذة خاصة) | `SOSOverlay.swift:155-160`، `LiveSheet.swift:8,80-82` |
| SOS ليس ضغطة واحدة: ١ ث ثم عدّ ٣ ث | `SarySOS.swift:140,152,403` |
| الصادر: دائم، متكرر الأمان، لا للجلسات المحلية؛ الإخفاء والمغادرة ٧ أيام والباقي ساعتان | `Core/PendingActionQueue.swift:7-8,54-71` |
| الفشل لا يستأنف المشاركة أبدًا | `OutingSession.swift:1238-1245` |
| إخفاء ≥٣٠ دقيقة يطلق تذكيرًا محليًا | `App/HideReminder.swift:6-26` |
| لا يُصفّى SOS بالحظر | `Chat/ChatModels.swift:274` |

### ٤.٥ تصميم مركز التنبيهات الموحَّد
- **مصدر واحد**: `AlertCenter` (يتطور من `AlertQueue`): كل ما يخبر المستخدم بشيء يمر عبره بنوع وأولوية: `sos` (مستثنى: يبقى في نافذته الخاصة)، `safety` (مغرّز، مؤقّت، غروب، صامت)، `guidance` (إعادة حساب فاشلة، خارج الطريق)، `camera` (ساهر، من PR #122)، `weather`، `convoy`، `device` (GPS، إنترنت، بطارية، صادر)، `social` (ملاحظة، صوت، دردشة، وسائط)، `info` (نُسخ، حُفظ).
- **عرض واحد**: صف تنبيه واحد في أعلى الشاشة (واحد في كل لحظة، الأعلى أولوية، والباقي في طابور بعدّاد صغير). الجرس يفتح **صندوق وارد** يحوي كل ما مرّ بما فيه toasts (يُصلح الخلل في §١).
- **قواعد الطابور**: الإخلاء حسب الأولوية لا الترتيب الزمني (يُصلح `pushAlert`)؛ تنبيه آمن-حرج لا يُطرد بتنبيه معلوماتي؛ `info` يختفي بلا أثر ولا يدخل الصندوق إلا إذا كان فشلًا.
- **الأشرطة الثابتة** (حالة مستمرة وليست حدثًا): خطأ GPS/إنترنت/صادر تُدمج في **شريط حالة واحد** (حالة الجهاز) بدل M6/M7/`SaryOfflineStrip` في أماكن متفرقة؛ يبقى `SaryBanner` كمكوّن مرئي داخل النماذج والأوراق (مو تنبيهًا).
- **ما لا يتغير**: SOS (A1-A5)، حوارات النظام، منطق `PendingActionQueue`/`SendGate`، إشعارات النظام.

---

## ٥. الأماكن والناس والأدوات (ملخص + تصميم)

**الأماكن (٥ تكرارات)**: بطاقة مكان الرئيسية `MapHomeScreen.placeCard` (`Home/MapHomeScreen.swift:887`) مقابل `PointCard` (`Plan/PointCard.swift:43`) مقابل `PlaceBriefSection` (`Plan/PlaceBriefView.swift:14`)؛ أربع نسخ لنتائج البحث (`MapHomeScreen.swift:772`، `Plan/LivePlan.swift:173,234`، `Create/CreateOutingWizard.swift:334`، `PointCard.swift:243`)؛ شرائح التصنيف مرتين (`MapHomeScreen.swift:182`، `Home/IdleMapHost.swift:165`)؛ شريط تحليل الإحداثيات مرتين (`PointCard.swift:299`، `CreateOutingWizard.swift:325`)؛ «احفظ» بلا أي تأكيد (`MapHomeScreen.swift:~985`). **الهدف**: `PlaceCard` واحدة (الاسم، المسافة، «اتجه»، «احفظ»، «طقس» تفتح الصفحة الموحدة) تُستعمل في الرئيسية والطلعة والمعالج.

**الناس (٤)**: ثلاثة عارضات للدعوة (`RootView.swift:63`، `LiveSheet.swift:80`) مقصودة ومتنافية، و`InviteTab` القديم (`LiveSheet.swift:893`) مقابل `PersonalInvitesSection`؛ مقطع صوتي بسطحين (`SaryAlertLane.swift:267`، `VoiceNoteViews.swift:224`)؛ زر PTT بموضعين؛ الدردشة: toast + شارة + push. **الهدف**: لوحة مجموعة واحدة (`LiveSheet`) وإزالة `InviteTab`.

**الأدوات (٦)**: قائمة «البر» بأربع نسخ (`MapHomeScreen.swift:215`، `IdleMapHost.swift:~166`، `LiveSheet.swift:342`، `HomeTools.swift:71`)، ثلاث قوائم «المزيد» (`IdleMapHost.swift:~125`، `LiveSheet.swift:~330`، `LiveActionSheet.swift:57`)، ثلاثة تعريفات للأزرار الجانبية (`MapHomeScreen.swift:235-262`، `UI/Components/SaryMapControls.swift:27,167`، `Home/IdleMapRules.swift:49-77`)، ورقة الطبقات القديمة `ExploreLayersSheet` (`Explore/ExploreViews.swift:186`) خلف علم، مفاتيح إعدادات مكررة (بطارية `LiveSettingsPage.swift:368` و`SettingsScreens.swift:257`؛ إشعارات `:372` و`:431`؛ قافلة ×٣). **الهدف**: قائمة «المزيد» واحدة مبنية من `LiveActionCatalog`، ومصدر واحد لأزرار الخريطة.

---

## ٦. القائمة المرتبة للـPRات الصغيرة

كل PR مستقل وقابل للشحن، **التكافؤ مُثبت بلقطات قبل حذف القديم**، والقديم خلف علم DEBUG حتى يُثبت التكافؤ.

### الطقس أولًا (سماه المالك)
| PR | المحتوى | الاختبارات | اللقطات (متغير واحد) | المخاطر |
|---|---|---|---|---|
| **W-1** (المرحلة ٢) | `WeatherPage` تجمع: بطاقة النقطة/الوجهة/المنطقة، منتقي الطبقة + فترة المطر، ▶︎/⏸ وشريط الزمن، مفتاح الألوان، اتجاه السحاب، السيول، المركز الوطني؛ شريحة حالة واحدة تفتحها؛ **البطاقة العائمة القديمة خلف `-SaryLegacyWeatherCard`** | **U** `WeatherPageRulesTests`؛ تعديل **UI** `WeatherCardUITests` (الشريحة والصفحة)، `ExploreUITests.testWeatherRainLayerAndPeriodControls` (يفتح الصفحة)؛ بقاء `WeatherLayersTests`، `CloudOutlookTests`، `WindRainMotionTests` خضراء | قبل: بطاقة عائمة + شريحة الرأس؛ بعد: شريحة + صفحة (نفس الطبقة، نفس الشاشة) | تغيير معرّفات `weather.legend.*` (تنتقل للصفحة بنفس الأسماء حيث أمكن) |
| W-2 | `WeatherPointSheet` و«الجو هناك» و«طقس» في بطاقة المكان تفتح `WeatherPage(point:)`؛ حذف الورقة الثانية | **U** مصدر النقطة؛ **UI** `HomeFlowUITests` (مسار الجو هناك) | بطاقة مكان → صفحة | مسار جلب `WeatherStore` يبقى حتى W-3 |
| W-3 | ورقة الطبقات: مجموعة «الطقس» تصير صفًا واحدًا يفتح الصفحة؛ حذف `WeatherLayersSection` و`ExploreLayersSheet` | `LayersSheetUITests` و`LayersToggleUITests` و`LayersButtonUITests` (تعديل) | الورقة قبل/بعد | معرّفات `weather.layer.*` تنتقل |
| W-4 | `DetailsWeatherSection` ومعالج «طلعة جديدة» يستعملان بطاقة الصفحة (قسم واحد قابل لإعادة الاستعمال)؛ توحيد `PlaceBriefModel` و`WeatherStore` و`OutingWeather` على مصدر جلب واحد | `CreateFlowUITests`، `PlaceBriefRulesTests`، `WeatherStoreTests` | تفاصيل الطلعة، المعالج | خصوصية: لا يتغير ما يُرسل لـOpen-Meteo |
| W-5 | حذف القديم (البطاقة العائمة، `LiveWeatherCard`، `LiveWeatherChip`، علم DEBUG) | الأساس كاملًا | – | بعد مرور دفعة TestFlight |

### التوجيه (بعد دمج #230 و#225 و#227)
| PR | المحتوى | الاختبارات | المخاطر |
|---|---|---|---|
| G-1 | حذف الميت (`TripPeekStrip`)؛ أداة سرعة واحدة تشمل `.offRoad` | `NavigationTests` + **UI** `NavigationUITests` | علامة الحد ترجع في خارج الطريق: لقطة |
| G-2 | الرأس يختفي دائمًا مع `nav.isActive` (حتى مع رفع الورقة)؛ ETA في الشريط السفلي فقط | `LiveCalmTests`, `TripUITests` | قاعدة «زرين كحد أقصى» |
| G-3 | الوصول: بطاقة واحدة (السفلي ينقلب)؛ حذف toast وسطر الرأس المكرر | `TripProgressTests`، `TripUITests` | **CarPlay** يقرأ `g.arrived`: لا تغيير في اسم الخاصية |
| G-4 | خارج الطريق/هجين/إعادة حساب داخل الشريط العلوي بنص واحد `NavOffRoad`؛ كم الأسطح سطر واحد في السفلي | `NavOffRoadTests`, `NavigationTests` | CarPlay وLive Activity يستهلكان نفس النص |
| G-5 | «رجّعني للتوجيه» زر واحد؛ `navSideItems`/`navControlItems` قائمة واحدة | `FollowCameraTests` | – |
| G-6 | حذف `StandaloneNavScreen`؛ مضيف واحد للوحة المسار | اختبارات `StandaloneNav*` تُحذف أو تُنقل | اختبارات الملاحة تفشل تحت الحمل: أعد وحدها (`TEST-BASELINE.md`) |
| G-7 | منتقي «إلى أين؟» والمسارات ورقة واحدة | `NavigationUITests` | – |

### الإشارات
| PR | المحتوى | الاختبارات | المخاطر |
|---|---|---|---|
| A-1 | الـtoast يدخل سجل الجرس؛ إصلاح الطرد حسب الأولوية في `pushAlert` | **U** `AlertQueueTests` (طرد، سجل) | لا يُلمس SOS |
| A-2 | `SaryToast`/toast المستقل/مصفوفة `TrackFollowScreen` تمر عبر `AlertCenter`؛ نص «نُسخ» واحد | **UI** `HomeFlowUITests` | – |
| A-3 | `notice` النماذج الأربعة تمر عبر `pushAlert` بمؤقت واحد | `VoiceNoteTests`، `LiveChannelTests` | PTT: لا تأخير في الإرسال |
| A-4 | صادر دون اتصال: سطح واحد (شريط حالة الجهاز) بدل banner+toast | `BackgroundSessionTests`, `PendingActionQueueTests` | **طابور الصادر**: لا يتغير المنطق، عرض فقط |
| A-5 | مغرّز/مؤقّت العودة/غروب: سطح تنبيه واحد لكل حالة (بطاقة تحمل الإجراء) بدل بطاقة+حوار+شريط | `SafetyTests` | **سباقات الإخفاء/SOS**: لا لمس لـ`OutingSession` |
| A-6 | نوع `camera` (بعد دمج #122) | اختبار جديد | – |
| A-7 | شريط حالة جهاز واحد يحل محل `SaryOfflineStrip` وملاحظات GPS المتفرقة | `ReachabilityUITests` | حالة الأذونات تفشل أصلًا على `main` |

### الأماكن/الناس/الأدوات
P-1 `PlaceCard` واحدة (+ تأكيد «حُفظ»)، P-2 نتائج البحث وشرائح التصنيف مكوّن واحد، T-1 قائمة «البر» و«المزيد» من كتالوج واحد، T-2 أزرار الخريطة الجانبية مصدر واحد، T-3 مفاتيح الإعدادات المكررة، N-1 حذف `InviteTab`.

---

## ٧. الاختبارات والمخاطر المشتركة

- **خط الأساس**: كل تشغيل يقارَن بـ`docs/TEST-BASELINE.md`؛ الفشل غير المذكور يوقف الدمج. واجهة الملاحة تُعاد وحدها قبل الحكم عليها.
- **سباقات SOS و«أخفِ موقعي»**: لا PR هنا يلمس `OutingSession` أو `SendGate` أو `SOSOverlay`. أي خطوة تمس `AlertQueue` تثبت أن SOS خارجها (اختبار: `AlertQueue` لا يحوي نوعًا `.sos`، وطرد التنبيهات لا يمس A1-A5).
- **CarPlay**: يقرأ `NavSession` و`LiveOutingController`؛ لا إعادة تسمية خصائص بلا غلاف توافق؛ نصوص `NavOffRoad` وإعادة الحساب تُشارَك لا تُنسخ.
- **الطابور دون اتصال**: العرض فقط يتغير؛ `PendingActionQueue` (٧ أيام للإخفاء والمغادرة، ساعتان للباقي) كما هو.
- **الطلعة الفردية (`OutingSession.solo`)**: محلية بالكامل؛ مركز التنبيهات والصفحة يعملان فيها بلا جلسة خادم (الطقس والتوجيه لا يحتاجان إليها).
- **الخصوصية**: الصفحة الموحدة لا ترسل أكثر مما ترسله الأوراق الحالية (إحداثيات مقرّبة ~١١ كم للمنطقة، الوجهة كما حُددت، النقطة المختارة فقط).
- **فروع مفتوحة تتقاطع**: `fix-end-trip-weather` (أزرار إنهاء الرحلة وزر الطبقات وأولوية الطقس داخل التوجيه) و`explore-merge` (EM4-EM6) و#230/#225/#227/#228 و#122. خطوات الطقس تتجنب ملفات التوجيه؛ خطوات G تنتظر دمجها.

## ٨. ما لم يتحقق منه
لا جوال حقيقي. الجرد من قراءة الكود (وكلاء قراءة فقط ثم مراجعتي)، وأرقام الأسطر قد تتحرك. لم أشغّل المحاكي في هذا الـPR (وثيقة فقط).
