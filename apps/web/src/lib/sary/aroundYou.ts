import { formatKm, formatNumber, haversineMeters, type EntityGroup, type OutdoorEntity } from "./domain";

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

/** Arabic counting: ١ مسار · مساران · ٣ مسارات · ١١ مسارًا. */
export function countAr(n: number, one: string, two: string, few: string, many: string): string {
	const d = formatNumber(n, true);
	if (n === 1) return one;
	if (n === 2) return two;
	if (n >= 3 && n <= 10) return `${d} ${few}`;
	return `${d} ${many}`;
}

function near(label: string, e: OutdoorEntity, isRTL: boolean): string {
	const name = e.name ? ` «${e.name}»` : "";
	return isRTL ? `${label}${name} على بُعد ${formatKm(e.distanceM, true)}` : `${label}${name} ${formatKm(e.distanceM, false)} away`;
}

export function aroundLines(summary: AroundSummary, isRTL: boolean): string[] {
	const lines: string[] = [];
	if (summary.tracks) {
		lines.push(
			isRTL
				? `${countAr(summary.tracks, "مسار واحد", "مساران", "مسارات", "مسارًا")} حولك`
				: `${summary.tracks} track${summary.tracks === 1 ? "" : "s"} around you`,
		);
	}
	if (summary.places) {
		lines.push(
			isRTL
				? `${countAr(summary.places, "معلم واحد", "معلمان", "معالم", "معلمًا")} حولك`
				: `${summary.places} place${summary.places === 1 ? "" : "s"} around you`,
		);
	}
	if (summary.nearestWell) lines.push(near(isRTL ? "أقرب بئر" : "Nearest well", summary.nearestWell, isRTL));
	if (summary.nearestRawdah) lines.push(near(isRTL ? "أقرب روضة" : "Nearest rawdah", summary.nearestRawdah, isRTL));
	if (summary.nearestShaib) lines.push(near(isRTL ? "أقرب شعيب" : "Nearest shaib", summary.nearestShaib, isRTL));
	return lines;
}
