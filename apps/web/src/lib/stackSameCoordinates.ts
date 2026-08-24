/**
 * Exact same-coordinate stacks — one marker, every identity kept.
 *
 * Food-court geocodes put many distinct restaurants on one lat/lng.
 * We never merge those identities and we never group by proximity.
 * Six decimal places is centimetre-scale float noise, not a 30 m merge.
 */

export const COORD_KEY_DECIMALS = 6;

export type StackMember = {
	placeId: string;
	name: string;
	gap: number | null;
	lat: number;
	lng: number;
};

export type CoordinateStack = {
	key: string;
	lat: number;
	lng: number;
	members: StackMember[];
};

type PointFeature = {
	type: "Feature";
	id?: string | number;
	geometry?: { type?: string; coordinates?: unknown } | null;
	properties?: Record<string, unknown> | null;
};

export function coordKey(lng: number, lat: number): string | null {
	if (!Number.isFinite(lng) || !Number.isFinite(lat)) return null;
	return `${lng.toFixed(COORD_KEY_DECIMALS)},${lat.toFixed(COORD_KEY_DECIMALS)}`;
}

function readPoint(feature: PointFeature): { lng: number; lat: number } | null {
	const coords = feature.geometry?.coordinates;
	if (!Array.isArray(coords) || coords.length < 2) return null;
	const lng = Number(coords[0]);
	const lat = Number(coords[1]);
	if (!Number.isFinite(lng) || !Number.isFinite(lat)) return null;
	return { lng, lat };
}

function memberFromFeature(feature: PointFeature): StackMember | null {
	const point = readPoint(feature);
	const placeId = String(feature.properties?.place_id || "").trim();
	if (!point || !placeId) return null;
	const gapRaw = Number(feature.properties?.gap);
	return {
		placeId,
		name: String(feature.properties?.name || placeId),
		gap: Number.isFinite(gapRaw) && gapRaw > 0 ? gapRaw : null,
		lat: point.lat,
		lng: point.lng,
	};
}

function gapOf(feature: PointFeature): number {
	const n = Number(feature.properties?.gap);
	return Number.isFinite(n) && n > 0 ? n : 0;
}

/**
 * Collapse exact-coordinate piles to one drawn feature.
 * The list of identities stays on `stack_place_ids` — never a merged place_id.
 */
export function stackSameCoordinateFeatures<T extends PointFeature>(
	features: T[],
): T[] {
	const singles: T[] = [];
	const buckets = new Map<string, T[]>();
	for (const feature of features) {
		if (feature.properties?.feature_type === "cluster") {
			singles.push(feature);
			continue;
		}
		const point = readPoint(feature);
		const key = point ? coordKey(point.lng, point.lat) : null;
		if (!key) {
			singles.push(feature);
			continue;
		}
		const bucket = buckets.get(key);
		if (bucket) bucket.push(feature);
		else buckets.set(key, [feature]);
	}
	const stacked: T[] = [];
	for (const [key, group] of buckets) {
		if (group.length === 1) {
			stacked.push(group[0]);
			continue;
		}
		const ordered = group.slice().sort((a, b) => {
			const dg = gapOf(b) - gapOf(a);
			if (dg) return dg;
			return String(a.properties?.place_id || "").localeCompare(
				String(b.properties?.place_id || ""),
			);
		});
		const hero = ordered[0];
		const members = ordered
			.map((feature) => memberFromFeature(feature))
			.filter((row): row is StackMember => Boolean(row));
		stacked.push({
			...hero,
			properties: {
				...(hero.properties || {}),
				stack_count: members.length,
				stack_key: key,
				stack_place_ids: members.map((row) => row.placeId),
				stack_names: members.map((row) => row.name),
				stack_gaps: members.map((row) => row.gap),
				never_merged: true,
			},
		});
	}
	return [...singles, ...stacked];
}

export function stackFromFeature(
	feature: PointFeature | null | undefined,
): CoordinateStack | null {
	if (!feature) return null;
	const ids = feature.properties?.stack_place_ids;
	const names = feature.properties?.stack_names;
	const gaps = feature.properties?.stack_gaps;
	const point = readPoint(feature);
	if (!point || !Array.isArray(ids) || ids.length < 2) return null;
	const nameList = Array.isArray(names) ? names : [];
	const gapList = Array.isArray(gaps) ? gaps : [];
	return {
		key: String(feature.properties?.stack_key || coordKey(point.lng, point.lat) || ""),
		lat: point.lat,
		lng: point.lng,
		members: ids.map((id, i) => {
			const gapRaw = Number(gapList[i]);
			return {
				placeId: String(id),
				name: String(nameList[i] || id),
				gap: Number.isFinite(gapRaw) && gapRaw > 0 ? gapRaw : null,
				lat: point.lat,
				lng: point.lng,
			};
		}),
	};
}

export function stackAtPlaceId(
	features: PointFeature[],
	placeId: string,
): CoordinateStack | null {
	const id = String(placeId || "").trim();
	if (!id) return null;
	const mine = features.find(
		(feature) => String(feature.properties?.place_id || "") === id,
	);
	const point = mine ? readPoint(mine) : null;
	const key = point ? coordKey(point.lng, point.lat) : null;
	if (!key) return null;
	const group = features.filter((feature) => {
		const at = readPoint(feature);
		return at ? coordKey(at.lng, at.lat) === key : false;
	});
	if (group.length < 2) return null;
	return stackFromFeature(stackSameCoordinateFeatures(group)[0] || null);
}

export function stackIncludesPlace(
	feature: PointFeature | null | undefined,
	placeId: string,
): boolean {
	const id = String(placeId || "").trim();
	if (!id || !feature) return false;
	if (String(feature.properties?.place_id || "") === id) return true;
	const ids = feature.properties?.stack_place_ids;
	return Array.isArray(ids) && ids.map(String).includes(id);
}
