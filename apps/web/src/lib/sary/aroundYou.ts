import { haversineMeters, type EntityGroup, type OutdoorEntity } from "./domain";

export type AroundSummary = {
	tracks: number;
	places: number;
	nearestWell: OutdoorEntity | null;
	nearestRawdah: OutdoorEntity | null;
	nearestShaib: OutdoorEntity | null;
};

export function summarizeAround(
	entities: OutdoorEntity[],
	origin: { lat: number; lng: number } | null,
	radiusM = 15_000,
): AroundSummary {
	const empty: AroundSummary = {
		tracks: 0,
		places: 0,
		nearestWell: null,
		nearestRawdah: null,
		nearestShaib: null,
	};
	if (!origin) return empty;
	const nearby = entities
		.map((e) => ({ ...e, distanceM: haversineMeters(origin, e) }))
		.filter((e) => e.distanceM <= radiusM);

	const nearest = (pred: (e: OutdoorEntity) => boolean) => {
		const hits = nearby.filter(pred).sort((a, b) => (a.distanceM ?? 0) - (b.distanceM ?? 0));
		return hits[0] ?? null;
	};

	const countGroup = (group: EntityGroup) => nearby.filter((e) => e.group === group).length;

	return {
		tracks: countGroup("movement"),
		places: countGroup("place") + countGroup("nature"),
		nearestWell: nearest((e) => e.kind === "well"),
		nearestRawdah: nearest((e) => e.kind === "rawdah" || e.kind === "fayad"),
		nearestShaib: nearest((e) => e.kind === "shaib" || e.kind === "wadi"),
	};
}

export function aroundLines(summary: AroundSummary, isRTL: boolean): string[] {
	const lines: string[] = [];
	if (summary.tracks) {
		lines.push(isRTL ? `${summary.tracks} مسارات` : `${summary.tracks} tracks`);
	}
	if (summary.places) {
		lines.push(isRTL ? `${summary.places} أماكن` : `${summary.places} places`);
	}
	if (summary.nearestWell) {
		lines.push(isRTL ? "بئر قريب" : "A nearby well");
	}
	if (summary.nearestRawdah) {
		lines.push(isRTL ? "روضة قريبة" : "A nearby rawdah");
	}
	if (summary.nearestShaib) {
		lines.push(isRTL ? "شعيب قريب" : "A nearby shaib");
	}
	return lines;
}
