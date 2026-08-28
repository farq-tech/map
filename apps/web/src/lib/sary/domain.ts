/**
 * سَرى البارق domain — nature, places, movement.
 * Never invents a kind that the source did not support. Unknown → unconfirmed.
 */

export type NatureKind =
	| "fayad"
	| "rawdah"
	| "wadi"
	| "shaib"
	| "nafud"
	| "dune"
	| "mountain"
	| "rocky"
	| "sabkha"
	| "coast";

export type PlaceKind = "camp" | "picnic" | "well" | "spring" | "landmark";

export type TrackKind = "public_track" | "osm_track" | "observed_track" | "personal_track";

export type EntityKind = NatureKind | PlaceKind | TrackKind;

export type EntityGroup = "nature" | "place" | "movement";

export type Evidence = "public" | "observed" | "mine" | "unconfirmed";

export type OutdoorSource = "osm" | "gps";

export type OutdoorEntity = {
	id: string;
	kind: EntityKind;
	group: EntityGroup;
	name: string | null;
	lng: number;
	lat: number;
	source: OutdoorSource;
	evidence: Evidence;
	license?: "ODbL";
	distanceM?: number | null;
	lengthM?: number | null;
	fclass?: string | null;
};

export const WEAK_GPS_METERS = 50;

export function isWeakGps(accuracyMeters: number | null | undefined): boolean {
	return typeof accuracyMeters === "number" && Number.isFinite(accuracyMeters) && accuracyMeters > WEAK_GPS_METERS;
}

export function isValidLngLat(lng: unknown, lat: unknown): lng is number {
	return (
		typeof lng === "number" &&
		typeof lat === "number" &&
		Number.isFinite(lng) &&
		Number.isFinite(lat) &&
		lng >= 34 &&
		lng <= 56 &&
		lat >= 16 &&
		lat <= 33
	);
}

export function asLngLat(lng: unknown, lat: unknown): { lng: number; lat: number } | null {
	if (!isValidLngLat(lng, lat)) return null;
	return { lng, lat: lat as number };
}

const NATURE_LEXICON: Array<{ kind: NatureKind; re: RegExp }> = [
	{ kind: "rawdah", re: /روضة|روضات|rawdah|rawdat/i },
	{ kind: "fayad", re: /فيضة|فياض|fayad|faydah/i },
	{ kind: "shaib", re: /شعيب|شعاب|shaib|sha'ib/i },
	{ kind: "wadi", re: /وادي|وديان|wadi/i },
	{ kind: "nafud", re: /نفود|نفوذ|nafud/i },
	{ kind: "dune", re: /كثيب|كثبان|طعوس|dune/i },
	{ kind: "mountain", re: /جبل|جبال|jabal|jebel/i },
	{ kind: "sabkha", re: /سبخة|سبخات|sabkha/i },
	{ kind: "coast", re: /ساحل|شاطئ|coast|beach/i },
];

export function kindFromName(name: string | null | undefined): NatureKind | null {
	const n = String(name || "").trim();
	if (!n) return null;
	for (const row of NATURE_LEXICON) {
		if (row.re.test(n)) return row.kind;
	}
	return null;
}

export function groupOf(kind: EntityKind): EntityGroup {
	if (
		kind === "camp" ||
		kind === "picnic" ||
		kind === "well" ||
		kind === "spring" ||
		kind === "landmark"
	) {
		return "place";
	}
	if (
		kind === "public_track" ||
		kind === "osm_track" ||
		kind === "observed_track" ||
		kind === "personal_track"
	) {
		return "movement";
	}
	return "nature";
}

export function evidenceLabel(evidence: Evidence, isRTL: boolean): string {
	if (evidence === "public") return isRTL ? "بيانات عامة" : "Public data";
	if (evidence === "observed") return isRTL ? "تم قطعه فعليًا" : "Actually travelled";
	if (evidence === "mine") return isRTL ? "مساري" : "My track";
	return isRTL ? "غير مؤكد" : "Unconfirmed";
}

export function kindLabel(kind: EntityKind, isRTL: boolean): string {
	const ar: Record<EntityKind, string> = {
		fayad: "فيضة",
		rawdah: "روضة",
		wadi: "وادي",
		shaib: "شعيب",
		nafud: "نفود",
		dune: "كثيب",
		mountain: "جبل",
		rocky: "منطقة صخرية",
		sabkha: "سبخة",
		coast: "ساحل",
		camp: "مخيم",
		picnic: "متنزه",
		well: "بئر",
		spring: "عين",
		landmark: "معلم",
		public_track: "مسار عام",
		osm_track: "مسار OSM",
		observed_track: "مسار مرصود",
		personal_track: "مساري",
	};
	const en: Record<EntityKind, string> = {
		fayad: "Fayad",
		rawdah: "Rawdah",
		wadi: "Wadi",
		shaib: "Shaib",
		nafud: "Nafud",
		dune: "Dune",
		mountain: "Mountain",
		rocky: "Rocky terrain",
		sabkha: "Sabkha",
		coast: "Coast",
		camp: "Camp",
		picnic: "Picnic area",
		well: "Well",
		spring: "Spring",
		landmark: "Landmark",
		public_track: "Public track",
		osm_track: "OSM track",
		observed_track: "Observed track",
		personal_track: "My track",
	};
	return isRTL ? ar[kind] : en[kind];
}

export function haversineMeters(
	a: { lat: number; lng: number },
	b: { lat: number; lng: number },
): number {
	const R = 6371000;
	const toRad = (d: number) => (d * Math.PI) / 180;
	const dLat = toRad(b.lat - a.lat);
	const dLng = toRad(b.lng - a.lng);
	const lat1 = toRad(a.lat);
	const lat2 = toRad(b.lat);
	const h =
		Math.sin(dLat / 2) ** 2 +
		Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLng / 2) ** 2;
	return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)));
}

export function formatKm(meters: number | null | undefined, isRTL: boolean): string {
	if (meters == null || !Number.isFinite(meters)) return isRTL ? "غير مؤكد" : "Unconfirmed";
	const km = meters / 1000;
	const n = km < 10 ? km.toFixed(1) : Math.round(km).toString();
	return isRTL ? `${n} كم` : `${n} km`;
}

export function formatDuration(ms: number, isRTL: boolean): string {
	const total = Math.max(0, Math.round(ms / 1000));
	const h = Math.floor(total / 3600);
	const m = Math.floor((total % 3600) / 60);
	if (isRTL) {
		if (h) return `${h} س ${m} د`;
		return `${m} د`;
	}
	if (h) return `${h}h ${m}m`;
	return `${m}m`;
}
