import { fetchApi } from "../lib/api";

export type MapOpportunity = {
	id: string;
	type: "opportunity";
	place: {
		id: string;
		restaurant_id: string | null;
		name: string | null;
		lat: number;
		lng: number;
		image_url: string | null;
	};
	category: string | null;
	product: { name: string } | null;
	price: {
		cheapest: number | null;
		expensive: number | null;
		difference: number | null;
		percentage: number | null;
		currency: "SAR";
	};
	providers: {
		count: number | null;
		cheapest: string | null;
		expensive: string | null;
	};
	evidence: {
		observed: boolean;
		freshness: string | null;
		confidence: number | string | null;
		match_quality: number | string | null;
	};
	opportunity_score: number;
};

export type MapOpportunityCluster = {
	id: string;
	type: "opportunity_cluster";
	lat: number;
	lng: number;
	place_count: number;
	opportunity_count: number;
};

export type MapOpportunitiesResponse = {
	type: "map_opportunities";
	version: 1;
	viewport: { bbox: unknown; zoom: number | null };
	opportunities: MapOpportunity[];
	clusters: MapOpportunityCluster[];
	coverage: unknown;
	source: "comparison.discovery_cards";
};

export async function fetchMapOpportunities(opts: {
	bbox?: string;
	zoom?: number;
	q?: string;
	category?: string;
	limit?: number;
	signal?: AbortSignal;
}): Promise<MapOpportunitiesResponse> {
	const qs = new URLSearchParams();
	if (opts.bbox) qs.set("bbox", opts.bbox);
	if (opts.zoom != null) qs.set("zoom", String(opts.zoom));
	if (opts.q) qs.set("q", opts.q);
	if (opts.category) qs.set("category", opts.category);
	if (opts.limit != null) qs.set("limit", String(opts.limit));

	const env = await fetchApi<MapOpportunitiesResponse>(
		`/api/intelligence/map/opportunities?${qs.toString()}`,
		{ signal: opts.signal },
		{ timeoutMs: 15_000 },
	);
	return env.data;
}
