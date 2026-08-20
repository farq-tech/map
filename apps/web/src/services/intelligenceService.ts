/**
 * N×C×P intelligence client — read-only `/api/intelligence`.
 * Scoring stays on the server (api/routes/intelligence.js). Never remint
 * place_ids or invent demand / lat-lon.
 */
import { fetchApi } from "../lib/api";

export type IntelligenceConfidence =
	| "HIGH"
	| "MEDIUM"
	| "LOW"
	| "INSUFFICIENT_DATA"
	| string;

export type IntelligenceNeighborhood = {
	neighborhood_id: string;
	neighborhood_en?: string;
	neighborhood_ar?: string;
	city_en?: string;
	city_ar?: string;
};

export type IntelligenceCategory = {
	category_id: string;
	category_name?: string;
	category_name_ar?: string;
	sector_id?: string;
	winner_rows?: number;
	promoted_rows?: number;
	neighborhood_count?: number;
	has_promoted_winner?: boolean;
};

export type IntelligenceCategoryGroup = {
	sector_id: string;
	sector_name_ar: string;
	sector_name_en?: string;
	category_count: number;
	winner_rows?: number;
	promoted_rows?: number;
	categories: IntelligenceCategory[];
};

export type IntelligenceProvider = {
	provider_id: string;
	provider_name_ar?: string;
};

export type IntelligenceCityCoverage = {
	city_en: string;
	city_ar?: string;
	neighborhood_count: number;
	winner_rows: number;
	promoted_rows: number;
	ncp_ready: boolean;
};

export type IntelligenceCrawlSeed = {
	city_en: string;
	city_ar?: string;
	ncp_ready?: boolean;
	note_ar?: string;
};

export type IntelligenceGeoReadiness = {
	primary_city_en?: string | null;
	primary_city_ar?: string | null;
	ncp_ready_cities: IntelligenceCityCoverage[];
	thin_cities: IntelligenceCityCoverage[];
	crawl_seeds: IntelligenceCrawlSeed[];
	note_ar?: string;
	blocker?: string;
};

export type IntelligenceMeta = {
	neighborhoods: IntelligenceNeighborhood[];
	categories: IntelligenceCategory[];
	category_groups?: IntelligenceCategoryGroup[];
	category_count?: number;
	quick_categories: IntelligenceCategory[];
	cities: string[];
	city_coverage?: IntelligenceCityCoverage[];
	geo_readiness?: IntelligenceGeoReadiness;
	providers: IntelligenceProvider[];
	dimension_labels_ar?: Record<string, string>;
	score_version?: string;
	positioning_ar?: string;
};

export type IntelligencePodium = {
	rank_1?: string | null;
	rank_1_name_ar?: string | null;
	rank_1_score?: number | string | null;
	rank_2?: string | null;
	rank_2_name_ar?: string | null;
	rank_2_score?: number | string | null;
	rank_3?: string | null;
	rank_3_name_ar?: string | null;
	rank_3_score?: number | string | null;
};

export type IntelligenceWinner = {
	provider_id: string | null;
	provider_name?: string | null;
	provider_name_ar?: string | null;
	overall_score?: number | null;
	confidence: IntelligenceConfidence;
	why?: string;
	evidence_bullets: string[];
	caution: boolean;
	promote_in_consumer_ui: boolean;
	consumer_message_ar?: string;
	ui_state?: string;
	podium?: IntelligencePodium;
};

export type IntelligenceDimensionChip = {
	key: string;
	label_ar: string;
	provider_id?: string | null;
	provider_name_ar?: string | null;
};

export type IntelligenceFarqConsumer = {
	to: "/" | "/grocery" | string;
	category?: string;
	q?: string;
	cta_ar?: string;
	cta_en?: string;
	note_ar?: string;
};

export type IntelligenceGroceryFarqSample = {
	product_id?: string | null;
	product_name?: string;
	cheapest_provider_id?: string | null;
	expensive_provider_id?: string | null;
	cheapest_price?: number | null;
	expensive_price?: number | null;
	difference_amount?: number | null;
	difference_percentage?: number | null;
	grain?: string;
	note_ar?: string;
};

export type IntelligenceFarqSignal = {
	available: boolean;
	cheapest_provider_id?: string | null;
	cheapest_provider_name_ar?: string | null;
	winner_is_cheapest?: boolean;
	price_win_rate?: number | null;
	median_item_price?: number | null;
	evidence?: string;
	message_ar?: string;
	consumer: IntelligenceFarqConsumer;
	grocery_week_samples?: IntelligenceGroceryFarqSample[];
};

export type IntelligenceDetail = {
	neighborhood_id: string;
	neighborhood_en?: string;
	neighborhood_ar?: string;
	city_en?: string;
	city_ar?: string;
	category_id: string;
	category_name?: string;
	category_name_ar?: string;
	question_ar: string;
	farq_signal?: IntelligenceFarqSignal;
	winner: IntelligenceWinner;
	dimension_chips: IntelligenceDimensionChip[];
	score_version?: string;
	computed_at?: string;
	source?: string;
};

export type IntelligenceLensRow = {
	neighborhood_id?: string;
	neighborhood_en?: string;
	neighborhood_ar?: string;
	city_en?: string;
	category_id?: string;
	category_name_ar?: string;
	overall_score?: number | null;
	confidence?: string;
	coverage_pct?: number | null;
	overall_rank?: number | null;
	provider_places?: number | null;
	market_places?: number | null;
};

export type IntelligenceLens = {
	provider_id: string;
	provider_name_ar?: string;
	counts: {
		wins: number;
		second: number;
		weak: number;
		coverage_gaps: number;
	};
	wins: IntelligenceLensRow[];
	second: IntelligenceLensRow[];
	weak: IntelligenceLensRow[];
	coverage_gaps: IntelligenceLensRow[];
};

export type IntelligenceOpportunity = {
	provider_id?: string;
	provider_name_ar?: string;
	neighborhood_id?: string;
	neighborhood_en?: string;
	city_en?: string;
	category_id?: string;
	category_name_ar?: string;
	coverage_pct?: number | string | null;
	provider_places?: number | string | null;
	market_places?: number | string | null;
	headline_ar?: string;
	body_ar?: string;
	tone?: string;
};

export type IntelligenceOpportunities = {
	count: number;
	disclaimer_ar: string;
	results: IntelligenceOpportunity[];
};

export type IntelligenceAlertItem = {
	kind?: "watchlist" | "winner_change" | string;
	label?: string;
	message_ar?: string;
	neighborhood_en?: string;
	category_id?: string;
	old_winner?: string;
	new_winner?: string;
};

export type IntelligenceAlerts = {
	has_week_over_week_flips: boolean;
	week_over_week_available?: boolean;
	single_snapshot?: boolean;
	ux_mode?: "winner_changes" | "watchlist_only" | string;
	watchlist_headline_ar?: string;
	watchlist_note_ar?: string | null;
	count: number;
	items: IntelligenceAlertItem[];
};

export type IntelligenceHealth = {
	ok: boolean;
	enabled?: boolean;
};

/** Home food-category slugs (`burger`) → intelligence category_id (`burgers`). */
export const FOOD_SLUG_TO_INTEL_CATEGORY: Record<string, string> = {
	burger: "burgers",
	burgers: "burgers",
	pizza: "pizza",
	coffee: "coffee",
	shawarma: "shawarma",
	chicken: "chicken",
	grill: "grill",
	sandwich: "sandwiches",
	sandwiches: "sandwiches",
	pasta: "pasta",
	sushi: "sushi",
	seafood: "seafood",
	dessert: "desserts",
	desserts: "desserts",
	pastry: "bakery",
	bakery: "bakery",
	drinks: "beverages",
	beverages: "beverages",
	grocery: "grocery",
	food: "food",
};

export function toIntelCategoryId(slug: string | null | undefined): string {
	if (!slug) return "";
	const key = slug.trim().toLowerCase();
	return FOOD_SLUG_TO_INTEL_CATEGORY[key] ?? key;
}

export type IntelligenceNeighborhoodCategoryRow = {
	neighborhood_id: string;
	neighborhood_en?: string;
	neighborhood_ar?: string;
	city_en?: string;
	category_id: string;
	category_name?: string;
	category_name_ar?: string;
	winner_provider_id?: string | null;
	winner_provider_name_ar?: string | null;
	overall_score?: number | string | null;
	confidence?: IntelligenceConfidence;
	caution?: boolean;
	promote_in_consumer_ui?: boolean;
	consumer_message_ar?: string;
	why_winner?: string;
	question_ar?: string;
	score_version?: string;
};

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
	gap?: number | null;
	cheapest_provider_id?: string | null;
	expensive_provider_id?: string | null;
	product_name?: string | null;
	cheapest_price?: number | null;
	expensive_price?: number | null;
	image_url?: string | null;
	branch_image_url?: string | null;
	restaurant_logo_url?: string | null;
	restaurant_image_url?: string | null;
	restaurant_image?: string | null;
	menu?: {
		to?: string;
		type?: string;
		id?: string;
		href?: string;
	} | null;
	difference?: {
		difference_amount?: number | null;
		cheapest_provider_id?: string | null;
		expensive_provider_id?: string | null;
		product_name?: string | null;
	} | null;
};

export type IntelligenceMapGeojsonFeature<P> = {
	type: "Feature";
	id?: string;
	geometry: {
		type: string;
		coordinates: unknown;
	};
	properties: P;
};

export type IntelligenceMapPlaces = {
	type: "FeatureCollection";
	count: number;
	matched?: number;
	limit?: number;
	capped?: boolean;
	cluster_break_zoom?: number;
	fields?: "pin" | "full" | string;
	server_clusters?: boolean;
	layer?: string;
	default_view?: IntelligenceMapView;
	coverage?: {
		source?: string;
		restaurants_total?: number;
		restaurants_with_coords?: number;
		cafes_total?: number;
		cafes_with_coords?: number;
		differences_with_coords?: number;
		unique_places?: number;
		matched?: number;
		shown?: number;
		db_join?: string | null;
	};
	features: IntelligenceMapGeojsonFeature<IntelligenceMapPlaceProperties>[];
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
	menu?: {
		to?: string;
		type?: string;
		id?: string;
		href?: string;
	} | null;
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
	compare?: {
		to: "/" | "/grocery" | string;
		q?: string;
		note_ar?: string;
		note_en?: string;
	};
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

export const IntelligenceService = {
	async health(signal?: AbortSignal): Promise<IntelligenceHealth> {
		const env = await fetchApi<IntelligenceHealth>(
			"/api/intelligence/health",
			{ signal },
			{ timeoutMs: 8_000 },
		);
		return env.data;
	},

	async meta(signal?: AbortSignal): Promise<IntelligenceMeta> {
		const env = await fetchApi<IntelligenceMeta>(
			"/api/intelligence/meta",
			{ signal },
			{ timeoutMs: 15_000 },
		);
		return env.data;
	},

	async categories(signal?: AbortSignal): Promise<{
		count: number;
		categories: IntelligenceCategory[];
		category_groups: IntelligenceCategoryGroup[];
	}> {
		const env = await fetchApi<{
			count: number;
			categories: IntelligenceCategory[];
			category_groups: IntelligenceCategoryGroup[];
		}>("/api/intelligence/categories", { signal }, { timeoutMs: 15_000 });
		return env.data;
	},

	async detail(
		neighborhoodId: string,
		categoryId: string,
		signal?: AbortSignal,
	): Promise<IntelligenceDetail> {
		const env = await fetchApi<IntelligenceDetail>(
			`/api/intelligence/neighborhoods/${encodeURIComponent(neighborhoodId)}/categories/${encodeURIComponent(categoryId)}`,
			{ signal },
			{ timeoutMs: 15_000 },
		);
		return env.data;
	},

	async lens(
		providerId: string,
		opts: { category?: string; city?: string; limit?: number; signal?: AbortSignal },
	): Promise<IntelligenceLens> {
		const qs = new URLSearchParams();
		if (opts.category) qs.set("category", opts.category);
		if (opts.city) qs.set("city", opts.city);
		qs.set("limit", String(opts.limit ?? 40));
		const env = await fetchApi<IntelligenceLens>(
			`/api/intelligence/providers/${encodeURIComponent(providerId)}/lens?${qs}`,
			{ signal: opts.signal },
			{ timeoutMs: 15_000 },
		);
		return env.data;
	},

	async opportunities(opts: {
		provider?: string;
		city?: string;
		limit?: number;
		signal?: AbortSignal;
	}): Promise<IntelligenceOpportunities> {
		const qs = new URLSearchParams();
		if (opts.provider) qs.set("provider", opts.provider);
		if (opts.city) qs.set("city", opts.city);
		qs.set("limit", String(opts.limit ?? 12));
		const env = await fetchApi<IntelligenceOpportunities>(
			`/api/intelligence/opportunities?${qs}`,
			{ signal: opts.signal },
			{ timeoutMs: 15_000 },
		);
		return env.data;
	},

	async alerts(signal?: AbortSignal): Promise<IntelligenceAlerts> {
		const env = await fetchApi<IntelligenceAlerts>(
			"/api/intelligence/alerts",
			{ signal },
			{ timeoutMs: 12_000 },
		);
		return env.data;
	},

	async neighborhoodCategory(
		opts: {
			category?: string;
			city?: string;
			neighborhood?: string;
			provider?: string;
			minConfidence?: string;
			limit?: number;
			signal?: AbortSignal;
		} = {},
	): Promise<{
		count: number;
		results: IntelligenceNeighborhoodCategoryRow[];
	}> {
		const qs = new URLSearchParams();
		if (opts.category) qs.set("category", opts.category);
		if (opts.city) qs.set("city", opts.city);
		if (opts.neighborhood) qs.set("neighborhood", opts.neighborhood);
		if (opts.provider) qs.set("provider", opts.provider);
		if (opts.minConfidence) qs.set("min_confidence", opts.minConfidence);
		qs.set("limit", String(opts.limit ?? 400));
		const env = await fetchApi<{
			count: number;
			results: IntelligenceNeighborhoodCategoryRow[];
		}>(
			`/api/intelligence/neighborhood-category?${qs}`,
			{ signal: opts.signal },
			{ timeoutMs: 15_000 },
		);
		return env.data;
	},

	async mapPlaces(
		opts: {
			bbox?: string;
			zoom?: number;
			q?: string;
			category?: string;
			layer?: "difference" | "places" | "all_food" | "comparison";
			limit?: number;
			fields?: "pin" | "full";
			signal?: AbortSignal;
		} = {},
	): Promise<IntelligenceMapPlaces> {
		const qs = new URLSearchParams();
		if (opts.bbox) qs.set("bbox", opts.bbox);
		if (opts.zoom != null) qs.set("zoom", String(opts.zoom));
		if (opts.q) qs.set("q", opts.q);
		if (opts.category) qs.set("category", opts.category);
		if (opts.layer) qs.set("layer", opts.layer);
		qs.set("fields", opts.fields ?? "pin");
		qs.set("limit", String(opts.limit ?? 400));
		const env = await fetchApi<IntelligenceMapPlaces>(
			`/api/intelligence/map/places?${qs}`,
			{ signal: opts.signal },
			{ timeoutMs: 15_000 },
		);
		return env.data;
	},

	async mapPlace(
		placeId: string,
		signal?: AbortSignal,
	): Promise<IntelligenceMapPlaceDetail> {
		const env = await fetchApi<IntelligenceMapPlaceDetail>(
			`/api/intelligence/map/places/${encodeURIComponent(placeId)}`,
			{ signal },
			{ timeoutMs: 12_000 },
		);
		return env.data;
	},

	async mapNeighborhoods(
		opts: {
			category?: string;
			city?: string;
			signal?: AbortSignal;
		} = {},
	): Promise<IntelligenceMapNeighborhoods> {
		const qs = new URLSearchParams();
		if (opts.category) qs.set("category", opts.category);
		if (opts.city) qs.set("city", opts.city);
		const env = await fetchApi<IntelligenceMapNeighborhoods>(
			`/api/intelligence/map/neighborhoods?${qs}`,
			{ signal: opts.signal },
			{ timeoutMs: 20_000 },
		);
		return env.data;
	},
};
