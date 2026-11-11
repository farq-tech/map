# «اتجه» طلعةً فرديةً محلية: التصميم

آخر تحديث: 2026-11-11. تصميم فقط، بلا كود. المرجع: قرار المالك في #157 («توحيد «اتجه» مع شاشة الطلعة الحية»).
المسارات نسبتها إلى `apps/ios/SaryAlbarq/` ما لم يُذكر غير ذلك. أرقام الأسطر من فرع `claude/offroad-next` اليوم، وقد تتزحزح.

**الفكرة في سطر:** «اتجه» من الخريطة الرئيسية لا تفتح `StandaloneNavScreen` بعد اليوم، بل تفتح `LiveOutingScreen` نفسها على `OutingSession` محلية فيها عضو واحد (أنا)، لا تتصل بالخادم ولا ترسل لأحد. كل ما يخص المجموعة يختفي، وكل ما يخص السائق يبقى كما هو في أي طلعة.

---

## (أ) ما يحتاجه `LiveOutingController` من `OutingSession`، وأين يتوقف بلا خادم

### ١. ما يقرؤه الكونترولر من الجلسة

أُحصيت الاستدعاءات بـ`grep -rhoE "session\.[a-zA-Z_]+"` على `Sources/Live` و`Views` و`Navigation` و`CarPlay` و`Safety` و`App`. الأكثر استعمالًا:

| ما يُقرأ | عدد المواضع | الاستعمال | بلا خادم |
|---|---|---|---|
| `session.view` (`OutingView?`) | 62 | كل شيء: الأعضاء، `status`، `myId`، `iLead`/`iOwn`، التجمع، القافلة | **يجب أن يكون غير nil**. لو كان nil لا تُرسم سيارتي ولا يُسجَّل المسار (انظر ٢) |
| `session.id` | 33 | مفتاح كل المخازن المحلية (`TrailStore`، `TripStore`، `TripLogStore`، `OutboundJunctionStore`، `PlanCenter`) | يعمل مع أي معرّف محلي |
| `session.displayView` | 27 | `view` مع إسقاط الشبكة القريبة (`meshOverlay`) | يساوي `view` حين تكون `mesh` فارغة |
| `session.walkie` / `session.voiceNotes` | 17 / 7 | الواكي، وكتم صوت الملاحة وقت الكلام (`nav.voice.canSpeak` في `LiveOutingController.swift:437`) | يكفي أن يكونا خاملين (`floor.state == .idle`) |
| `session.closedReason` | 15 | إغلاق الشاشة والملخص | يُضبط محليًا عند «أنهِ» |
| `session.isDemo` | 14 | فروع «بلا خادم» **وفروع بيانات العرض** معًا (انظر ٣) | لا يصلح كما هو للطلعة الفردية |
| `session.trail` / `displayTrail` / `smoothedFix` | 3 / 5 / 5 | «مساري»، «طريق الرجعة»، سيارتي المنعّمة | محلية بالكامل أصلًا |
| `session.link` | 3 | شريط «ما فيه نت» (`LiveOutingPresenter.warnings`، سطر 146) | يجب ألا يكون `.offline` وإلا ظهر تحذير كاذب |
| `session.wantsToShare` / `isSharingNow` / `hasConsent` | 6 / 5 / 2 | حالة المشاركة في الرأس والإعدادات | `false` دائمًا، والواجهة يجب أن تقول «على جوالك فقط» بدل «موقفة» |
| `session.setStatus` / `sendNote` / `setRally` / `raiseSOS` / `leave` / `nudge` / `setHidden` / `newInviteURL` | 1 إلى 4 لكل منها | أفعال المجموعة | كلها تمر على `api` إلا في فرع `isDemo` |
| `session.navSnapshot` / `speedSnapshot` / `tripSnapshot` / `stuckMarks` | 1 لكل منها | تغذية Live Activity وCarPlay | محلية |

ويأخذ الكونترولر مع الجلسة أربعة أشياء في `init` (`LiveOutingController.swift:342`) لها خلفيات خادم:

- `features` ← `OutingFeaturesModel(session:backend:)`: النقاط والقافلة. `AppModel.featuresBackend` يعطي `api` خارج العرض (`AppModel.swift:283`).
- `safety` ← `SafetyController(backend: session.safetyBackend)` و`safetyBackend` هو `isDemo ? nil : api` (`OutingSession.swift:100`).
- `legs` ← `OutingLegsCenter(backend: session.isDemo ? nil : session.api)` (`OutingLegsCenter.swift:175`). عند الفشل يتحول إلى مشوار محلي `local-<UUID>` (`OutingLegsCenter.swift:130`).
- `planModel` ← `AppModel.plans.model(session.id)` و`plans` هو `PlanCenter(backend: isDemo ? DemoPlanBackend() : api)` (`AppModel.swift:67`).

### ٢. أين يتوقف أو ينكسر بلا خادم

لو فُتحت `OutingSession` عادية (بلا `demo:`) بمعرّف محلي:

1. **`open()` يبني `LiveChannel` ويبدأه** (`OutingSession.swift:315`): مقبس WebSocket واستطلاع HTTP إلى `/outings/<id>` يُرفضان، فيدور الرابط بين `.connecting` و`.offline` فيظهر «ما فيه نت» وهو كاذب.
2. **`view` يبقى nil** لأن اللقطة الأولى تأتي من الخادم (`applySnapshot`). ونتيجته:
   - `trailRecordingAllowed` يرجع `false` (`OutingSession.swift:811`: يشترط `view` و`v.me` و`status ∈ {active, paused}`)، **فلا يُسجَّل مسار ولا تعمل «طريق الرجعة»**.
   - `LiveOutingPresenter.mapMembers` يرجع `[]` (يبدأ بـ`guard let v = i.view`)، **فلا تُرسم سيارتي**.
   - `CarPlayCoordinator.refresh` يعرض «لا طلعة» (`guard let s = session, s.view != nil`، سطر 168).
   - `OutingActivityCoordinator.start` لا يبدأ (`guard ... let v = s.view`، سطر 110).
3. **المؤقتات تطرق الخادم:** نبض الاتصال (`beat`)، و`refreshWaitingStatus` كل 15 ثانية إذا `status == .created`، و`BackfillUploader.resume()`، و`chat.refresh()` بعد ثانية من الفتح.
4. **الخطة:** `plans.model(id).loadPlan()` يطلب `GET` من الخادم فيفشل، فلا وجهة للرحلة (`tripDestination == nil`)، فلا يعمل `offerGuidanceChoice` (`LiveOutingController+AutoNav.swift:173` يشترط `tripDestination != nil`).
5. **التوجيه التلقائي:** `autoNavAllowed` = `!session.isDemo` (سطر 18). هذا صحيح للطلعة الفردية، **بشرط ألا تُعلَّم الجلسة `isDemo`**.
6. **الطوارئ:** `raiseSOS` يرسل `api.raiseSos` (`OutingSession.swift:1219`) ويعلن عبر `mesh`. بلا خادم يفشل الإرسال، فيظهر «ما وصل» ويبقى زر 911 وحده.
7. **«أنهِ الطلعة»:** `setStatus("end")` يطلب الخادم (`OutingSession.swift:1115`)، فلا تنتهي الطلعة ولا يظهر الملخص.

### ٣. لماذا لا نعيد استعمال `isDemo` كما هو

مسار `-demo` يشغّل الشاشة الحية كلها بلا خادم اليوم (`AppModel.openDemoSession`، سطر 882، يمرر `demo: OutingView`). لكن `isDemo` يخلط شيئين:

- **«بلا خادم»** وهو ما نريده: `guard !isDemo else { walkie.attach(channel: nil, …); return }` في `open()` (سطر 310)، و`link = .live` (سطر 194)، وفروع `setStatus`/`raiseSOS`/`setRally` المحلية.
- **«بيانات عرض»** وهي ما لا نريده إطلاقًا:
  - `DemoVoiceNoteBackend(friendId:)` يرد على كل رسالة صوتية بتسجيل «أبو فهد» (سطر 180).
  - `DemoChatBackend(friends:)` (سطر 188).
  - `OutingWalkieTalkie(demo: true)` بقناة محلية.
  - `autoNavAllowed == false` خارج `-SaryAutoNav`.
  - `startReturnTrip` يرفض بـ«تحتاج الخادم» (`AppModel.swift:767`).
  - `TripLogStore` يُتجاوز.
  - الحالة تُقرأ من `speed.local` (`LiveOutingController+Trip.swift:63`).
  - شعار «(عرض تجريبي)».

  ويوجد 129 موضعًا لـ`isDemo` في 26 ملفًا.

**القرار:** نوع جلسة صريح بدل علم واحد. التفاصيل في (ب).

---

## (ب) واجهة الجلسة المحلية

### ١. الخيار المقترح: `OutingSession.Kind` لا بروتوكول جديد

استخراج بروتوكول من `OutingSession` يعني تعديل 26 ملفًا تأخذ النوع الملموس (`LiveOutingController`، و`CarPlayCoordinator.makeInput`، و`OutingActivityCoordinator`، و`OutingFeaturesModel`، و`PersonalInvitesSection`…). هذا أكبر من الحاجة وفيه خطر أعلى. الأصغر والأصح هو تعداد داخل الصنف نفسه:

```swift
enum Kind: Equatable { case server, demo, solo }
let kind: Kind
var isDemo: Bool { kind == .demo }          // unchanged meaning for the 129 call sites
var isLocal: Bool { kind != .server }       // "no server" — the new, explicit question
var isSolo: Bool { kind == .solo }
```

- مواضع `isDemo` التي تعني «بلا خادم» تتحول إلى `isLocal`. هي في `OutingSession` أساسًا (فروع `open`، و`setStatus`، و`raiseSOS`، و`setRally`، و`leave`، و`sendNote`، و`safetyBackend`)، وفي `OutingLegsCenter.swift:175`.
- المواضع التي تعني «بيانات عرض» تبقى `isDemo`.
- تُراجع المواضع واحدًا واحدًا في PR مستقل (الخطوة ١ في (ز)). لا يتغير فيه أي سلوك لـ`server` ولا `demo`.

### ٢. المُنشئ

```swift
extension OutingSession {
    /// «اتجه» without an outing: one member (me), no server, nothing sent.
    static func solo(id: String, me: PublicUser, name: String, location: LocationSharer, env: SessionEnv = SessionEnv()) -> OutingSession
}
```

ينادي `init` الحالي بـ`demo: SoloOuting.view(…)` و`kind: .solo` (معامل جديد قيمته الافتراضية تُشتق من `demo != nil` كي لا يتغير أي استدعاء قائم). الفروق عن `demo`:

| الجزء | `demo` اليوم | `solo` |
|---|---|---|
| `view` | `DemoData.view()`: أربعة أعضاء بمواقع ثابتة | `SoloOuting.view(id:me:name:)`: عضو واحد `role: "owner"`، `sharing: false`، `status: .active`، `positions: []`، `invite: InviteState(active: false, …)` |
| `link` | `.live` | `.live` (لا تحذير «ما فيه نت»؛ الشبكة الحقيقية تُقرأ من `AppModel.online` للملاحة) |
| `LiveChannel` / `BackgroundPositionSender` / `BackfillUploader` / نبض | لا شيء | لا شيء |
| `walkie` | `demo: true`، قناة محلية | `tokenBackend: nil`، **لا `attach`** (يبقى `.unavailable`) |
| `voiceNotes` | `DemoVoiceNoteBackend` يرد بـ«أبو فهد» | خلفية فارغة لا ترد (`NoVoiceNoteBackend`) أو مركز غير مُرفق |
| `chat` | `DemoChatBackend` بأصدقاء العرض | `ChatStore` مع `availability = .unavailable`، بلا `refresh()` |
| `mesh` | يعمل مع `-SaryMeshTest` | `env.nearbyMesh = false` |
| `matcher` (مطابقة المسار بالطريق) | فقط مع `-SaryTrailMatch` | **يعمل** كما في الطلعة الحقيقية (Mapbox Map Matching بالمفتاح العام، يحتاج نت، ويُكمل لاحقًا إن انقطع) |
| `safetyBackend` | nil | nil |
| `TripLogStore` | يُتجاوز | يُكتب (ملخص المسافة والمدة) من `trailFix` لا من `handleFix`، لأن `handleFix` محكوم بـ`gate.allowsPosition` الذي يبقى مغلقًا (لا موافقة مشاركة) |

**`SendGate` لا يُلمس.** في الطلعة الفردية: `consent == false`، و`userWantsShare == false`، و`serverSharing == false`، فيبقى `allowsPosition == false`. الخصوصية مضمونة بالبناء نفسه لا بشرط إضافي. وسيارتي تُرسم من `myFix` مباشرة دون المرور بالبوابة (`LiveOutingPresenter.mapMembers`، سطر 376).

### ٣. ما حول الجلسة في `AppModel`

```swift
func openSolo(to d: OutingDestination)   // replaces StandaloneNavScreen's cover
```

1. **إذا كانت هناك طلعة حقيقية مفتوحة أو مركونة** (`session`/`parkedSession`): لا ننشئ طلعة فردية، بل نستعمل المسار الموجود اليوم: `open(id, mapDestination: d)` ← `pendingMapDestination` ← `startLegFromMap(d)` (`LiveOutingController+Legs.swift:181`). القاعدة: لا تُفتح جلستان معًا أبدًا.
2. **غير ذلك:**
   - المعرّف `solo-<UUID>` (يمر بـ`TrailStore.fileName` وبمدقق `OutingActivityState.outingId(from:)` لأن الحروف والأرقام و`-` مسموحة).
   - الاسم «مشوار إلى <الوجهة>».
   - `SoloOutingStore.add(…)` (فهرس محلي، انظر (د)).
   - `plans.model(id)` على خلفية محلية تحفظ على الجوال (`LocalPlanBackend`، على نمط `DemoPlanBackend` لكن **بلا بذور عرض**، ومخزّنة في `UserDefaults`/ملف). فيها `setDestination(d)`.
   - `session = OutingSession.solo(…)` ثم `open()`.
3. **التوجيه يبدأ وحده:** `autoNavAllowed` صحيح (ليست `demo`)، و`tripDestination == d`، و`guideAllHasOthers == false` (عضو واحد، `NavBroadcast.asksForAll(memberCount: 1)`)، فيذهب `offerGuidanceChoice` مباشرة إلى `startGuidanceForMe()` (سطر 175). وهو المسار نفسه الذي يسلكه قائد وحيد في طلعة حقيقية اليوم.
4. **التوجيه بالخلفية:** `PlanCenter` يختار الخلفية لكل معرّف: `isSoloId(id) ? local : (isDemo ? demo : api)`. وكذلك `featuresBackend(for:)`: `DemoFeaturesBackend(myId:notDeployed: true)` للفردية، فـ«أضف نقطة» تعمل محليًا.
5. **حارس أخير في `OutingsAPI`:** أي طلب بمعرّف يبدأ بـ`solo-` يُرفض محليًا (`OutingAPIError(code: "local_outing")`) ويُسجَّل في السجل. لا يصل شيء إلى الخادم حتى لو فات مسار ما في المراجعة.

### ٤. كيف يشغّل `-demo` الشاشة الحية اليوم (للمقارنة)

`AppModel.init` يقرأ `-demo` (سطر 83) ويصنع هوية محلية، ثم ينادي `openDemo()` ← `openDemoSession()` الذي يبني `OutingSession(…, demo: DemoData.view(…))`. بعدها `RootView` يرى `model.session` فيبني `LiveOutingHost` ← `LiveOutingController(session:…, featuresBackend: model.featuresBackend)`. الشاشة الحية لا تعرف أن لا خادم؛ الفروق كلها داخل الجلسة والخلفيات. الطلعة الفردية تمشي المسار نفسه حرفيًا، والفرق الوحيد هو `Kind`.

---

## (ج) ما يُخفى أو يُعطَّل في الطلعة الفردية

القاعدة: **يُخفى** ما لا معنى له لشخص وحده. **يُعطَّل مع سبب مكتوب** ما قد يبحث عنه المستخدم. مصدر الحقيقة واحد: `LiveScreenRules.solo` (دالة نقية تُختبر)، والمقدِّم (`LiveOutingPresenter`) يقرؤها.

| العنصر | أين هو اليوم | في الطلعة الفردية |
|---|---|---|
| **الواكي توكي** `SaryPTTButton` | `LiveOutingScreen.swift:297` و`:371` | يُخفى (لا زر ولا شريحة قناة). «الترددات» (`channels`) تُخفى من «المزيد» |
| **المحادثة** | صف الوصول السريع (`LiveActionCatalog.inQuickRow` = `chat`, `rally`)، و`runAction("chat")` | تُخفى من الصف السريع ومن «المزيد» |
| **نقطة التجمع** | الصف السريع، و`.panel(.rally)`، و`onRallyTap` على الخريطة | تُخفى |
| **ادعُ ربعك** | `.panel(.invite)`، وتبويب الدعوة، و`PersonalInvitesSection` | تُخفى في المرحلة الأولى. «حوّلها لطلعة مع الربع» مؤجَّل (قرار المالك: «الدمج لاحقًا اختياري») |
| **تنبيه الصديق / «نبّهه»** `nudge`، وتنبيهات القافلة `convoy`، و«رسالة فوق سيارتي» `note`، و«أخفِ موقعي» `hide`، و«شوف الكل» `fit`، و«وجّه الكل» `guideAll` | «المزيد» ← «الربع» و«الخريطة» | تُخفى كلها. مجموعة «الربع» تختفي بالكامل |
| **تبويب «الربع»** وقائمة المشاركين | `selectedTab == .group` | يُخفى التبويب. تبقى «الرحلة» و«الخريطة» |
| **«غرّزت»** | «المزيد» ← «السلامة» | يبقى، لكن محليًا: يسجّل علامة على المسار (`stuckMarks`) دون إرسال، ونصه «ما فيه أحد معك يوصله التنبيه؛ اتصل بإنجاد أو ٩١١» |
| **مؤقت الرجوع** `timer` | «السلامة» | يبقى كمنبّه محلي (إشعار على الجوال)، بلا إرسال لأحد |
| **الطوارئ (SOS)** | زر الطوارئ + `SOSOverlay` + `raiseSOS` | **يبقى الزر**. الضغط المطوّل يفتح مباشرة **اتصال ٩١١** (`Enjad.officialCallURL`، `Enjad.swift:95`) مع «اتصل بإنجاد» كخيار ثانٍ. لا عدّاد «نرسل لربعك»، ولا `raiseSOS`، ولا `mesh.announce` |
| **حالة المشاركة في الرأس** | `MySharingUI.paused` | نص ثابت «على جوالك فقط · ما يوصل لأحد» بدل «موقفة» أو «ابدأ المشاركة» |
| **تحذير «ما فيه نت»** | `warnings` إذا `link == .offline` | لا يظهر من الرابط. الملاحة تعرض حالتها الخاصة («نعيد المحاولة…») كما في الطلعة الحقيقية |
| **«أنهِ الطلعة»** | قائد الطلعة | يبقى بنص «أنهِ المشوار»، ويفتح الملخص المحلي |

ما يبقى كما هو بالضبط:

- السيارة الملوّنة ثلاثية الأبعاد و«أنت».
- السرعة وحدّ الشارع (`SpeedModel`).
- الملاحة وخيارات المسار (`NavOptionsSheet`) وكاميرا «باتجاهي» و«رجّعني للتوجيه».
- «مساري» و«طريق الرجعة» و«اسلك هذا المسار».
- الطقس، والقبلة، والبحث، و«بريف المكان»، و«استكشف الخريطة»، والطبقات.
- CarPlay وLive Activity.
- رأس الطلعة المختصر.

---

## (د) تسجيل المسار محليًا: أين يُحفظ وأين يظهر

**لا كود تسجيل جديد.** `OutingSession.trailFix` يعمل كما هو (`OutingSession.swift:882`) متى صار `trailRecordingAllowed` صحيحًا. وهو كذلك في الطلعة الفردية لأن `view.me != nil` و`status == .active`.

| ماذا | أين يُحفظ | الكاتب |
|---|---|---|
| المسار المرسوم (`Trail`) | `Application Support/trails-v1/solo-<UUID>.json` (`TrailStore.directory`، `Trail.swift:423`) | `saveTrail()` كل 5 نقاط أو 5 ثوانٍ، وعند `close()` |
| النقاط الخام | `TrailRawLog` بجانبه (المجلد نفسه) | `saveTrail()` |
| مطابقة الطريق | `TrailMatchStore` (المجلد نفسه) | `TrailMatchCoordinator` |
| نقطة البداية والأحداث | `TripStore` (`sary.trip.records.v1`) | `tripEvent(.started)` في `LiveOutingController+Trip` |
| ملخص المسافة والمدة | `TripLogStore` (`sary.trip.logs.v1`) | يُضاف مسار من `trailFix` للطلعة الفردية (انظر (ب)٢) |
| نقطة خروج المدينة إلى البر | `OutboundJunctionStore` (`sary.trip.roadJunction.v1`) | `recordOutboundJunction()` (`LiveOutingController+Trip.swift:202`) |
| **الفهرس (جديد)** | `SoloOutingStore` (`sary.solo.outings.v1`): `[id, name, destination, startedAt, endedAt?]` | `openSolo` و«أنهِ المشوار» |

ملاحظة على `recordOutboundJunction`: يشترط `target.source == .destination`. وجهة الطلعة الفردية تُحفظ في الخطة المحلية، فتأتي إلى `TripAutoNav` بمصدر `.destination`، والشرط يتحقق دون تعديل.

**أين يظهر:**

- **أثناء المشوار:** على الخريطة نفسها (`MapTrails.mine` / `mineTrack`)، وفي «الرحلة».
- **بعد الإنهاء:** ملخص الرحلة (`showSummaryAfterClose`)، و`OutingDetailsView` (يقرأ `model.myTrailPoints(id)` ← `TrailStore.load(id)`، `AppModel.swift:653`، دون تعديل)، وقصة الطلعة (`StoryModel` يقرأ `TrailStore`)، وتصدير GPX.
- **في «طلعاتي»:** القائمة اليوم من الخادم (`AppModel.history` من `api.list()`). نضيف دمج `SoloOutingStore` في `history` بشارة «على جوالك». **هذا في `Home/` وفي `AppModel`**، أي منطقة الوكيل الآخر، فيُنسَّق قبل تلك الخطوة.
- **الحذف:** «امسح مساري» (`clearTrail`) يعمل كما هو. حذف الحساب (`AccountDeletion`، `LocalAccountData.wipe`) يجب أن يمسح `SoloOutingStore` مع الباقي.

---

## (هـ) توحيد الخريطة، ولماذا تبدو «اتجه» أبهت

### ١. السبب: محركان مختلفان لا خريطة واحدة بإعدادين

`StandaloneNavScreen` ترسم `PlanMapView` (`Sources/Map/PlanMapView.swift`)، وهي خريطة محرر الخطة والمعاينات الصغيرة. أما الطلعة فترسم `OutingMapboxView`. المقارنة من الكود:

| الجانب | `PlanMapView` («اتجه» اليوم) | `OutingMapboxView` (الطلعة) | الأثر الذي يراه المالك |
|---|---|---|---|
| **النمط والتدريج** | `ArabicBasemap.cachedJSON`، أي `cached(.satellite)` (`OutingMapboxView.swift:2238`)، و`SandGrade.follow(map)` (`PlanMapView.swift:46`) | `ArabicBasemap.cached(layer)` بالنمط نفسه، و`sarySand` من `MapVisualsDirector` (`MapVisualsDirector.swift:253`) | **متطابق تقريبًا.** الرمل ليس السبب |
| **الإضاءة** | لا `lightPreset` ولا `setLights`: إضاءة Standard الافتراضية (نهار محايد مسطّح) | `applyLight()` يضبط `lightPreset` من الشمس الحقيقية (`OutingMapboxView.swift:704`)؛ ومع «السماء والإضاءة» (`ownsLight`، `MapVisualsDirector.swift:104`) `setScene()` يضع **ضوءًا اتجاهيًا من موقع الشمس مع ظلال** وضوءًا محيطًا ملوّنًا (`:383`) | الصورة الجوية فيها `raster-emissive-strength: 0.3` (`SandGrade.Look.emissive`)، أي أن 70% من لونها من ضوء المشهد. بضوء محايد تبدو باهتة رمادية، وبضوء الشمس الدافئ تبدو «شمس». **هذا السبب الأول لـ«كأنها غبار»** |
| **التضاريس** | لا `setTerrain` | `mapbox-dem` بتضخيم 1.15 (`:594`، و`terrainExaggeration` في `:627`) | الكثبان والجبال مسطّحة في «اتجه» |
| **تظليل التضاريس** | لا شيء | `applyHillshade()`: طبقتا `hillshade` (تفصيلية وعريضة) مضاءتان من اتجاه الشمس الحقيقي (`MapVisualsDirector.swift:402`) | بلا ظل وضوء على الكثبان تفقد الصورة عمقها وتبدو «مغبرة» |
| **السماء والضباب** | لا شيء | `applyFog()` ← `setAtmosphere` من ارتفاع الشمس والطقس (`:488`) | الأفق أبيض مسطّح |
| **الميل (pitch)** | `zoom: 11.5` بلا ميل (`PlanMapView.swift:39`)؛ والكاميرا `PlanCamera` (`point`/`fit`) لا تميل ولا تدور | «باتجاهي»: `FollowZoom.headingPitch = 58°` (`FollowCamera.swift:243`)، والسيارة عند 74% من المساحة الخالية، والزوم من السرعة، ودوران مع الاتجاه | «اتجه» منظر علوي مسطّح، والطلعة منظر سائق مائل |
| **المجسمات** | `show3dObjects: false` (`PlanMapView.swift:131`) | `show3dObjects: true` (`OutingMapboxView.swift:576`) | المباني في المدينة مسطّحة |
| **التسميات** | `showPointOfInterestLabels: true`، `showRoadLabels: true` | `SatelliteLabels.driving`: لا نقاط اهتمام، وأسماء الطرق والأماكن فقط (`TrackLineLayers.swift:160`) | زحمة نصوص بيضاء فوق الصورة تزيد الإحساس بالبهتان |
| **شوارع فرق** | لا `FarqTiles` | `FarqTiles.install(m, layer:labels:)` | شوارع وأماكن أطلس الأحدث غائبة |
| **مبانٍ مسطّحة** | `BuildingFootprints.install(m)` من زوم الحي (`:136`): بصمات فاتحة `hsl(36, 45%, 92%)` | الشيء نفسه، لكن تحت إضاءة الشمس | في «اتجه» البصمات الفاتحة تحت ضوء محايد تضيف غشاوة فوق المدن |
| **سيارتي** | `PlanUserLocationPin`: نقطة زرقاء (`puckType = nil` ثم دبوس) | نموذج 4×4 ثلاثي الأبعاد بلون العضو، وانزلاق بين القراءات (`MotionFX`)، ولصق بالطريق (`RoadSnap`) | «نقطة زرقاء» مقابل «سيارتي البيضاء» |
| **رسم الملاحة** | خط `PlanMapStyle` المتقطع (`ensureLayers(emphasised:)`)، خط خطة لا خط ملاحة | `NavMapDrawer`: ألوان الزحام، وأنواع السطح، وسهم المناورة، وإظهار المسار، والخط البديل | «اتجه» تبدو كخطة لا كملاحة |

### ٢. التوحيد

لا يُعدَّل `PlanMapView` ليشبه الطلعة. ذلك يكرر 2000 سطر من `OutingMapboxView`. بل **تختفي «اتجه» من `PlanMapView` تمامًا**: الطلعة الفردية تفتح `LiveOutingScreen` التي ترسم `OutingMapboxView` بالمعاملات نفسها التي تأخذها أي طلعة (`LiveOutingScreen.swift:58`): `members` (أنا وحدي)، و`nav: controller.mapNav`، و`followMode: controller.mapFollowMode`، و`labels: .driving` وقت التوجيه، و`layer: .satellite`. فيصير التطابق بنائيًا لا يحتاج صيانة:

- الإضاءة والتضاريس والتظليل والسماء والميل والمجسمات وشوارع فرق والسيارة ورسم الملاحة: كلها لأنها الخريطة نفسها.
- «باتجاهي» و«رجّعني للتوجيه» و«نظرة عامة» تأتي من `LiveOutingController+FollowCamera.swift` و`navControlItems`. وهذا يسد ثغرات «اتجه» الثلاث (الكاميرا، وخيارات المسار، وCarPlay وLive Activity) دون سطر خاص.

`PlanMapView` تبقى لما صُممت له: محرر الخطة، ومعاينة الوجهة، و«اختر من الخريطة»، والخريطة الرئيسية. وتحسين إضاءة الخريطة الرئيسية (`lightPreset` من الشمس على `PlanMapView`) قرار منفصل للمالك، ليس جزءًا من هذا التوحيد.

---

## (و) CarPlay وLive Activity و«طريق الرجعة» في الطلعة الفردية

### CarPlay

`CarPlayCoordinator` يقرأ `model?.session` (`CarPlayCoordinator.swift:73`) ويبني `CarPlayInput` من `s.view` و`location.lastFix`. و`LiveOutingController.registerCarPlay()` (`CarPlayWiring.swift:170`) يربط `CarPlayNavAdapter(provider: nav)` بـ`CarPlayFeatures.roadNavigation`. الطلعة الفردية جلسة عادية في `AppModel.session` لها `view`، فـ**قالب الخريطة والمناورات وخيارات المسار وبدء التوجيه من السيارة كلها تعمل دون تعديل.**

ما يحتاج تعديلًا صغيرًا:

- **قائمة الأعضاء والقافلة والمغرّزين:** فارغة طبيعيًا (عضو واحد). يُخفى زر «الربع» إن وُجد.
- **`carPlayStuckReportSupported`** (`CarPlayWiring.swift:161`): `view.status == .active && !isDemo`، فيصير صحيحًا في الطلعة الفردية. يجب أن يصير `!isLocal`، لأن البلاغ يذهب للخادم.
- **زر التحدث (رسالة صوتية):** يُخفى لأن `walkie` غير مُرفق.
- **بلا طلعة مفتوحة:** `showNoOuting()` يبقى كما هو. البدء من CarPlay بلا طلعة («اتجه» من السيارة) خارج المرحلة الأولى.

### Live Activity

`OutingActivityCoordinator` يتبع `session ?? parkedSession` (`AppModel.swift:140`). لكن `shouldRun(wantsToShare:status:closed:)` (`OutingActivityCoordinator.swift:73`) يشترط `wantsToShare`، وهو `false` دائمًا في الطلعة الفردية، **فلن تبدأ اليوم**. التعديل:

```swift
nonisolated static func shouldRun(wantsToShare: Bool, solo: Bool = false, status: OutingStatus?, closed: Bool) -> Bool {
    (wantsToShare || solo) && !closed && (status == .active || status == .paused)
}
```

القيمة الافتراضية تحفظ كل الاستدعاءات القائمة واختبارات `OutingActivityTests`.

- **السمات:** تُعاد كما هي: `OutingActivityAttributes(outingId: "solo-…", outingName: "مشوار إلى …")`.
- **الحالة:** `OutingActivityState` فيه ما يلزم أصلًا: `navLine`/`navSymbol` من `session.navSnapshot` (يُربط في `LiveOutingController+AutoNav.swift:44`)، و`tripRemainingM`/`tripETA`/`tripPercent` من `tripSnapshot`، و`speedKmh`، و`backMeters`.
- **حقل جديد:** `var solo: Bool = false` (اختياري بقيمة افتراضية، فيبقى `Codable` متوافقًا مع النسخ السابقة).
- **الودجت:** يقرأ الحقل ليخفي «مباشر ٣/٤» و«الأبعد» (`OutingLiveActivityWidget.swift:60` و`:102`)، ويعرض مكانها السرعة والوصول.
- **الضغط على النشاط:** يفتح `saryalbarq://outing/solo-…`. يجب أن يوجّه `AppModel.open(_:)` المعرّف المحلي إلى الجلسة المفتوحة أو المركونة، **ولا يطلب الخادم**. حارس `OutingsAPI` في (ب)٣ يضمن ذلك حتى لو فات.

### «طريق الرجعة»: يتتبع درب الذهاب في البر حرفيًا

**داخل المشوار نفسه** (ذهبت ثم أرجع قبل «أنهِ»): «طريق الرجعة» في «المزيد» ← `startBackTrack()` (`LiveOutingController.swift:790`) على `session.displayTrail`، المسار المسجّل محليًا. `BackTrack` يتتبعه نقطة نقطة بلا إنترنت. **لا تغيير.** شرطه الوحيد `trailRecordingAllowed`، وقد تحقق في (ب).

**مشوار رجعة جديد بعد الإنهاء** (المكافئ الفردي لـ«طلعة الرجعة»): اليوم `AppModel.startReturnTrip(from:)` يرفض العرض وينشئ طلعة على الخادم. للطلعة الفردية فرع محلي:

1. `openSolo(to: نقطة البداية)` من `TripStore.load(old).start` أو `myTrailPoints(old).start`.
2. `ReturnTripStore.link(new, returnsFrom: old)`، المخزن نفسه.
3. عند أول `.start` من `TripAutoNav` يعمل `startReturnDesertLegIfNeeded` (`LiveOutingController+Trip.swift:171`) كما هو:
   - `ReturnRoute.split(trail, saved: OutboundJunctionStore.load(old), match: TrailMatchStore.load(old))` يقسم درب الذهاب إلى جزء مدينة وجزء بر.
   - **جزء البر يُتتبع بـ`BackTrack` حرفيًا** حتى نقطة الالتقاء. وإن خرج السائق عنه، «خرجت عن الطريق» تعيده إلى الدرب نفسه، لا إلى مسار بر جديد.
   - بعد الالتقاء `handOverReturnToRoad()` يسلّم للتوجيه العادي (أسرع طريق في المدينة).
4. وبلا نت: `startReturnOnPhone(offline:)` (`:152`) يعمل كما هو.

كل ما يلزم موجود على الجوال: المسار والالتقاء والمطابقة، وكلها بمعرّف الطلعة القديمة، والطلعة الفردية تكتبها كأي طلعة. **قاعدة المالك (درب الذهاب حرفيًا في البر) لا تُمس**، فالمنطق في `ReturnRoute` و`BackTrack` لا يتغير، والتغيير الوحيد هو مصدر إنشاء الطلعة الجديدة.

---

## (ز) المخاطر، وخطة الاختبار، والتقدير، وخطة التنفيذ

### المخاطر

| الخطر | الاحتمال | الوقاية |
|---|---|---|
| مسار ما يرسل معرّف `solo-…` إلى الخادم (الخطة، والنقاط، والمشاوير، والدعوات، والمحادثة، و`push`، والملخص) | متوسط | حارس `OutingsAPI` يرفض محليًا + اختبار وحدة يمر على كل دوال `OutingsAPI` بمعرّف محلي + سجل |
| تحويل `isDemo` إلى `isLocal` يغيّر سلوك العرض أو الطلعة الحقيقية | متوسط | PR مستقل بلا سلوك جديد. اختبارات الواجهة تحت `-demo` كلها خط أساس (`docs/TEST-BASELINE.md`) |
| `LiveOutingScreen` تفترض وجود أصدقاء (مصفوفة فارغة، تقسيم على عدد الأعضاء، تبويب «الربع» فارغ) | متوسط | `LiveScreenRules.solo` واختبار `LivePresenterTests` بعضو واحد |
| تكلفة الشاشة الحية للسائق وحده (البطارية والحرارة): `MapVisualsDirector` ومجسمات ثلاثية الأبعاد | منخفض إلى متوسط | هي الشاشة نفسها التي يقودها المالك في الطلعات. `VisualBudget` يخفف في وضع الطاقة المنخفضة. قياس على الجهاز |
| جلستان معًا (طلعة حقيقية مركونة + فردية) | منخفض | قاعدة `openSolo` (ب)٣.١: داخل طلعة قائمة يصير «اتجه» مشوارًا فيها |
| الضغط على Live Activity أو إشعار يفتح معرّفًا محليًا كأنه طلعة خادم | منخفض | توجيه `open(_:)` + الحارس |
| «طلعاتي» تحتاج دمج الفهرس المحلي، وهي في منطقة وكيل آخر (`Home/`) | مؤكد | خطوة منفصلة منسّقة (٦ أدناه) |
| الإحساس بالخصوصية: «أنا وحدي، ليش شاشة طلعة؟» | منخفض | الرأس يقول «على جوالك فقط · ما يوصل لأحد». ولا موافقة مشاركة ولا `SendGate` مفتوح |

### خطة الاختبار

**وحدة (XCTest، محاكي):**

- `OutingSessionTests` (جديد أو ضمن `OutingStateTests`):
  - `solo` لا تبني `LiveChannel` (حقن `env.makeSocket` يفشل الاختبار إن استُدعي).
  - `link == .live`، و`trailRecordingAllowed == true`.
  - `gate.allowsPosition == false` دائمًا.
  - `setStatus("end")` يغلق محليًا.
- `PrivacyTests`: لا طلب شبكة لأي دالة `OutingsAPI` بمعرّف `solo-` (حقن `URLProtocol`).
- `LivePresenterTests`: عضو واحد يرسم سيارتي، ولا أعضاء غيري، وحالة المشاركة «على جوالك فقط».
- `LiveDeclutterTests` / `DeclutterTests`: `LiveActionCatalog.groups` مع `solo` بلا «الربع» ولا محادثة ولا تجمع، والطوارئ = ٩١١.
- `OutingActivityTests`: `shouldRun(wantsToShare: false, solo: true, …) == true`، والتوافق: فك ترميز `OutingActivityState` قديم بلا `solo`.
- `CarPlayWiringTests`: `carPlayStuckReportSupported == false` للفردية.
- `TripProgressTests`: سلسلة رجعة فردية: `ReturnTripStore.link` + `ReturnRoute.split` على مسار محفوظ بمعرّف `solo-` تعطي `desertTrail`.
- `TrailTests`: `TrailStore` بمعرّف `solo-…` حفظ وتحميل.

**واجهة (XCUITest، محاكي):** وسيط `-SarySolo "lat,lng,name"` يفتح طلعة فردية مع `-SaryNavDemo` (`DemoNavProvider`):

- تظهر الشاشة الحية (`outing.map`)، والتوجيه يبدأ وحده (`nav.banner`).
- لا `ptt`، ولا `outing-chat`، ولا `outing-invite`.
- زر الطوارئ يعرض «اتصل ٩١١».
- «أنهِ المشوار» يفتح الملخص.
- لقطات مقارنة: «اتجه» قبل وبعد، على `-SaryDemoShift` في النفود.

**جهاز حقيقي (لا يُقفل إلا بصورة أو فيديو، `docs/WORKFLOW.md`):**

1. «اتجه» من الخريطة إلى نقطة في البر: الخريطة مائلة دافئة مثل الطلعة، وسيارتي، والسرعة وحدّ الشارع.
2. «باتجاهي»، ثم سحب، ثم «رجّعني للتوجيه».
3. CarPlay (محاكي CarPlay ثم سيارة): القالب والمناورات.
4. Live Activity: شاشة القفل والجزيرة الديناميكية بالمناورة التالية والمسافة والوصول.
5. قفل الشاشة 10 دقائق والمسار مستمر.
6. «طريق الرجعة» من البر بلا نت: يتتبع الدرب حرفيًا.
7. لا طلب واحد إلى خادم سرى (Charles/Proxyman) طوال المشوار.

### التقدير التقريبي

| الخطوة | الحجم |
|---|---|
| ١. `Kind` و`isLocal` (بلا سلوك جديد) | صغير إلى متوسط، يوم واحد (مراجعة 129 موضعًا) |
| ٢. `OutingSession.solo` + حارس `OutingsAPI` + اختبارات | متوسط، يوم إلى يومين |
| ٣. `openSolo` + `LocalPlanBackend` + الخلفيات لكل معرّف + ربط «اتجه» | متوسط، يومان |
| ٤. `LiveScreenRules.solo` (الإخفاء) + طوارئ ٩١١ + نص المشاركة | متوسط، يومان |
| ٥. Live Activity (`solo`) + CarPlay (البلاغ والتحدث) | صغير، يوم واحد |
| ٦. `SoloOutingStore` في «طلعاتي» + الملخص + حذف الحساب (منسّق مع وكيل الرئيسية) | متوسط، يوم إلى يومين |
| ٧. مشوار الرجعة الفردي | صغير، يوم واحد |
| ٨. إزالة `StandaloneNavScreen` و`StandaloneNavRules` واختباراتها في `HomeFlowTests` | صغير، نصف يوم |

**المجموع:** 9 إلى 12 يوم عمل للكود والاختبار على المحاكي، ثم جولة جهاز حقيقي. هذا يناسب Build 40 إلى 41، كما في مراحل #157.

### خطة التنفيذ (PR لكل خطوة، بالترتيب)

1. **`OutingSession.Kind` و`isLocal`:** لا سلوك جديد. كل `isDemo` يعني «بلا خادم» يصير `isLocal`. اختبارات `-demo` كلها خضراء كخط أساس.
2. **`OutingSession.solo(…)` و`SoloOuting.view`، وحارس `OutingsAPI` لمعرّفات `solo-`:** وحدة فقط، ولا نقطة دخول بعد.
3. **`AppModel.openSolo(to:)` و`LocalPlanBackend`، و`PlanCenter`/`featuresBackend` لكل معرّف، ووسيط `-SarySolo`:** الشاشة الحية تفتح فرديةً من وسيط التشغيل فقط، والتوجيه يبدأ وحده.
4. **`LiveScreenRules.solo`:** إخفاء عناصر المجموعة، وطوارئ ٩١١، و«على جوالك فقط»، و«أنهِ المشوار». مع اختبارات الواجهة.
5. **Live Activity وCarPlay:** `shouldRun(solo:)`، وحقل `solo` في الحالة والودجت، و`carPlayStuckReportSupported`، وتوجيه رابط النشاط.
6. **ربط «اتجه» في `MapHomeScreen` بـ`openSolo`** (بدل `cover = .nav`)، ودمج `SoloOutingStore` في «طلعاتي»، والحذف مع الحساب. **منسّق مع وكيل `Home/`.**
7. **مشوار الرجعة الفردي:** فرع محلي في `startReturnTrip`.
8. **إزالة `StandaloneNavScreen`** و`StandaloneNavRules` وكل ما لا يستعمله غيرهما، بعد أن يثبت ٦ على الجهاز. (`NavProviders.standard()` ينتقل إلى `NavRouting.swift` لأن `LiveOutingController.navProvider` يستعمله.)

كل خطوة قابلة للدمج وحدها، ولا تغيّر سلوك الطلعة الحقيقية ولا العرض. الخطوات ١ إلى ٥ لا تلمس `Home/` ولا `Explore/` ولا `Core/TripProgress.swift`.
