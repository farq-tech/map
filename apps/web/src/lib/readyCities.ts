/**
 * "Ready" (supported) Saudi cities shown as labeled pins on the delivery-address
 * map picker, so the shopper can see where Farq operates and tap one to jump
 * there. Names mirror the Arabic set in cityNames.ts; coordinates are the city
 * centers (WGS84). Keep this list in sync with launch coverage.
 */
export interface ReadyCity {
	key: string;
	nameAr: string;
	nameEn: string;
	lat: number;
	lng: number;
}

export const READY_CITIES: ReadyCity[] = [
	{
		key: "riyadh",
		nameAr: "الرياض",
		nameEn: "Riyadh",
		lat: 24.7136,
		lng: 46.6753,
	},
	{
		key: "jeddah",
		nameAr: "جدة",
		nameEn: "Jeddah",
		lat: 21.4858,
		lng: 39.1925,
	},
	{
		key: "makkah",
		nameAr: "مكة المكرمة",
		nameEn: "Makkah",
		lat: 21.3891,
		lng: 39.8579,
	},
	{
		key: "madinah",
		nameAr: "المدينة المنورة",
		nameEn: "Madinah",
		lat: 24.5247,
		lng: 39.5692,
	},
	{
		key: "dammam",
		nameAr: "الدمام",
		nameEn: "Dammam",
		lat: 26.4207,
		lng: 50.0888,
	},
	{
		key: "khobar",
		nameAr: "الخبر",
		nameEn: "Al Khobar",
		lat: 26.2794,
		lng: 50.2083,
	},
	{
		key: "dhahran",
		nameAr: "الظهران",
		nameEn: "Dhahran",
		lat: 26.2886,
		lng: 50.114,
	},
	{
		key: "jubail",
		nameAr: "الجبيل",
		nameEn: "Jubail",
		lat: 27.0046,
		lng: 49.6583,
	},
	{
		key: "qatif",
		nameAr: "القطيف",
		nameEn: "Qatif",
		lat: 26.5205,
		lng: 49.9899,
	},
	{
		key: "ahsa",
		nameAr: "الأحساء",
		nameEn: "Al Ahsa",
		lat: 25.3833,
		lng: 49.5867,
	},
	{ key: "taif", nameAr: "الطائف", nameEn: "Taif", lat: 21.2703, lng: 40.4158 },
	{
		key: "buraidah",
		nameAr: "بريدة",
		nameEn: "Buraidah",
		lat: 26.326,
		lng: 43.975,
	},
	{
		key: "unaizah",
		nameAr: "عنيزة",
		nameEn: "Unaizah",
		lat: 26.0843,
		lng: 43.9935,
	},
	{ key: "hail", nameAr: "حائل", nameEn: "Hail", lat: 27.5114, lng: 41.7208 },
	{ key: "tabuk", nameAr: "تبوك", nameEn: "Tabuk", lat: 28.3838, lng: 36.555 },
	{ key: "abha", nameAr: "أبها", nameEn: "Abha", lat: 18.2164, lng: 42.5053 },
	{
		key: "khamis-mushait",
		nameAr: "خميس مشيط",
		nameEn: "Khamis Mushait",
		lat: 18.3,
		lng: 42.7333,
	},
	{
		key: "najran",
		nameAr: "نجران",
		nameEn: "Najran",
		lat: 17.4917,
		lng: 44.1322,
	},
	{
		key: "jazan",
		nameAr: "جازان",
		nameEn: "Jazan",
		lat: 16.8892,
		lng: 42.5511,
	},
	{ key: "yanbu", nameAr: "ينبع", nameEn: "Yanbu", lat: 24.0895, lng: 38.0637 },
	{
		key: "kharj",
		nameAr: "الخرج",
		nameEn: "Al Kharj",
		lat: 24.1554,
		lng: 47.3346,
	},
];

function haversineKm(
	lat1: number,
	lng1: number,
	lat2: number,
	lng2: number,
): number {
	const toRad = (d: number) => (d * Math.PI) / 180;
	const R = 6371;
	const dLat = toRad(lat2 - lat1);
	const dLng = toRad(lng2 - lng1);
	const a =
		Math.sin(dLat / 2) ** 2 +
		Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
	return 2 * R * Math.asin(Math.min(1, Math.sqrt(a)));
}

/** Nearest launch-coverage city key for difference-rail city scoping. */
export function nearestReadyCity(
	lat: number | null | undefined,
	lng: number | null | undefined,
): ReadyCity | null {
	if (
		lat == null ||
		lng == null ||
		!Number.isFinite(lat) ||
		!Number.isFinite(lng)
	) {
		return null;
	}
	let best: ReadyCity | null = null;
	let bestKm = Number.POSITIVE_INFINITY;
	for (const city of READY_CITIES) {
		const km = haversineKm(lat, lng, city.lat, city.lng);
		if (km < bestKm) {
			bestKm = km;
			best = city;
		}
	}
	// Cap so a pin far outside KSA doesn't invent a fake "city" filter.
	if (!best || bestKm > 120) return null;
	return best;
}
