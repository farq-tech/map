# Draft — permission request to Mapbox (for the owner to send himself)

> Internal draft. **Nothing has been sent.** Fill the bracketed fields, attach the Order /
> account details, and send from the company's own address to your Mapbox account manager
> (or via https://www.mapbox.com/contact/sales). Keep the reply with the Order documents.

---

## English

**Subject:** Written permission request — on-device display enhancement of Mapbox Satellite tiles (Sary Albarq iOS app, account [ACCOUNT / ORDER ID])

Dear Mapbox team,

We are [COMPANY LEGAL NAME], the publisher of «سَرى البارق» (Sary Albarq), an iOS app for group outdoor trips in Saudi Arabia built on the Mapbox Maps SDK for iOS v11 and the Navigation SDK v3 under account [ACCOUNT / ORDER ID].

In desert areas, Mapbox Satellite imagery stops getting sharper at about z17, and in cities at about z19. Past those levels it is up-sampled. We would like your **written permission**, as an amendment to our Order, for the following narrowly scoped use:

1. **What:** when the map is zoomed in past those levels, the app runs an open-source super-resolution model (Real-ESRGAN x4plus, BSD-3-Clause) **on the user's device only**. It enhances the satellite tile on screen for display and shows the result as a raster layer over the Mapbox basemap, with the Mapbox logo and attribution unchanged.
2. **No storage or redistribution:** enhanced and original tiles are kept **in memory only** while they are on screen. Nothing is written to disk, uploaded, proxied, shared between users or devices, or exported. Nothing is used to **train, fine-tune or evaluate** any model.
3. **Tile access:** to feed the SDK's `CustomRasterSource`, the app requests the parent raster tile (`mapbox.satellite`, @2x) from api.mapbox.com with our public token. Each request counts toward our usage as normal.
4. **Safety limits:** the enhancement never runs during turn-by-turn navigation, track following, SOS, or when the device moves faster than 15 km/h. In those cases the original imagery is always shown. Enhanced tiles carry an on-map «مُحسّنة» ("enhanced") badge, and holding the badge shows the original imagery.
5. **Control:** a server-side switch can turn the feature off for all users immediately, and each user can turn it off in the app's settings.

We understand that the Mapbox Product Terms (version of 20 October 2026) restrict modifying or creating derived works from the Service Offerings and using them to operate machine-learning systems (§1.5(i)–(ii)), using satellite imagery to enhance imagery (§2.8.2), caching and redistribution (§2.8.1), and accessing the Service Offerings other than through the Mobile SDKs (§2.9.1). We are asking for an explicit written exception that covers the use above, together with any conditions you require: attribution wording, regions, zoom limits, volume, or fees.

If this use cannot be permitted, please tell us, and we will keep the feature switched off. We would also welcome any supported alternative, such as higher-resolution imagery products for Saudi Arabia.

Kind regards,
[NAME]
[TITLE], [COMPANY]
[EMAIL] · [PHONE]

---

## العربية

**الموضوع:** طلب إذن كتابي لتحسين عرض صور Mapbox Satellite على جهاز المستخدم (تطبيق «سَرى البارق»، الحساب [رقم الحساب / الطلب])

فريق Mapbox المحترم،

نحن [الاسم القانوني للشركة]، ناشرو تطبيق «سَرى البارق» على iOS. يخدم التطبيق رحلات البر الجماعية في السعودية، ومبني على Mapbox Maps SDK v11 وNavigation SDK v3 ضمن الحساب [رقم الحساب / الطلب].

تتوقف صور Mapbox Satellite عن الازدياد في الوضوح عند المستوى z17 تقريباً في المناطق الصحراوية، وعند z19 تقريباً في المدن، وما بعد ذلك تكبير للصورة نفسها. نطلب **إذناً كتابياً** يُضاف تعديلاً على الطلب (Order)، ويقتصر على الاستخدام التالي:

1. **الاستخدام:** عند التقريب إلى ما بعد هذه المستويات، يشغّل التطبيق نموذج تكبير مفتوح المصدر (Real-ESRGAN x4plus، برخصة BSD-3-Clause) **على جهاز المستخدم فقط**. يحسّن النموذج البلاطة الظاهرة على الشاشة لغرض العرض، وتُعرض النتيجة طبقةً فوق خريطة Mapbox، مع بقاء شعار Mapbox والإسناد كما هما.
2. **لا تخزين ولا توزيع:** تبقى البلاطات المحسّنة والأصلية **في الذاكرة فقط** ما دامت ظاهرة على الشاشة. لا يُكتب شيء منها على القرص، ولا يُرفع إلى أي خادم، ولا يمر عبر وسيط، ولا يُشارك بين المستخدمين أو الأجهزة، ولا يُصدَّر. ولا يُستخدم أي منها في **تدريب** أي نموذج أو ضبطه أو تقييمه.
3. **الوصول إلى البلاطات:** لتغذية `CustomRasterSource` في الـ SDK، يطلب التطبيق البلاطة الأم (`mapbox.satellite` بدقة @2x) من api.mapbox.com بالمفتاح العام الخاص بنا. ويُحتسب كل طلب ضمن استهلاكنا المعتاد.
4. **حدود السلامة:** لا يعمل التحسين أبداً أثناء الملاحة خطوة بخطوة، ولا أثناء تتبّع مسار، ولا في حالة الطوارئ (SOS)، ولا عندما تتجاوز سرعة الجهاز 15 كم/س، وتُعرض الصورة الأصلية دائماً في هذه الحالات. تظهر على الخريطة شارة «مُحسّنة» كلما كانت البلاطات المحسّنة معروضة، والضغط المطوّل عليها يعرض الصورة الأصلية.
5. **التحكم:** لدينا مفتاح على الخادم يوقف الميزة لجميع المستخدمين فوراً، ويستطيع كل مستخدم إيقافها من إعدادات التطبيق.

ندرك أن شروط منتجات Mapbox (نسخة 20 أكتوبر 2026) تقيّد ما يلي: تعديل الخدمات أو إنشاء أعمال مشتقة منها، واستخدامها في تشغيل أنظمة تعلّم الآلة (البند 1.5(i) و(ii)). واستخدام صور الأقمار الصناعية في تحسين الصور (البند 2.8.2). والتخزين المؤقت وإعادة التوزيع (البند 2.8.1). والوصول إلى الخدمات بغير الـ Mobile SDKs (البند 2.9.1). لذلك نطلب استثناءً كتابياً صريحاً يغطي الاستخدام الموصوف أعلاه، مع أي شروط تطلبونها، سواء في صيغة الإسناد أو المناطق أو حدود التقريب أو حجم الاستخدام أو الرسوم.

إن تعذّر السماح بهذا الاستخدام فنرجو إبلاغنا، وسنُبقي الميزة متوقفة. ونرحب كذلك بأي بديل تدعمونه، كمنتجات صور أعلى دقة تغطي السعودية.

مع التحية،
[الاسم]
[المسمى الوظيفي]، [الشركة]
[البريد] · [الجوال]
