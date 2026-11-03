import { formatNumber } from "../sary/domain";

/** «ينتهي بعد ٢٣ ساعة» — an invite's remaining life, in words a person reads at a glance. */
export function expiresIn(expiresAt: string | number | Date, isRTL: boolean, now = Date.now()): string {
	const ms = new Date(expiresAt).getTime() - now;
	if (!Number.isFinite(ms) || ms <= 0) return isRTL ? "انتهت صلاحيته" : "expired";
	const min = Math.max(1, Math.round(ms / 60_000));
	if (min < 60) return isRTL ? `ينتهي بعد ${formatNumber(min, true)} دقيقة` : `expires in ${min} min`;
	const h = Math.round(min / 60);
	if (h < 48) return isRTL ? `ينتهي بعد ${formatNumber(h, true)} ساعة` : `expires in ${h} h`;
	const d = Math.round(h / 24);
	return isRTL ? `ينتهي بعد ${formatNumber(d, true)} أيام` : `expires in ${d} days`;
}
