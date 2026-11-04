import { Bell, CheckCircle2, Clock, MapPin, Phone, ShieldAlert, XCircle } from "lucide-react";
import { lazy, Suspense, useCallback, useEffect, useMemo, useState } from "react";
import { usePageMeta } from "../../lib/usePageMeta";
import { useSaryChrome } from "../../lib/sary/useSaryChrome";
import {
	WATCH_POLL_MS,
	ago,
	arabicDigits,
	fetchWatchStatus,
	formatDue,
	relativeDue,
	subscribeWatcher,
	takeWatchToken,
	telHref,
	type WatchPushResult,
	type WatchStatus,
} from "../../lib/outings/watch";
import { fetchPushConfig } from "../../lib/outings/push";
import "../../styles/outings.css";

const WatchMap = lazy(() => import("./WatchMap"));

type View =
	| { kind: "loading" }
	| { kind: "invalid" }
	| { kind: "error" }
	| { kind: "status"; status: WatchStatus; at: number; stale?: boolean };

const PUSH_ERRORS: Record<Exclude<WatchPushResult, { ok: true }>["reason"], string> = {
	disabled: "التنبيهات غير متاحة حاليًا. افتح هذه الصفحة بين حين وآخر.",
	denied: "التنبيهات مرفوضة في هذا المتصفح. اسمح بها من إعدادات الموقع.",
	unsupported: "هذا المتصفح لا يدعم التنبيهات.",
	"ios-needs-home-screen": "على الآيفون: اضغط زر المشاركة ← «إضافة إلى الشاشة الرئيسية»، وافتح الرابط من الأيقونة ثم فعّل التنبيه.",
	closed: "انتهى هذا المؤقت، لا حاجة للتنبيه.",
	failed: "تعذّر تفعيل التنبيه. أعد المحاولة.",
};

/**
 * /watch#<token> — «مؤقت الرجوع» for the person outside the outing.
 * Polls every 30 s. Positions only when overdue (the server's snapshot).
 */
export default function WatchPage() {
	useSaryChrome();
	usePageMeta({ title: "مؤقت الرجوع · سَرى البارق", path: "/watch", robots: "noindex, nofollow" });

	const [token] = useState<string | null>(() => (typeof window === "undefined" ? null : takeWatchToken()));
	const [view, setView] = useState<View>(() => (token ? { kind: "loading" } : { kind: "invalid" }));
	const [now, setNow] = useState(() => Date.now());
	const [push, setPush] = useState<"hidden" | "offer" | "busy" | "on">("hidden");
	const [pushError, setPushError] = useState<string | null>(null);

	const load = useCallback(async () => {
		if (!token) return;
		const r = await fetchWatchStatus(token);
		if (r.ok) setView({ kind: "status", status: r.status, at: Date.now() });
		else if (r.reason === "invalid") setView({ kind: "invalid" });
		else setView((v) => (v.kind === "status" ? { ...v, stale: true } : { kind: "error" }));
	}, [token]);

	useEffect(() => {
		if (!token) return;
		void load();
		const id = window.setInterval(() => void load(), WATCH_POLL_MS);
		const onVisible = () => document.visibilityState === "visible" && void load();
		document.addEventListener("visibilitychange", onVisible);
		return () => {
			window.clearInterval(id);
			document.removeEventListener("visibilitychange", onVisible);
		};
	}, [token, load]);

	useEffect(() => {
		const id = window.setInterval(() => setNow(Date.now()), 15_000);
		return () => window.clearInterval(id);
	}, []);

	useEffect(() => {
		let alive = true;
		void fetchPushConfig().then((c) => alive && c.enabled && setPush((p) => (p === "hidden" ? "offer" : p)));
		return () => {
			alive = false;
		};
	}, []);

	const status = view.kind === "status" ? view.status : null;
	/* Correct for a wrong phone clock: count from the server's clock. */
	const skew = status?.server_now && view.kind === "status" ? new Date(status.server_now).getTime() - view.at : 0;
	const serverNow = now + skew;
	const live = status?.state === "armed" || status?.state === "overdue";
	const points = useMemo(() => (status?.state === "overdue" ? status.last_known || [] : []), [status]);

	const turnOn = async () => {
		if (!token) return;
		setPush("busy");
		setPushError(null);
		const r = await subscribeWatcher(token);
		if (r.ok) return setPush("on");
		setPush("offer");
		setPushError(PUSH_ERRORS[r.reason]);
	};

	return (
		<main className="sary-o-page sary-watch" dir="rtl" lang="ar" data-testid="watch-page" data-state={status?.state || view.kind}>
			<header className="sary-o-top sary-o-brand">
				<strong>مؤقت الرجوع — سَرى البارق</strong>
			</header>

			{view.kind === "loading" ? <section className="sary-o-card"><p>جارٍ التحميل…</p></section> : null}

			{view.kind === "invalid" ? (
				<section className="sary-o-card" data-testid="watch-invalid">
					<h2>الرابط غير صالح أو انتهى</h2>
					<p className="sary-o-note">اطلب من صاحب الطلعة أن يرسل لك الرابط من جديد.</p>
				</section>
			) : null}

			{view.kind === "error" ? (
				<section className="sary-o-card">
					<h2>تعذّر الاتصال</h2>
					<p className="sary-o-note">سنحاول مرة أخرى تلقائيًا كل ٣٠ ثانية.</p>
				</section>
			) : null}

			{status ? (
				<>
					<section className={`sary-o-card sary-watch-hero sary-watch-${status.state}`} data-testid="watch-hero">
						<div className="sary-watch-icon" aria-hidden>
							{status.state === "armed" ? <Clock /> : status.state === "overdue" ? <ShieldAlert /> : status.state === "arrived" ? <CheckCircle2 /> : <XCircle />}
						</div>
						<p className="sary-o-note">
							يا {status.contact_name}، {status.owner_name} في «{status.outing_name}»
						</p>
						{status.state === "armed" ? (
							<>
								<h1>متوقع رجوعهم {formatDue(status.due_at, serverNow)}</h1>
								<p className="sary-watch-rel">{relativeDue(status.due_at, serverNow)}</p>
								<p className="sary-o-note">إذا لم يضغطوا «وصلت» قبل هذا الوقت ستتغير هذه الصفحة وتظهر آخر مواقعهم المعروفة.</p>
							</>
						) : null}
						{status.state === "overdue" ? (
							<>
								<h1>تأخروا عن وقت الرجوع</h1>
								<p className="sary-watch-rel">كان المتوقع {formatDue(status.due_at, serverNow)} — {relativeDue(status.due_at, serverNow)}</p>
								<p className="sary-o-note">قد يكون السبب ضعف الشبكة فقط. حاول الاتصال، وإن لم تصل إليهم فتواصل مع الجهات المختصة (٩١١).</p>
							</>
						) : null}
						{status.state === "arrived" ? <h1>وصلوا بالسلامة</h1> : null}
						{status.state === "cancelled" ? <h1>أُلغي مؤقت الرجوع</h1> : null}
					</section>

					{status.state === "overdue" ? (
						<section className="sary-o-card" data-testid="watch-overdue">
							{telHref(status.owner_phone) ? (
								<a className="sary-o-primary sary-watch-call" href={telHref(status.owner_phone) || undefined} data-testid="watch-call">
									<Phone className="inline size-5" aria-hidden /> اتصل بـ{status.owner_name}
								</a>
							) : null}
							<h2>
								<MapPin className="inline size-4" aria-hidden /> آخر موقع معروف
							</h2>
							{points.length ? (
								<>
									<p className="sary-o-note">هذه المواقع لحظة التأخر، وليست مباشرة.</p>
									<Suspense fallback={null}>
										<WatchMap points={points} />
									</Suspense>
									<ul className="sary-watch-list">
										{points.map((p) => (
											<li key={`${p.name}-${p.at}`}>
												<strong>{p.name}</strong> <span className="sary-o-note">{ago(p.at, serverNow)}</span>
												<a href={`https://maps.apple.com/?q=${p.lat},${p.lng}`} target="_blank" rel="noreferrer noopener" dir="ltr">
													<bdi>{arabicDigits(p.lat.toFixed(5))}</bdi>, <bdi>{arabicDigits(p.lng.toFixed(5))}</bdi>
												</a>
											</li>
										))}
									</ul>
								</>
							) : (
								<p className="sary-o-note">لا يوجد موقع معروف: لم يكن أحد يشارك موقعه لحظة التأخر.</p>
							)}
						</section>
					) : null}

					{live && status.members.length ? (
						<section className="sary-o-card">
							<h2>في الطلعة ({arabicDigits(status.members.length)})</h2>
							<p>{status.members.map((m) => m.name).join("، ")}</p>
						</section>
					) : null}

					{live && push !== "hidden" ? (
						<section className="sary-o-card" data-testid="watch-push">
							{push === "on" ? (
								<p>
									<Bell className="inline size-4" aria-hidden /> سننبّهك إذا تأخروا أو وصلوا.
								</p>
							) : (
								<button type="button" className="sary-o-primary" disabled={push === "busy"} onClick={() => void turnOn()} data-testid="watch-push-enable">
									<Bell className="inline size-4" aria-hidden /> نبّهني إذا تأخروا
								</button>
							)}
							{pushError ? <p className="sary-o-error" role="alert">{pushError}</p> : null}
						</section>
					) : null}

					{view.kind === "status" && view.stale ? (
						<p className="sary-o-error" role="status" data-testid="watch-stale">
							تعذّر التحديث — المعروض آخر ما وصلنا {ago(new Date(view.at).toISOString(), now)}. سنعيد المحاولة.
						</p>
					) : null}
					<p className="sary-o-note sary-watch-foot">
						تتحدث الصفحة كل ٣٠ ثانية. لا تظهر المواقع إلا بعد التأخر. <a href="/privacy">الخصوصية</a>
					</p>
				</>
			) : null}
		</main>
	);
}
