import { usePageMeta } from "../../lib/usePageMeta";
import { useSaryChrome } from "../../lib/sary/useSaryChrome";
import "../../styles/outings.css";

/* الدعم — the App Store "Support URL" for the «سَرى البارق» iPhone app.
 * Keep every answer true to what the app does today (same rule as PrivacyPolicy.tsx). */

const CONTACT = "farqtechservices@gmail.com";

const FAQ: Array<{ q: string; a: string }> = [
	{
		q: "كيف أبدأ طلعة وأدعو العيال؟",
		a: "من التطبيق اضغط «طلعة جديدة»، سمّها، ثم أرسل الدعوة للعيال (واتساب أو رسالة). من يفتح الرابط ينضم من التطبيق، أو من المتصفح إن ما كان عنده التطبيق.",
	},
	{
		q: "من يشوف موقعي؟ وكيف أوقف المشاركة؟",
		a: "أعضاء الطلعة اللي انضممت لها فقط، وما دامت الطلعة شغّالة. بانضمامك يشوفون موقعك المباشر، ولإيقاف المشاركة غادر الطلعة (أو تنتهي الطلعة). التفاصيل في سياسة الخصوصية.",
	},
	{
		q: "ليش يطلب التطبيق الموقع «دائمًا»؟",
		a: "عشان يستمر العيال يشوفونك والشاشة مقفلة أثناء الطلعة، ويظهر مؤشر الموقع الأزرق طول الوقت. تقدر تختار «أثناء الاستخدام» فقط، وتتوقف المشاركة وقتها إذا قفلت الشاشة.",
	},
	{
		q: "«قناة الطلعة» (اضغط وتكلم) ما تشتغل",
		a: "تأكد إنك سمحت للتطبيق بالمايكروفون من الإعدادات، وإن عندك إنترنت. الصوت يوصل لأعضاء الطلعة لحظة كلامك فقط ولا يُحفظ.",
	},
	{
		q: "كيف أستخدم الخرائط بدون إنترنت؟",
		a: "قبل الطلعة: الإعدادات ← «الخرائط بلا إنترنت» ← «حمّل منطقة»، واختر المنطقة وهي على واي فاي.",
	},
	{
		q: "كيف أحذف حسابي؟",
		a: "من التطبيق: الإعدادات ← الخصوصية ← «احذف حسابي». أو راسلنا على البريد أدناه ونحذفه خلال ٣٠ يومًا.",
	},
	{
		q: "زر الطوارئ و«اطلب إنجاد»",
		a: "زر SOS ينبّه أعضاء طلعتك. «اطلب إنجاد» يجهّز رسالة لجمعية إنجاد التطوعية ترسلها أنت بنفسك من واتساب أو الرسائل؛ التطبيق لا يرسل شيئًا تلقائيًا ولا يتبع لإنجاد. في الطوارئ اتصل ٩١١ / ٩٩٧ / ٩٩٨.",
	},
];

export default function SupportPage() {
	useSaryChrome();
	usePageMeta({
		title: "الدعم · سَرى البارق",
		path: "/support",
		robots: "index",
	});

	return (
		<main className="sary-o-page" dir="rtl" lang="ar" data-testid="support-page">
			<header className="sary-o-top sary-o-brand">
				<strong>الدعم — سَرى البارق</strong>
				<p className="sary-o-note">
					عندك سؤال أو مشكلة في التطبيق؟ راسلنا ونرد عليك في أقرب وقت.
				</p>
			</header>
			<section className="sary-o-card">
				<h2>تواصل معنا</h2>
				<p>
					البريد: <a href={`mailto:${CONTACT}`}>{CONTACT}</a>
				</p>
				<p className="sary-o-note">
					اذكر نوع جوالك ونسخة iOS ووصف المشكلة، وصورة شاشة إن أمكن. لا ترسل رمز الاسترجاع لأي أحد.
				</p>
			</section>
			<section className="sary-o-card">
				<h2>أسئلة شائعة</h2>
				<dl style={{ display: "grid", gap: "12px", margin: 0 }}>
					{FAQ.map((f) => (
						<div key={f.q}>
							<dt style={{ fontWeight: 700 }}>{f.q}</dt>
							<dd style={{ margin: 0 }}>{f.a}</dd>
						</div>
					))}
				</dl>
			</section>
			<section className="sary-o-card" lang="en" dir="ltr">
				<h2>Support (English)</h2>
				<p>
					Questions or problems with Sary Albarq? Email <a href={`mailto:${CONTACT}`}>{CONTACT}</a>. To delete
					your account: Settings → Privacy → «احذف حسابي» (Delete my account) in the app, or email us.
				</p>
			</section>
			<p className="sary-o-note">
				<a href="/privacy">سياسة الخصوصية</a>
			</p>
		</main>
	);
}
