import { Bell, BellOff } from "lucide-react";
import { useEffect, useState } from "react";
import { currentSubscription, disablePush, enablePush, fetchPushConfig, isIOS, pushSupport, readPushEnv, type PushSupport } from "../../lib/outings/push";

type State = "loading" | "off-server" | "on" | "off" | PushSupport;

/**
 * «فعّل التنبيهات» — a note or an SOS reaches this phone while its screen is
 * off. On iPhone this works only from the home-screen app (iOS 16.4+), so a
 * Safari tab gets the steps instead of a button that cannot work.
 */
export function PushRow({ isRTL }: { isRTL: boolean }) {
	const [state, setState] = useState<State>("loading");
	const [busy, setBusy] = useState(false);
	const [error, setError] = useState<string | null>(null);

	useEffect(() => {
		let alive = true;
		(async () => {
			const cfg = await fetchPushConfig();
			if (!alive) return;
			if (!cfg.enabled) return setState("off-server");
			const support = pushSupport(readPushEnv());
			if (support !== "available") return setState(support);
			const sub = await currentSubscription();
			if (alive) setState(sub && Notification.permission === "granted" ? "on" : "off");
		})();
		return () => {
			alive = false;
		};
	}, []);

	/* Server without VAPID keys: say nothing rather than offer a dead switch. */
	if (state === "loading" || state === "off-server") return null;

	const turnOn = async () => {
		setBusy(true);
		setError(null);
		const r = await enablePush();
		setBusy(false);
		if (r.ok) return setState("on");
		if (r.reason === "denied") return setState("denied");
		if (r.reason === "disabled") return setState("off-server");
		setError(isRTL ? "تعذّر تفعيل التنبيهات. أعد المحاولة." : "Could not turn on notifications. Try again.");
	};
	const turnOff = async () => {
		setBusy(true);
		await disablePush();
		setBusy(false);
		setState("off");
	};

	const ios = typeof navigator !== "undefined" && isIOS(navigator.userAgent, navigator.maxTouchPoints);

	return (
		<div className="sary-o-push" data-testid="outing-push" data-state={state}>
			<div className="sary-o-push-head">
				<strong>
					{state === "on" ? <Bell className="inline size-4" aria-hidden /> : <BellOff className="inline size-4" aria-hidden />}{" "}
					{state === "on" ? (isRTL ? "التنبيهات مفعّلة" : "Notifications on") : isRTL ? "فعّل التنبيهات" : "Turn on notifications"}
				</strong>
				{state === "off" ? (
					<button type="button" className="sary-o-primary" disabled={busy} onClick={() => void turnOn()} data-testid="outing-push-enable">
						{isRTL ? "فعّل التنبيهات" : "Turn on"}
					</button>
				) : state === "on" ? (
					<button type="button" className="sary-o-secondary" disabled={busy} onClick={() => void turnOff()} data-testid="outing-push-disable">
						{isRTL ? "إيقاف" : "Turn off"}
					</button>
				) : null}
			</div>
			<p className="sary-o-note">
				{isRTL
					? "تصلك رسائل أصحابك ونداء الاستغاثة حتى والشاشة مطفأة. لا يُرسل موقعك في التنبيهات."
					: "Friends' notes and SOS reach you even with the screen off. Your location is never sent in a notification."}
			</p>
			{state === "ios-needs-home-screen" ? (
				<>
					<p className="sary-o-note" data-testid="outing-push-ios">
						{isRTL
							? "على الآيفون تعمل التنبيهات فقط من أيقونة التطبيق على الشاشة الرئيسية (iOS 16.4 أو أحدث):"
							: "On iPhone, notifications work only from the home-screen icon (iOS 16.4 or later):"}
					</p>
					<ol>
						<li>{isRTL ? "اضغط زر المشاركة في Safari" : "Tap Share in Safari"}</li>
						<li>{isRTL ? "اختر «إضافة إلى الشاشة الرئيسية»" : "Choose “Add to Home Screen”"}</li>
						<li>{isRTL ? "افتح سَرى من الأيقونة الجديدة ثم فعّل التنبيهات من هنا" : "Open Sary from the new icon, then turn on notifications here"}</li>
					</ol>
				</>
			) : null}
			{state === "denied" ? (
				<p className="sary-o-note" data-testid="outing-push-denied">
					{ios
						? isRTL ? "التنبيهات مرفوضة. فعّلها من الإعدادات ← الإشعارات ← سَرى." : "Notifications are blocked. Allow them in Settings → Notifications → Sary."
						: isRTL ? "التنبيهات مرفوضة. اسمح بها من إعدادات الموقع في المتصفح." : "Notifications are blocked. Allow them in the browser's site settings."}
				</p>
			) : null}
			{state === "unsupported" ? (
				<p className="sary-o-note">{isRTL ? "هذا المتصفح لا يدعم التنبيهات." : "This browser does not support notifications."}</p>
			) : null}
			{error ? <p className="sary-o-error" role="alert">{error}</p> : null}
		</div>
	);
}
