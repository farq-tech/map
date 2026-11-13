# مكوّنات الشاشات المشتركة (الواجهة الجديدة، Build 47)

كل شاشة جديدة تُبنى من هذه القطع فقط، ولا تعيد رسم ترويسة أو زر أو حالة فارغة بنفسها.
الملفات: `Sources/UI/Foundations/SaryFoundationComponents.swift` (ترويسة وأزرار) و
`Sources/UI/Components/SaryScreenKit.swift` (الباقي). المعرض: شغّل التطبيق بالمعامل `-SaryComponents`
(اختياري: `-SaryComponentsPage all|header|states|loading|list|chips`, `-SaryComponentsScheme light|dark`,
`-SaryComponentsType AX3`). الألوان والمسافات من `@Environment(\.sary)`، ولا ألوان خام.

## القواعد
- **زر رئيسي واحد** في الشاشة (`SaryPrimaryButton`، إمبر، ارتفاع 58). كل ما سواه ثانوي (`SarySecondaryButton`).
- كل عنصر ضغط ≥ 44 نقطة. الأسماء الطويلة تصغر (`.saryLongName()`) ولا تنقطع بـ«…».
- التحميل بهيكل رمادي (`SarySkeletonList`) لا بدائرة تدور. الحركة تحترم «تقليل الحركة» وتتوقف في وضع القيادة.
- أحجام الخط: ثلاثة بالكثير في الشاشة (`SaryType.withinBudget`).

## الاستخدام

| القطعة | الاستخدام |
|---|---|
| `SaryScreenScaffold(title:onClose:primaryTitle:onPrimary:content:)` | هيكل الشاشة: ترويسة (العنوان يمين، ✕ يسار 44) + محتوى قابل للتمرير + الزر الرئيسي مثبّتًا تحت |
| `SaryWindowTitle(_:onClose:)` | الترويسة وحدها (للأوراق) |
| `SaryPrimaryButton` / `SarySecondaryButton` | الأزرار |
| `SaryScreenState(kind: .empty/.error, systemImage:, message:, actionTitle:)` | حالة فاضية أو خطأ: أيقونة في دائرة + جملة نجدية واحدة (وش صار ووش تسوي) + زر الخطوة الجاية |
| `SarySkeletonList(rows:)` / `SarySkeleton(shape:width:height:)` | هيكل التحميل بارتفاع الصف الحقيقي |
| `SaryListGroup { SaryListRow… }` | مجموعة صفوف بفواصل رفيعة (لا فاصل بعد الأخير) |
| `SaryListRow(title:subtitle:systemImage:trailing:action:)` | صف بارتفاع 56، أيقونة يمين، سهم إفصاح `chevron.forward` (يشير لليسار بالعربي) |
| `SaryChip(title:selected:action:)` | شريحة تصفية، إمبر عند الاختيار، منطقة ضغط 44 |
| `SaryPill(text:tone:)` | حبة حالة: neutral / accent / live / warning / emergency |
| `SaryAvatarStack(people:)` | صور متداخلة مع «+N» |

مثال شاشة:

```swift
SaryScreenScaffold(title: "طلعاتي", onClose: dismiss, primaryTitle: "＋ ابدأ طلعة", onPrimary: start) {
    if loading { SarySkeletonList() }
    else if trips.isEmpty {
        SaryScreenState(kind: .empty, systemImage: "figure.hiking",
                        message: "ما عندك طلعات للحين، سوّ أول طلعة", actionTitle: nil)
    } else {
        SaryListGroup { ForEach(trips) { SaryListRow(title: $0.name, subtitle: $0.summary, systemImage: "flag.fill") { open($0) } } }
    }
}
```

(عند وجود زر رئيسي في الهيكل لا تمرّر `actionTitle` للحالة الفاضية، كي لا يتكرر الزر الرئيسي.)

## ما بقي كما هو (لا خسارة ميزات)
الواجهة القديمة تبقى الافتراضية خلف مفتاح `NewUI`. هذه القطع **إضافة** ولا تحذف شيئًا:

| القديم (باقٍ كما هو) | الجديد |
|---|---|
| `SaryStateView` (تحميل/فاضي/خطأ/بلا إنترنت) | `SaryScreenState` (فاضي/خطأ) + `SarySkeletonList` للتحميل |
| `SarySkeletonRow` | `SarySkeletonList` / `SarySkeleton` |
| `SaryBanner`, `SaryDialog` | بلا تغيير |
| `SaryAvatar` | يُستخدم داخل `SaryAvatarStack` |
| `SaryRowIcon`, `SaryToggleRow` | بلا تغيير |
