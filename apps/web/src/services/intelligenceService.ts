import { fetchApi } from "../lib/api";

export type IntelligenceMapView = {
	lat: number;
	lng: number;
	zoom: number;
};

export type IntelligenceMapPlaceProperties = {
	feature_type: "place" | "cluster";
	place_id?: string;
	name?: string;
	kind?: "difference" | "restaurant" | "cafe" | "comparison" | string;
	restaurant_id?: string;
	provider_count?: number | null;
	has_difference?: boolean;
	count?: number;
	difference_count?: number;
	image_url?: string | null;
	branch_image_url?: string | null;
	restaurant_logo_url?: string | null;
	restaurant_image_url?: string | null;
	restaurant_image?: string | null;
	menu?: { to?: string; type?: string; id?: string; href?: string } | null;
	difference?: {
		difference_amount?: number | null;
		cheapest_provider_id?: string | null;
		expensive_provider_id?: string | null;
		product_name?: string | null;
		cheapest_price?: number | null;
		expensive_price?: number | null;
		observed_at?: string | null;
		confidence?: number | null;
		match_quality?: number | null;
	} | null;
};

export type IntelligenceMapGeojsonFeature<P> = {
	type: "Feature";
	id?: string;
	geometry: { type: string; coordinates: unknown };
	properties: P;
};

export type IntelligenceMapOpportunity = {
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
	category?: string | null;
	product?: { name?: string | null } | null;
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
};

export type IntelligenceMapPresentation = {
	type: "map_opportunities";
	version: number;
	viewport: { bbox: string | null; zoom: number | null };
	opportunities: IntelligenceMapOpportunity[];
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

export type IntelligenceMapPlaces = {
	type: "FeatureCollection";
	count: number;
	matched?: number;
	layer?: string;
	default_view?: IntelligenceMapView;
	coverage?: Record<string, unknown> | null;
	features: IntelligenceMapGeojsonFeature<IntelligenceMapPlaceProperties>[];
	presentation?: IntelligenceMapPresentation;
	note_ar?: string;
	note_en?: string;
};

export type IntelligenceMapPlaceDetail = {
	place_id: string;
	name: string;
	name_ar?: string | null;
	name_en?: string | null;
	category?: string | null;
	subcategory?: string | null;
	city?: string | null;
	provider_count?: number | null;
	kind?: string;
	restaurant_id?: string;
	lat: number;
	lng: number;
	menu?: { to?: string; type?: string; id?: string; href?: string } | null;
	difference?: {
		product_id?: string | null;
		product_name?: string | null;
		cheapest_provider_id?: string | null;
		expensive_provider_id?: string | null;
		cheapest_price?: number | null;
		expensive_price?: number | null;
		difference_amount?: number | null;
		difference_percentage?: number | null;
		provider_count?: number | null;
		confidence?: number | null;
		observed_at?: string | null;
		grain?: string | null;
	} | null;
	compare?: { to: "/" | "/grocery" | string; q?: string; note_ar?: string; note_en?: string };
	image_url?: string | null;
};

export type IntelligenceMapNeighborhoodProperties = {
	neighborhood_id: string;
	neighborhood_en?: string | null;
	neighborhood_ar?: string | null;
	city_en?: string | null;
	city_ar?: string | null;
	category_id?: string | null;
	winner_provider_id?: string | null;
	winner_provider_name_ar?: string | null;
	overall_score?: number | null;
	confidence?: string | null;
	promote_in_consumer_ui?: boolean;
	caution?: boolean;
	consumer_message_ar?: string | null;
};

export type IntelligenceMapNeighborhoods = {
	type: "FeatureCollection";
	count: number;
	default_view?: IntelligenceMapView;
	features: IntelligenceMapGeojsonFeature<IntelligenceMapNeighborhoodProperties>[];
	note_ar?: string;
	note_en?: string;
};

export type IntelligenceHealth = { ok: boolean; enabled?: boolean };

export type IntelligenceCategory = {
	category_id: string;
	category_name?: string;
	category_name_ar?: string;
};
export type IntelligenceCategoryGroup = {
	sector_id: string;
	sector_name_ar?: string;
	sector_name_en?: string;
	category_count: number;
	categories: IntelligenceCategory[];
};
export type IntelligenceMeta = {
	categories: IntelligenceCategory[];
	category_groups?: IntelligenceCategoryGroup[];
	geo_readiness?: { ncp_ready_cities?: Array<{ city_en: string; city_ar?: string }> };
};

export type IntelligenceDetail = {
	winner?: {
		provider_id?: string | null;
		provider_name_ar?: string | null;
		overall_score?: number | null;
		promote_in_consumer_ui?: boolean;
		consumer_message_ar?: string;
		podium?: Record<string, string | number | null>;
	};
	farq_signal?: { consumer?: { category?: string; q?: string } };
};

export const FOOD_SLUG_TO_INTEL_CATEGORY: Record<string, string> = {
	burger: "burgers", burgers: "burgers", pizza: "pizza", coffee: "coffee", shawarma: "shawarma",
	chicken: "chicken", grill: "grill", sandwich: "sandwiches", sandwiches: "sandwiches", pasta: "pasta",
	sushi: "sushi", seafood: "seafood", dessert: "desserts", desserts: "desserts", pastry: "bakery",
	bakery: "bakery", drinks: "beverages", beverages: "beverages", grocery: "grocery", food: "food",
};

export function toIntelCategoryId(slug: string | null | undefined): string {
	if (!slug) return "";
	const key = slug.trim().toLowerCase();
	return FOOD_SLUG_TO_INTEL_CATEGORY[key] ?? key;
}

export const IntelligenceService = {
	async health(signal?: AbortSignal): Promise<IntelligenceHealth> {
		const env = await fetchApi<IntelligenceHealth>("/api/intelligence/health", { signal }, { timeoutMs: 8_000 });
		return env.data;
	},
	async meta(signal?: AbortSignal): Promise<IntelligenceMeta> {
		const env = await fetchApi<IntelligenceMeta>("/api/intelligence/meta", { signal }, { timeoutMs: 15_000 });
		return env.data;
	},
	async detail(neighborhoodId: string, categoryId: string, signal?: AbortSignal): Promise<IntelligenceDetail> {
		const env = await fetchApi<IntelligenceDetail>(`/api/intelligence/neighborhoods/${encodeURIComponent(neighborhoodId)}/categories/${encodeURIComponent(categoryId)}`, { signal }, { timeoutMs: 15_000 });
		return env.data;
	},
	async mapPlaces(opts: { bbox?: string; zoom?: number; q?: string; category?: string; layer?: "difference" | "places" | "all_food" | "comparison"; limit?: number; signal?: AbortSignal } = {}): Promise<IntelligenceMapPlaces> {
		const qs = new URLSearchParams();
		if (opts.bbox) qs.set("bbox", opts.bbox);
		if (opts.zoom != null) qs.set("zoom", String(opts.zoom));
		if (opts.q) qs.set("q", opts.q);
		if (opts.category) qs.set("category", opts.category);
		if (opts.layer) qs.set("layer", opts.layer);
		qs.set("limit", String(opts.limit ?? 400));
		const env = await fetchApi<IntelligenceMapPlaces>(`/api/intelligence/map/places?${qs}`, { signal: opts.signal }, { timeoutMs: 15_000 });
		return env.data;
	},
	async mapPlace(placeId: string, signal?: AbortSignal): Promise<IntelligenceMapPlaceDetail> {
		const env = await fetchApi<IntelligenceMapPlaceDetail>(`/api/intelligence/map/places/${encodeURIComponent(placeId)}`, { signal }, { timeoutMs: 12_000 });
		return env.data;
	},
	async mapNeighborhoods(opts: { category?: string; city?: string; signal?: AbortSignal } = {}): Promise<IntelligenceMapNeighborhoods> {
		const qs = new URLSearchParams();
		if (opts.category) qs.set("category", opts.category);
		if (opts.city) qs.set("city", opts.city);
		const env = await fetchApi<IntelligenceMapNeighborhoods>(`/api/intelligence/map/neighborhoods?${qs}`, { signal: opts.signal }, { timeoutMs: 20_000 });
		return env.data;
	},
};
