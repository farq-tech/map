# نظام العمل: من يكتب، ومن يدمج، ومن يبني

قرار المالك (2026-11-11): **وكيل الماك هو الوحيد الذي يدمج ويبني ويرفع TestFlight.** كل من عداه مطوّر محسّن: يكتب كودًا ويدفعه إلى فرعه، ولا يدمج.

## الأدوار

| الدور | يسوي | لا يسوي أبدًا |
|---|---|---|
| **المطوّر المحسّن** (وكلاء السحابة وأي جلسة تكتب كودًا) | فرع لكل مرحلة، من `origin/main`، وPR إلى `main`. تعليق على PR فيه ما تغيّر وكيف يُختبر | يدمج PR. يغيّر رقم البناء (`CURRENT_PROJECT_VERSION`). يرفع TestFlight. يدفع إلى فرع في وضع «تجميد». يعدّل `docs/BUILDS.md` |
| **وكيل الدمج** (جلسة الماك) | يسحب، يبني، يختبر، يصلح أخطاء الترجمة بأقل تعديل (commit لكل إصلاح)، يدمج، يحجز رقم البناء، يبني الأرشيف ويرفعه | يغيّر تصميمًا أو سلوكًا بدون قرار المالك |
| **المالك** | يقرر ما يدخل البناء. يجري بنود الجهاز الحقيقي | — |

## دورة الدمج

1. **جاهز للاختبار:** المطوّر يكتب تعليقًا على PR: «جاهز، آخر commit `<sha>`».
2. **تجميد:** وكيل الدمج يسجّل الـSHA في PR ويعلن التجميد. لا أحد يدفع إلى الفرع بعدها.
3. **بناء واختبار** على ذلك الـSHA فقط: وحدة كاملة، ثم الواجهة على دفعات. كل فشل يقارَن بـ`docs/TEST-BASELINE.md`؛ الفشل الجديد وحده يوقف الدمج.
4. **إصلاحات الوكيل:** أخطاء الترجمة وتوقعات الاختبارات التي لم تتبع قرارًا مقصودًا، كل واحد في commit صغير على الفرع نفسه.
5. **دمج** بعد التحقق من قاعدة الـPR (`baseRefName == main`) ثم `git fetch` ثم الدمج.
6. **عمل جديد أثناء التجميد** يذهب إلى دورة لاحقة؛ لا يدخل في الدورة الجارية.

## رقم البناء والبناء

- الرقم يُحجز في `docs/BUILDS.md` قبل أي أرشفة. الرقم التالي = الأكبر بين App Store Connect والسجل، زائد واحد. تخطّي رقم مقبول؛ تكراره غير مقبول.
- البناء يُصدر من فرع `release/buildNN` المقطوع من `main` بعد الدمج. قبل أن يُذكر محتواه لأي أحد: `git fetch` ثم `git merge-base --is-ancestor <PR merge commit> <build commit>` لكل بند.
- انسخ `Config/Secrets.xcconfig` إلى أي worktree جديد، وتأكد قبل الرفع أن `MBXAccessToken` في الأرشيف يبدأ بـ`pk.`.
- بناء واحد في المرة على الماك، و`-clonedSourcePackagesDirPath ~/code/map-wt/_spm`.

## الجهاز الحقيقي

بنود الجهاز لا تُقفل إلا بصورة أو فيديو من جوال حقيقي. ما لم يُجرَّب يُكتب في PR وفي وصف البناء بصراحة: **«ما انجرّب»**، ولا يُسمّى «نجح» لأن الاختبارات على المحاكي نجحت.

## لقطات كل الشاشات

`UITests/AllScreensShotsUITests.swift` يمرّ على كل شاشة في `docs/SCREENS.md` ببيانات العرض التجريبي (بلا خادم)، ويحفظ لقطة محاكٍ مسمّاة لكل شاشة: `NN-area-SS-screen`، فترتيب الأسماء هو ترتيب التطبيق. الصنف لا يشتغل في التشغيل العادي؛ يتخطّاه `XCTSkipIf` ما لم يكن `SARY_ALL_SHOTS=1`. الشاشة التي لا يوصلها المحاكي (كاميرا، GPS، خادم) تُصوَّر كما هي، ومعها مرفق نصي `<الاسم>-NOTE` يقول السبب، بلا فشل.

التشغيل على iPhone 15 Pro (كل الصنف قرابة ساعة؛ لمنطقة واحدة أضف اسم الدالة، مثل `.../AllScreensShotsUITests/test05Home`):

```sh
cd apps/ios/SaryAlbarq
OUT="$HOME/Desktop/sary-all-screens"; mkdir -p "$OUT"
TEST_RUNNER_SARY_ALL_SHOTS=1 TEST_RUNNER_SARY_SHOTS="$OUT" \
xcodebuild -project SaryAlbarq.xcodeproj -scheme SaryAlbarq \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  -clonedSourcePackagesDirPath ~/code/map-wt/_spm \
  -resultBundlePath /tmp/sary-all-screens.xcresult \
  test -only-testing:SaryAlbarqUITests/AllScreensShotsUITests
```

- `TEST_RUNNER_SARY_SHOTS` يكتب كل لقطة PNG باسمها في `$OUT` مباشرة، وكل ملاحظة `-NOTE.txt` جنبها. هذا أسهل طريق.
- اللقطات نفسها مرفقات `keepAlways` في `xcresult`. لتصديرها من هناك (Xcode 16 أو أحدث):

```sh
xcrun xcresulttool export attachments --path /tmp/sary-all-screens.xcresult --output-path "$OUT/xcresult"
```

  أسماء الملفات المصدّرة معرّفات؛ الاسم المقروء في `manifest.json` (الحقل `suggestedHumanReadableName`).
- حالة كل اختبار: `xcrun xcresulttool get test-results summary --path /tmp/sary-all-screens.xcresult`.

## أين تُكتب الأشياء

- **PR:** تعليق لكل دورة: جدول بالبند والنتيجة والدليل.
- **`docs/STATUS.md`:** وكيل الدمج وحده يحدّثه. المطوّر يكتب ما عنده في تعليق PR.
- **`docs/BUILDS.md`:** أرقام البناء. **`docs/TEST-BASELINE.md`:** الفشل المعروف على `main`.
