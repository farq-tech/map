import { usePageMeta } from "../../lib/usePageMeta";
import { useSaryChrome } from "../../lib/sary/useSaryChrome";
import "../../styles/outings.css";

/* Privacy policy for «طلعة مشتركة» on the web and the «سَرى البارق» iPhone app.
 * Every statement here describes what the API actually does (apps/api/lib/outings);
 * change the text when that behaviour changes. */

const UPDATED = "٤ نوفمبر ٢٠٢٦";
const CONTACT = "farqtechservices@gmail.com";

const SECTIONS: Array<{ title: string; items: string[] }> = [
	{
		title: "ما نجمعه",
		items: [
			"اسمك كما تكتبه (حتى ٤٠ حرفًا). لا نطلب كلمة مرور ولا بريدًا إلكترونيًا.",
			"صورتك ورقم جوالك إن اخترت إضافتهما فقط، ويظهران لأعضاء طلعاتك وحدهم.",
			"مفتاح هوية يُحفظ على جهازك. نخزّن عندنا بصمته المشفرة (SHA-256) لا المفتاح نفسه.",
			"موقعك: آخر موقع فقط لكل عضو، بلا سجلّ للمسار، ويُرسَل فقط وأنت داخل طلعة جارية، وبعد أن تضغط «شارك موقعي»، والتطبيق مفتوح أمامك. لا نرسل موقعك والتطبيق في الخلفية.",
		],
	},
	{
		title: "ما يُحذف تلقائيًا",
		items: [
			"آخر موقعك يُحذف عند إيقاف المشاركة أو مغادرة الطلعة أو إزالتك منها أو انتهائها.",
			"العبارات فوق السيارة تبقى ١٥ دقيقة في ذاكرة الخادم ولا تُكتب في قاعدة البيانات.",
			"الرسائل الصوتية تبقى ١٠ دقائق في ذاكرة الخادم ثم تُحذف، وتُحذف قبل ذلك إذا انتهت الطلعة.",
			"روابط الدعوة تنتهي صلاحيتها، ونخزّن بصمتها المشفرة فقط.",
		],
	},
	{
		title: "من يرى بياناتك",
		items: [
			"أعضاء الطلعة النشطون فقط يرون اسمك وموقعك وعباراتك أثناء الطلعة. يتحقق الخادم من العضوية في كل طلب.",
			"الطوارئ (SOS) تُرسل لأعضاء طلعتك مع موقعك إن كانت المشاركة مفعّلة.",
			"لا نبيع بياناتك ولا نشاركها مع معلنين.",
		],
	},
	{
		title: "مزودو الخدمة",
		items: [
			"الخرائط من Mapbox. يرسل تطبيق الآيفون إلى Mapbox بيانات استخدام مجهولة افتراضيًا، ويمكنك إيقافها من إعدادات الخصوصية في التطبيق.",
			"الإشعارات عبر خدمة إشعارات Apple على الآيفون، وخدمة إشعارات المتصفح على الويب. محتوى الإشعار نص قصير فقط.",
			"الخادم وقاعدة البيانات مستضافان لدى مزودي استضافة سحابية ويُتصل بهما عبر اتصال مشفّر.",
		],
	},
	{
		title: "الخرائط بدون إنترنت",
		items: ["المناطق التي تنزّلها تُحفظ على جهازك فقط، وتستطيع حذفها متى شئت من التطبيق."],
	},
	{
		title: "حذف حسابك",
		items: [
			"من التطبيق: الإعدادات ← الخصوصية ← «احذف حسابي». يُخرجك ذلك من كل طلعاتك ويحذف موقعك ورقمك وصورتك واشتراكات الإشعارات، ثم يحذف هويتك من الجهاز.",
			"أو راسلنا على البريد أدناه وسنحذفها خلال ٣٠ يومًا.",
		],
	},
	{
		title: "الأطفال",
		items: ["الخدمة غير موجهة لمن هم دون ١٣ عامًا."],
	},
];

export default function PrivacyPolicy() {
	useSaryChrome();
	usePageMeta({
		title: "سياسة الخصوصية · سَرى البارق",
		path: "/privacy",
		robots: "index",
	});

	return (
		<main className="sary-o-page" dir="rtl" lang="ar" data-testid="privacy-policy">
			<header className="sary-o-top sary-o-brand">
				<strong>سياسة الخصوصية — سَرى البارق</strong>
				<p className="sary-o-note">
					تنطبق على «طلعة مشتركة» في موقع الويب وعلى تطبيق «سَرى البارق» للآيفون. آخر تحديث: {UPDATED}.
				</p>
			</header>
			{SECTIONS.map((s) => (
				<section key={s.title} className="sary-o-card">
					<h2>{s.title}</h2>
					<ul style={{ listStyle: "disc", paddingInlineStart: "1.2em", display: "grid", gap: "8px", margin: 0 }}>
						{s.items.map((t) => (
							<li key={t}>{t}</li>
						))}
					</ul>
				</section>
			))}
			<section className="sary-o-card">
				<h2>تواصل معنا</h2>
				<p>
					لأي سؤال عن خصوصيتك أو لطلب حذف بياناتك: <a href={`mailto:${CONTACT}`}>{CONTACT}</a>
				</p>
			</section>
		</main>
	);
}
