import { API_BASE_URL } from "../lib/api";
import type { OutdoorEntity } from "../lib/sary/domain";

export type OutdoorFeature = GeoJSON.Feature<
	GeoJSON.Point | GeoJSON.LineString | GeoJSON.MultiLineString,
	{
		id: string;
		kind: OutdoorEntity["kind"];
		group: OutdoorEntity["group"];
		name: string | null;
		source: "osm";
		evidence: OutdoorEntity["evidence"];
		license: "ODbL";
		lng: number;
		lat: number;
		distance_m?: number;
		fclass?: string | null;
	}
>;

export type OutdoorFeatureCollection = {
	type: "FeatureCollection";
	count: number;
	source: "osm";
	license: "ODbL";
	features: OutdoorFeature[];
};

export type OutdoorAround = {
	origin: { lng: number; lat: number };
	radius_m: number;
	summary: {
		tracks: number;
		places: number;
		nearest_well: OutdoorFeature | null;
		nearest_rawdah: OutdoorFeature | null;
		nearest_shaib: OutdoorFeature | null;
	};
	features: OutdoorFeature[];
};

async function getJson<T>(path: string, signal?: AbortSignal): Promise<T> {
	const res = await fetch(`${API_BASE_URL}${path}`, { signal });
	if (!res.ok) {
		throw new Error(`outdoor_${res.status}`);
	}
	return (await res.json()) as T;
}

export const OutdoorService = {
	features(opts: {
		bbox: string;
		zoom: number;
		types?: string;
		signal?: AbortSignal;
	}): Promise<OutdoorFeatureCollection> {
		const qs = new URLSearchParams({
			bbox: opts.bbox,
			zoom: String(opts.zoom),
		});
		if (opts.types) qs.set("types", opts.types);
		return getJson(`/api/outdoor/features?${qs}`, opts.signal);
	},
	around(opts: {
		lng: number;
		lat: number;
		radius?: number;
		signal?: AbortSignal;
	}): Promise<OutdoorAround> {
		const qs = new URLSearchParams({
			lng: String(opts.lng),
			lat: String(opts.lat),
		});
		if (opts.radius) qs.set("radius", String(opts.radius));
		return getJson(`/api/outdoor/around?${qs}`, opts.signal);
	},
	search(q: string, signal?: AbortSignal): Promise<OutdoorFeatureCollection> {
		return getJson(`/api/outdoor/search?q=${encodeURIComponent(q)}`, signal);
	},
	feature(id: string, signal?: AbortSignal): Promise<OutdoorFeature> {
		const [kind, rest] = id.split(":");
		return getJson(`/api/outdoor/${encodeURIComponent(kind)}/${encodeURIComponent(rest)}`, signal);
	},
};

export function featureToEntity(f: OutdoorFeature): OutdoorEntity {
	const p = f.properties;
	return {
		id: p.id,
		kind: p.kind,
		group: p.group,
		name: p.name,
		lng: p.lng,
		lat: p.lat,
		source: "osm",
		evidence: p.evidence,
		license: "ODbL",
		distanceM: p.distance_m ?? null,
		fclass: p.fclass ?? null,
	};
}
