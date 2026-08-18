// Canonical provider keys for Farq restaurant delivery. The canonical key is
// the backend provider_code spelling (full names) so this layer, the delivery
// normalizer (services/normalizeDeliveryResponse) and the comparison read layer
// all speak ONE vocabulary. Short/legacy spellings (hs, chefz, mandoob, …) are
// ALIASES resolved by normalizePlatformKey — never canonical keys.
export type PlatformKey =
	| "hungerstation"
	| "jahez"
	| "toyou"
	| "thechefz"
	| "ninja"
	| "keeta"
	| "mrsool"
	| "mrmandoob"
	| "brand_app";

export const PLATFORM_LOGOS: Record<
	PlatformKey,
	{ src: string; label: string; labelAr: string }
> = {
	// We ship the exact same icons locally to avoid hotlink/network issues.
	// The asset filename need not match the canonical key (hs.png / chefz.png
	// predate the rename); only the key vocabulary changed.
	// labelAr values mirror PROVIDER_NAMES_AR in MenuCatalog.tsx exactly —
	// the item modal and the final comparison must speak one name per locale.
	hungerstation: {
		src: "/platform_icons/hs.png",
		label: "HungerStation",
		labelAr: "هنقرستيشن",
	},
	jahez: { src: "/platform_icons/jahez.png", label: "Jahez", labelAr: "جاهز" },
	toyou: { src: "/platform_icons/toyou.png", label: "ToYou", labelAr: "تويو" },
	thechefz: {
		src: "/platform_icons/chefz.png",
		label: "The Chefz",
		labelAr: "ذا شفز",
	},
	ninja: { src: "/platform_icons/ninja.png", label: "Ninja", labelAr: "نينجا" },
	keeta: { src: "/platform_icons/keeta.png", label: "Keeta", labelAr: "كيتا" },
	mrsool: {
		src: "/platform_icons/mrsool.png",
		label: "Mrsool",
		labelAr: "مرسول",
	},
	mrmandoob: {
		src: "/platform_icons/mrmandoob.webp",
		label: "Mr. Mandoob",
		labelAr: "مرمندوب",
	},
	// brand_app is the restaurant's OWN app (official channel). Call
	// resolveProviderDisplayLogo with restaurantLogoUrl so the UI shows the
	// restaurant mark — this generic asset is only the last-resort fallback.
	brand_app: {
		src: "/platform_icons/brand_app.png",
		label: "Restaurant App",
		labelAr: "تطبيق المطعم",
	},
};

export function normalizePlatformKey(value: unknown): PlatformKey | null {
	// Collapse spaces, underscores, hyphens and dots so provider codes and
	// legacy aliases (hunger_station, to_you, mr_mandoob, the-chefz…) all
	// resolve to one canonical key.
	const raw = String(value ?? "")
		.trim()
		.toLowerCase()
		.replace(/[\s_.-]+/g, "");
	if (!raw) return null;

	// Aliases collapse INTO the canonical full-name key (hs → hungerstation,
	// chefz → thechefz, mandoob → mrmandoob).
	if (raw === "hungerstation" || raw === "hungerstationapp" || raw === "hs")
		return "hungerstation";
	if (raw === "jahez") return "jahez";
	if (raw === "toyou") return "toyou";
	if (raw === "thechefz" || raw === "chefz") return "thechefz";
	if (raw === "ninja" || raw === "ananinja") return "ninja";
	if (raw === "keeta") return "keeta";
	if (raw === "mrsool") return "mrsool";
	if (raw === "mrmandoob" || raw === "mandoob") return "mrmandoob";
	if (raw === "brandapp" || raw === "brand") return "brand_app";

	return null;
}

/** Every canonical provider key, in the same order as PlatformKey. */
export const ALL_PLATFORM_KEYS: readonly PlatformKey[] = [
	"hungerstation",
	"jahez",
	"toyou",
	"thechefz",
	"ninja",
	"keeta",
	"mrsool",
	"mrmandoob",
	"brand_app",
];

/** Per-provider item price map. Canonical keys; a missing provider = no price. */
export type PlatformPriceMap = Partial<Record<PlatformKey, number | null>>;

/**
 * THE single builder for a per-item price map from a provider's offers.
 *
 * Driven entirely by normalizePlatformKey — there is NO hardcoded provider
 * list, so every provider present in the offers is carried through and a
 * future tenth provider needs only a normalize alias, never an edit here or in
 * any caller. Keeps the lowest real (> 0) price when a provider appears twice.
 * Used by BOTH producers (restaurantService, MerchantHomePage) so the map can
 * never diverge or be rebuilt into a 6-key subset (Bug 1 root cause).
 */
export function buildPlatformPriceMap(
	offers:
		| ReadonlyArray<{ provider: unknown; price: unknown }>
		| null
		| undefined,
): PlatformPriceMap {
	const map: PlatformPriceMap = {};
	for (const offer of offers ?? []) {
		const key = normalizePlatformKey(offer.provider);
		if (!key) continue;
		const price =
			typeof offer.price === "number" ? offer.price : Number(offer.price);
		if (!Number.isFinite(price) || price <= 0) continue;
		const existing = map[key];
		if (existing == null || price < existing) map[key] = price;
	}
	return map;
}

export function getPlatformLogoByKey(key: unknown) {
	const normalized = normalizePlatformKey(key);
	if (!normalized) return null;
	return PLATFORM_LOGOS[normalized];
}

/**
 * Canonical provider-logo resolver for the trusted comparison layer.
 * Provider logos are Farq-owned brand assets resolved by provider_code —
 * NEVER a restaurant/branch image URL coming from provider data.
 *
 * For brand_app (restaurant's own channel), use resolveProviderDisplayLogo
 * with the restaurant logo instead of this generic mark.
 */
export function getProviderLogo(providerCode: unknown) {
	return getPlatformLogoByKey(providerCode);
}

export type ProviderDisplayLogo = {
	key: PlatformKey;
	src: string;
	label: string;
};

/**
 * Display logo for coverage chips / price marks. Marketplace providers use
 * Farq-owned platform icons; brand_app uses the restaurant's own logo when
 * available (agreed product rule — never the purple generic placeholder).
 */
export function resolveProviderDisplayLogo(
	providerCode: unknown,
	opts?: {
		isRTL?: boolean;
		restaurantLogoUrl?: string | null;
		restaurantName?: string | null;
	},
): ProviderDisplayLogo | null {
	const key = normalizePlatformKey(providerCode);
	if (!key) return null;
	const base = PLATFORM_LOGOS[key];
	const label =
		getProviderLabel(key, {
			isRTL: opts?.isRTL,
			restaurantName: opts?.restaurantName,
		}) ?? (opts?.isRTL ? base.labelAr : base.label);

	if (key === "brand_app") {
		const restLogo = opts?.restaurantLogoUrl?.trim() || null;
		return {
			key,
			src: restLogo || base.src,
			label,
		};
	}

	return { key, src: base.src, label };
}

/**
 * Canonical, user-facing provider label resolved from any spelling of the
 * provider code (mrmandoob → "Mr. Mandoob", thechefz → "The Chefz"). Returns
 * null for unknown codes so callers can fall back rather than print a raw key.
 *
 * `brand_app` is the restaurant's own app: pass `restaurantName` to render it
 * as that restaurant's app instead of the generic "Restaurant App" label.
 */
export function getProviderLabel(
	providerCode: unknown,
	opts?: { isRTL?: boolean; restaurantName?: string | null },
): string | null {
	const key = normalizePlatformKey(providerCode);
	if (!key) return null;
	if (key === "brand_app") {
		const name = opts?.restaurantName?.trim();
		if (name) return opts?.isRTL ? `تطبيق ${name}` : `${name} app`;
		return opts?.isRTL ? "تطبيق المطعم" : "Restaurant App";
	}
	// Locale-aware: the Arabic UI showed English names on the final comparison
	// while the item modal already spoke Arabic (QA consistency issue).
	return opts?.isRTL ? PLATFORM_LOGOS[key].labelAr : PLATFORM_LOGOS[key].label;
}
