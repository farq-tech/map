export type MapZoomMode = "discover" | "opportunity" | "restaurant" | "decision";

export function mapZoomMode(zoom: number): MapZoomMode {
	if (zoom < 11) return "discover";
	if (zoom < 13.5) return "opportunity";
	if (zoom < 15) return "restaurant";
	return "decision";
}

export type MapOpportunity = {
	id: string;
	type: "opportunity";
	place: {
		id: string;
		restaurant_id?: string | null;
		name?: string | null;
		lat: number;
		lng: number;
		image_url?: string | null;
	};
	category?: { id?: string; name?: string; name_ar?: string } | null;
	product?: { id?: string; name?: string } | null;
	price: {
		cheapest: number | null;
		expensive: number | null;
		difference: number | null;
		percentage: number | null;
		currency: "SAR";
	};
	providers: {
		count: number | null;
		cheapest?: string | null;
		expensive?: string | null;
	};
	evidence: {
		observed: boolean;
		freshness?: string | null;
		confidence?: number | null;
		match_quality?: number | null;
	};
	opportunity_score: number;
	distance_meters?: number | null;
};

export type MapExplorationPresentation = {
	type: "map_opportunities";
	version: number;
	viewport: { bbox: string | null; zoom: number | null };
	opportunities: MapOpportunity[];
	clusters: Array<{
		id: string;
		lat: number;
		lng: number;
		place_count: number;
		opportunity_count: number;
	}>;
	coverage?: Record<string, unknown> | null;
	source: string;
};

export function topOpportunities(items: MapOpportunity[], limit = 5) {
	return [...items]
		.sort((a, b) => b.opportunity_score - a.opportunity_score || (b.price.difference ?? 0) - (a.price.difference ?? 0))
		.slice(0, limit);
}

export function formatDifference(value: number | null | undefined, locale = "ar-SA") {
	if (value == null || !Number.isFinite(Number(value))) return "—";
	return new Intl.NumberFormat(locale, { maximumFractionDigits: 0 }).format(Number(value));
}

export function formatPercentage(value: number | null | undefined, locale = "ar-SA") {
	if (value == null || !Number.isFinite(Number(value))) return null;
	return `${new Intl.NumberFormat(locale, { maximumFractionDigits: 0 }).format(Number(value))}%`;
}
