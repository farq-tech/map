import type { OutingStatus } from "../../lib/outings/api";
import type { LiveState } from "../../lib/outings/live";

export function statusLabel(s: OutingStatus, isRTL: boolean): string {
	const ar = { created: "ما بدأت", active: "جارية", paused: "متوقفة مؤقتًا", ended: "انتهت" };
	const en = { created: "Not started", active: "Live", paused: "Paused", ended: "Ended" };
	return (isRTL ? ar : en)[s];
}

export function liveStateLabel(s: LiveState, isRTL: boolean): string {
	const ar = { connecting: "جارٍ الاتصال…", live: "متصل", polling: "اتصال محدود", offline: "بلا إنترنت", closed: "مغلق" };
	const en = { connecting: "Connecting…", live: "Connected", polling: "Limited connection", offline: "Offline", closed: "Closed" };
	return (isRTL ? ar : en)[s];
}
