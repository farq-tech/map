// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import { PLATFORM_LOGOS } from "./platformLogos";
import { TOP_OPPORTUNITIES } from "./farqOpportunities";
import {
	BUBBLE_SIZE_BASE,
	BUBBLE_SIZE_MAX,
	BUBBLE_SIZE_MIN,
	BUBBLE_SIZE_SCALE,
	AURA_PROMOTE_MAX,
	AURA_PROMOTE_MAX_MOBILE,
	CLUSTER_BREAK_ZOOM,
	MAP_PIN_CAP,
	MAP_PIN_HTML_CAP,
	PIN_IDENTITY_ZOOM,
	auraPromoteCap,
	applyAuraRankClasses,
	pinPresentationForZoom,
	pinIdentityReveal,
	buildClusterPinElement,
	buildPlacePinElement,
	bubbleSizePx,
	clusterOpportunityCount,
	clusterOpportunityLabel,
	clusterGapHeroLabel,
	gapRiyalLabel,
	FARQ_CLUSTERS_CLASS,
	featureMarkerKey,
	observedClusterTopGap,
	observedDifferenceAmount,
	parseDifference,
	PLACE_HERO_PX,
	PROVIDER_HERO_PX,
	pinSizeTier,
	promotedAuraLimit,
	rankAuraPlaceIds,
	RESTAURANT_IMAGE_FIELDS,
	restaurantImageCoverage,
	restaurantMarkSizePx,
	restaurantPinInitial,
	resolveCheapestPinLogo,
	resolvePlacePinMarks,
	observedRestaurantImageUrl,
	sanitizeObservedImageUrl,
	setPinSelected,
	shouldAttachPinPhoto,
	shouldReplayBubbleMotion,
	pinDomCapForZoom,
	differenceFromPinProps,
	updatePlacePinChip,
} from "./farqMapPins";

describe("resolveCheapestPinLogo — honest cheapest-app only", () => {
	it("uses getProviderLogo(cheapest_provider_id) for a known winner", () => {
		const logo = resolveCheapestPinLogo({
			cheapest_provider_id: "jahez",
			difference_amount: 12,
		});
		expect(logo?.src).toBe(PLATFORM_LOGOS.jahez.src);
		expect(logo?.providerId).toBe("jahez");
	});

	it("normalizes aliases (hs → HungerStation asset)", () => {
		const logo = resolveCheapestPinLogo({ cheapest_provider_id: "hs" });
		expect(logo?.src).toBe(PLATFORM_LOGOS.hungerstation.src);
	});

	it("returns null when there is no cheapest_provider_id", () => {
		expect(resolveCheapestPinLogo(null)).toBeNull();
		expect(resolveCheapestPinLogo({})).toBeNull();
		expect(resolveCheapestPinLogo({ difference_amount: 4 })).toBeNull();
		expect(
			resolveCheapestPinLogo({ cheapest_provider_id: "" }),
		).toBeNull();
	});

	it("restaurantPinInitial uses the venue name, never «ف»", () => {
		expect(restaurantPinInitial("حصاد البن")).toBe("ح");
		expect(restaurantPinInitial("Burger Queen")).toBe("B");
		expect(restaurantPinInitial("")).toBe("•");
	});

	it("returns null for an unknown provider — never invents a logo URL", () => {
		expect(
			resolveCheapestPinLogo({ cheapest_provider_id: "talabat" }),
		).toBeNull();
	});

	it("parses Mapbox-stringified difference objects", () => {
		const logo = resolveCheapestPinLogo(
			JSON.stringify({ cheapest_provider_id: "keeta" }),
		);
		expect(logo?.src).toBe(PLATFORM_LOGOS.keeta.src);
		expect(parseDifference('{"cheapest_provider_id":"ninja"}')?.cheapest_provider_id).toBe(
			"ninja",
		);
	});
});

describe("Price Difference Bubble HTML", () => {
	it("renders a gap bubble with the cheapest app logo larger than the price chip", () => {
		const el = buildPlacePinElement({
			name: "برجر ستيشن",
			isRTL: true,
			difference: {
				cheapest_provider_id: "ninja",
				expensive_provider_id: "chefz",
				difference_amount: 18,
			},
		});
		expect(el.dataset.testid).toBe("farq-map-gap-bubble");
		expect(el.classList.contains("farq-gap-bubble--provider")).toBe(true);
		expect(el.dataset.mark).toBe("provider");
		expect(el.querySelector("img")?.getAttribute("src")).toContain("ninja");
		expect(Number(el.dataset.size)).toBeLessThan(PROVIDER_HERO_PX);
		expect(el.textContent).not.toContain("برجر ستيشن");
		expect(el.querySelector(".farq-gap-bubble-amount")?.textContent).toBe("+١٨");
		expect(el.textContent).not.toContain("ر.س");
		expect(el.querySelector(".farq-gap-bubble-currency")).toBeNull();
		expect(Number(el.dataset.size)).toBeLessThanOrEqual(BUBBLE_SIZE_MAX);
		expect(el.getAttribute("aria-label")).toBe(
			"فرق السعر ١٨ ريال في برجر ستيشن",
		);
	});

	it("tiny gaps show +N and initials — never +0, names, or both prices", () => {
		const el = buildPlacePinElement({
			name: "Cafe",
			difference: { difference_amount: 3, cheapest_price: 22, expensive_price: 25 },
		});
		expect(el.dataset.testid).toBe("farq-map-gap-bubble");
		expect(el.classList.contains("farq-gap-bubble--tiny")).toBe(true);
		expect(el.querySelector(".farq-gap-bubble-amount")?.textContent).toBe("+3");
		expect(el.textContent).not.toContain("Cafe");
		expect(el.textContent).not.toContain("22");
		expect(el.textContent).not.toContain("25");
	});

	it("keeps restaurant initials when the gap is missing, zero, or sub-riyal", () => {
		for (const difference of [null, { difference_amount: 0 }, { difference_amount: 0.4 }, {}]) {
			const el = buildPlacePinElement({
				name: "Golden cafe",
				difference,
			});
			expect(el.dataset.testid).toBe("farq-map-restaurant-pin");
			expect(el.className).toContain("farq-3d-pin--restaurant");
			expect(el.textContent).not.toMatch(/\+0|\+\?/);
			expect(el.querySelector(".farq-3d-pin-initial")?.textContent).toBe("G");
		}
	});

	it("does not mint a bubble from cheapest_provider_id alone", () => {
		const el = buildPlacePinElement({
			name: "Bestrito",
			difference: { cheapest_provider_id: "ninja" },
		});
		expect(el.dataset.testid).toBe("farq-map-restaurant-pin");
		expect(el.querySelector("img")?.getAttribute("src")).toContain("ninja");
		expect(el.querySelector(".farq-gap-bubble-amount")).toBeNull();
		expect(el.textContent).not.toContain("+");
	});

	it("cluster count is observed opportunities and never invents a provider logo", () => {
		const el = buildClusterPinElement({ count: 14, differenceCount: 3 });
		expect(el.classList.contains(FARQ_CLUSTERS_CLASS)).toBe(true);
		expect(el.classList.contains("farq-3d-cluster--opportunity")).toBe(true);
		expect(el.querySelector(".farq-3d-cluster-count")?.textContent).toBe("🔥 3 places");
		expect(el.dataset.opportunities).toBe("3");
		expect(el.dataset.count).toBe("14");
		expect(el.querySelector(".farq-3d-cluster-gap")).toBeNull();
		expect(el.querySelector("img")).toBeNull();
		expect(el.dataset.provider).toBeUndefined();
	});

	it("opportunity cluster shows an observed top gap and never invents one", () => {
		const plain = buildClusterPinElement({ count: 24, differenceCount: 24, isRTL: true });
		expect(plain.querySelector(".farq-3d-cluster-gap")).toBeNull();
		expect(plain.querySelector(".farq-3d-cluster-count")?.textContent).toBe("🔥 ٢٤ مكان");
		expect(plain.textContent).not.toMatch(/\+/);

		const topped = buildClusterPinElement({
			count: 24,
			differenceCount: 24,
			topGap: 18,
			isRTL: true,
		});
		expect(topped.querySelector(".farq-3d-cluster-gap")?.textContent).toBe("🔥 ١٨ ر.س فرق");
		expect(topped.querySelector(".farq-3d-cluster-count")?.textContent).toBe("٢٤ مكان");
		expect(topped.querySelector("img")).toBeNull();
	});

	it("selected bubble is a class + z-index toggle", () => {
		const el = buildPlacePinElement({
			name: "X",
			difference: { difference_amount: 18 },
		});
		expect(el.classList.contains("is-selected")).toBe(false);
		setPinSelected(el, true);
		expect(el.classList.contains("is-selected")).toBe(true);
		expect(Number(el.style.zIndex)).toBeGreaterThan(1000);
	});
});

describe("featureMarkerKey", () => {
	it("keys by place_id only — gap or photo flicker does not remint", () => {
		const key = featureMarkerKey({
			type: "Feature",
			geometry: { type: "Point", coordinates: [46.67, 24.71] },
			properties: {
				feature_type: "place",
				place_id: "FARQ-PLACE-008559",
				difference: {
					cheapest_provider_id: "ninja",
					expensive_provider_id: "chefz",
					difference_amount: 18.4,
				},
			},
		});
		expect(key).toBe("place:FARQ-PLACE-008559");
	});

	it("stays place:id when a restaurant photo arrives", () => {
		const key = featureMarkerKey({
			type: "Feature",
			geometry: { type: "Point", coordinates: [46.67, 24.71] },
			properties: {
				feature_type: "place",
				place_id: "FARQ-PLACE-008559",
				image_url: "https://images.deliveryhero.io/image/logo.png",
				difference: { difference_amount: 18 },
			},
		});
		expect(key).toBe("place:FARQ-PLACE-008559");
	});

	it("keys places without an observed gap as place:id — not a fake +0", () => {
		const key = featureMarkerKey({
			type: "Feature",
			geometry: { type: "Point", coordinates: [46.67, 24.71] },
			properties: {
				feature_type: "place",
				place_id: "FARQ-PLACE-1",
				has_difference: false,
			},
		});
		expect(key).toBe("place:FARQ-PLACE-1");
	});

	it("updates the mint chip in place instead of reminting", () => {
		const el = buildPlacePinElement({
			name: "X",
			difference: { difference_amount: 12 },
		});
		updatePlacePinChip(el, 22);
		expect(el.dataset.amount).toBe("22");
		expect(el.querySelector(".farq-gap-bubble-amount")?.textContent).toBe("+22");
	});

	it("reads slim gap + cheapest_provider_id without a nested difference", () => {
		expect(
			differenceFromPinProps({
				gap: 18,
				cheapest_provider_id: "jahez",
			}),
		).toEqual({
			difference_amount: 18,
			cheapest_provider_id: "jahez",
			expensive_provider_id: null,
			cheapest_price: null,
			expensive_price: null,
			product_name: null,
		});
	});
});

describe("bubble size — observed difference only", () => {
	it("rejects missing, zero, and sub-riyal gaps", () => {
		expect(observedDifferenceAmount(null)).toBeNull();
		expect(observedDifferenceAmount({ difference_amount: 0 })).toBeNull();
		expect(observedDifferenceAmount({ difference_amount: 0.4 })).toBeNull();
		expect(observedDifferenceAmount({ cheapest_provider_id: "jahez" })).toBeNull();
		expect(observedDifferenceAmount({ difference_amount: 18 })).toBe(18);
	});

	it("uses clamp(MIN, BASE + sqrt(diff) * SCALE, MAX)", () => {
		const expected = (diff: number) =>
			Math.max(
				BUBBLE_SIZE_MIN,
				Math.min(BUBBLE_SIZE_MAX, BUBBLE_SIZE_BASE + Math.sqrt(diff) * BUBBLE_SIZE_SCALE),
			);
		expect(bubbleSizePx(3)).toBeCloseTo(expected(3));
		expect(bubbleSizePx(18)).toBeCloseTo(expected(18));
		expect(bubbleSizePx(3)).toBeLessThan(bubbleSizePx(18));
		expect(bubbleSizePx(3)).toBeGreaterThanOrEqual(BUBBLE_SIZE_MIN);
		expect(bubbleSizePx(18)).toBeLessThanOrEqual(BUBBLE_SIZE_MAX);
		expect(bubbleSizePx(400)).toBe(BUBBLE_SIZE_MAX);
		expect(BUBBLE_SIZE_MAX).toBeLessThan(PROVIDER_HERO_PX);
		expect(bubbleSizePx(18)).toBeGreaterThanOrEqual(20);
		expect(bubbleSizePx(18)).toBeLessThanOrEqual(24);
		expect(bubbleSizePx(18)).toBeLessThan(PROVIDER_HERO_PX);
	});

	it("stamps pixel size from the observed gap, not rating or count", () => {
		const small = buildPlacePinElement({
			name: "X",
			difference: { difference_amount: 3, provider_count: 9 },
		});
		const large = buildPlacePinElement({
			name: "X",
			difference: { difference_amount: 18, provider_count: 2 },
		});
		expect(Number(small.dataset.size)).toBe(Math.round(bubbleSizePx(3)));
		expect(Number(large.dataset.size)).toBe(Math.round(bubbleSizePx(18)));
		expect(Number(small.dataset.size)).toBeLessThan(Number(large.dataset.size));
	});

	it("replays motion only for new pins or a clearly changed gap", () => {
		const prev = new Map<string, number>([["a", 18]]);
		expect(shouldReplayBubbleMotion("b", 4, prev)).toBe(true);
		expect(shouldReplayBubbleMotion("a", 18, prev)).toBe(false);
		expect(shouldReplayBubbleMotion("a", 18.2, prev)).toBe(false);
		expect(shouldReplayBubbleMotion("a", 22, prev)).toBe(true);
	});

	it("keeps pinSizeTier readable for leftover restaurant chrome", () => {
		expect(pinSizeTier(null)).toBe("md");
		expect(pinSizeTier(5)).toBe("sm");
		expect(pinSizeTier(120)).toBe("lg");
	});
});

describe("resolvePlacePinMarks — honest winner + expensive only", () => {
	it("treats cheapest as winner and expensive as the only other chip", () => {
		const marks = resolvePlacePinMarks(
			{
				cheapest_provider_id: "ninja",
				expensive_provider_id: "chefz",
			},
			3,
		);
		expect(marks.winner?.providerId).toBe("ninja");
		expect(marks.winner?.src).toBe(PLATFORM_LOGOS.ninja.src);
		expect(marks.others.map((m) => m.providerId)).toEqual(["chefz"]);
		expect(marks.others[0]?.src).toBe(PLATFORM_LOGOS.thechefz.src);
		expect(marks.extraCount).toBe(1);
	});

	it("dedupes aliases so hs is not a second HungerStation chip", () => {
		const marks = resolvePlacePinMarks({
			cheapest_provider_id: "hungerstation",
			expensive_provider_id: "hs",
		});
		expect(marks.winner?.providerId).toBe("hungerstation");
		expect(marks.others).toEqual([]);
		expect(marks.extraCount).toBe(0);
	});
});

describe("Price Aura viewport rank + cluster honesty", () => {
	it("ranks top gaps and switches pin presentation at the cluster break", () => {
		const items = Array.from({ length: 20 }, (_, i) => ({
			placeId: `p${i}`,
			amount: i + 1,
		}));
		expect(CLUSTER_BREAK_ZOOM).toBe(14);
		expect(PIN_IDENTITY_ZOOM).toBe(14);
		expect(MAP_PIN_CAP).toBe(400);
		expect(TOP_OPPORTUNITIES).toBe(10);
		expect(MAP_PIN_HTML_CAP).toBe(1);
		expect(pinDomCapForZoom(16)).toBe(1);
		expect(shouldAttachPinPhoto(false)).toBe(false);
		expect(shouldAttachPinPhoto(true)).toBe(true);
		expect(promotedAuraLimit(20)).toBe(AURA_PROMOTE_MAX);
		expect(promotedAuraLimit(6)).toBe(6);
		expect(auraPromoteCap(true)).toBe(AURA_PROMOTE_MAX_MOBILE);
		expect(promotedAuraLimit(20, auraPromoteCap(true))).toBe(8);
		expect(pinPresentationForZoom(11.8)).toBe("amount");
		expect(pinPresentationForZoom(13.9)).toBe("amount");
		expect(pinPresentationForZoom(14)).toBe("identity");
		expect(pinPresentationForZoom(16)).toBe("identity");
		expect(pinIdentityReveal(13.2)).toBe(0);
		expect(pinIdentityReveal(13.99)).toBeGreaterThan(0.4);
		expect(pinIdentityReveal(13.99)).toBeLessThan(0.6);
		expect(pinIdentityReveal(14.01)).toBeGreaterThan(pinIdentityReveal(13.99));
		expect(pinIdentityReveal(14.7)).toBe(1);
		const top = rankAuraPlaceIds(items);
		expect(top.size).toBe(12);
		expect(top.has("p19")).toBe(true);
		expect(top.has("p8")).toBe(true);
		expect(top.has("p7")).toBe(false);
	});

	it("toggles rank classes without reminting HTML", () => {
		const el = buildPlacePinElement({
			name: "X",
			difference: { difference_amount: 12 },
		});
		applyAuraRankClasses(el, "promoted");
		expect(el.dataset.rank).toBe("promoted");
		expect(el.classList.contains("farq-gap-bubble--promoted")).toBe(true);
		applyAuraRankClasses(el, "demoted");
		expect(el.dataset.rank).toBe("demoted");
		expect(el.classList.contains("farq-gap-bubble--demoted")).toBe(true);
		applyAuraRankClasses(el, "visible");
		expect(el.dataset.rank).toBe("visible");
		expect(el.classList.contains("farq-gap-bubble--demoted")).toBe(false);
		expect(el.classList.contains("farq-gap-bubble--promoted")).toBe(false);
		expect(el.querySelector(".farq-gap-bubble-amount")?.textContent).toBe("+12");
	});

	it("reads an observed cluster top gap and refuses a missing one", () => {
		expect(observedClusterTopGap({ difference: { difference_amount: 18 } })).toBe(18);
		expect(observedClusterTopGap({ max_difference_amount: 12.4 })).toBe(12.4);
		expect(observedClusterTopGap({ top_difference_amount: 0.4 })).toBeNull();
		expect(observedClusterTopGap({ max_difference_amount: 0 })).toBeNull();
		expect(observedClusterTopGap({ })).toBeNull();
		expect(clusterOpportunityCount({ count: 24, differenceCount: 8 })).toBe(8);
		expect(clusterOpportunityCount({ count: 14 })).toBe(14);
		expect(clusterOpportunityLabel(24, true)).toBe("٢٤ مكان");
		expect(gapRiyalLabel(38, true)).toBe("٣٨ ر.س فرق");
		expect(clusterGapHeroLabel(38, true)).toBe("🔥 ٣٨ ر.س فرق");
	});
});

describe("restaurant identity on Price Aura — real URLs only", () => {
	it("accepts only observed http(s) or same-origin paths", () => {
		expect(sanitizeObservedImageUrl("https://images.deliveryhero.io/logo.png")).toBe(
			"https://images.deliveryhero.io/logo.png",
		);
		expect(sanitizeObservedImageUrl("//cdn.example/r.png")).toBe(
			"https://cdn.example/r.png",
		);
		expect(sanitizeObservedImageUrl("/brand/local.png")).toBe("/brand/local.png");
		expect(sanitizeObservedImageUrl("")).toBeNull();
		expect(sanitizeObservedImageUrl("   ")).toBeNull();
		expect(sanitizeObservedImageUrl("javascript:alert(1)")).toBeNull();
		expect(sanitizeObservedImageUrl("data:image/png;base64,aaaa")).toBeNull();
		expect(sanitizeObservedImageUrl("not-a-url")).toBeNull();
	});

	it("reads comparison-layer image_url / branch_image_url and ignores junk", () => {
		expect(RESTAURANT_IMAGE_FIELDS[0]).toBe("image_url");
		expect(RESTAURANT_IMAGE_FIELDS).toContain("branch_image_url");
		expect(
			observedRestaurantImageUrl({
				image_url: "https://images.deliveryhero.io/logo.png",
			}),
		).toBe("https://images.deliveryhero.io/logo.png");
		expect(
			observedRestaurantImageUrl({
				branch_image_url: "https://img.ananinja.com/r.png",
			}),
		).toBe("https://img.ananinja.com/r.png");
		expect(
			observedRestaurantImageUrl({
				image_url: "",
				restaurant_logo_url: "https://cdn.example/brand.png",
			}),
		).toBe("https://cdn.example/brand.png");
		expect(observedRestaurantImageUrl({ image_url: "unsplash-invented" })).toBeNull();
		expect(observedRestaurantImageUrl({ cheapest_provider_id: "jahez" })).toBeNull();
		expect(observedRestaurantImageUrl(null)).toBeNull();
	});

	it("keeps the app logo larger than the max price chip", () => {
		expect(BUBBLE_SIZE_MIN).toBe(20);
		expect(BUBBLE_SIZE_MAX).toBe(24);
		expect(BUBBLE_SIZE_MAX).toBeLessThanOrEqual(26);
		expect(PROVIDER_HERO_PX).toBeGreaterThan(BUBBLE_SIZE_MAX);
		expect(PLACE_HERO_PX).toBeGreaterThan(BUBBLE_SIZE_MAX);
		expect(BUBBLE_SIZE_MAX).toBeLessThanOrEqual(PROVIDER_HERO_PX - 16);
	});

	it("sits the cheapest app logo as the hero with a smaller price chip", () => {
		const src = "https://images.deliveryhero.io/image/hungerstation/restaurant/logo/abc.png";
		const el = buildPlacePinElement({
			name: "كودو",
			isRTL: true,
			imageUrl: src,
			difference: { difference_amount: 18, cheapest_provider_id: "jahez" },
		});
		const img = el.querySelector("img");
		expect(el.dataset.mark).toBe("provider");
		expect(el.classList.contains("farq-gap-bubble--provider")).toBe(true);
		expect(
			(el.querySelector(".farq-gap-bubble-mark") as HTMLElement | null)?.dataset.kind,
		).toBe("provider");
		expect(img?.getAttribute("src")).toBe(PLATFORM_LOGOS.jahez.src);
		expect(Number(el.dataset.size)).toBeLessThanOrEqual(BUBBLE_SIZE_MAX);
		expect(Number(el.dataset.size)).toBeLessThan(PROVIDER_HERO_PX);
		expect(el.querySelector(".farq-gap-bubble-amount")?.textContent).toBe("+١٨");
		expect(el.textContent).not.toContain("ر.س");
		expect(el.style.getPropertyValue("--farq-hero-size")).toBe(`${PROVIDER_HERO_PX}px`);
	});

	it("falls back to initials when the photo URL is missing — never invents Unsplash", () => {
		const el = buildPlacePinElement({
			name: "حصاد البن",
			imageUrl: null,
			difference: { difference_amount: 12 },
		});
		expect(el.querySelector("img")).toBeNull();
		expect(el.dataset.mark).toBe("initials");
		expect(el.querySelector(".farq-gap-bubble-mark-initial")?.textContent).toBe("ح");
		expect(el.querySelector(".farq-gap-bubble-stem")).toBeTruthy();
		expect(el.innerHTML).not.toContain("unsplash");
	});

	it("never attaches a restaurant photo on unselected pins", () => {
		const el = buildPlacePinElement({
			name: "كودو",
			imageUrl: "https://images.deliveryhero.io/logo.png",
			includePhoto: false,
			difference: { difference_amount: 12 },
		});
		expect(el.querySelector("img")).toBeNull();
		expect(el.dataset.mark).toBe("initials");
	});

	it("hides a broken photo and shows initials on error", () => {
		const el = buildPlacePinElement({
			name: "Burger Queen",
			imageUrl: "https://cdn.example/missing-logo.png",
			includePhoto: true,
			difference: { difference_amount: 7 },
		});
		const img = el.querySelector("img");
		expect(img).toBeTruthy();
		img?.dispatchEvent(new Event("error"));
		expect(el.querySelector("img")).toBeNull();
		expect(el.querySelector(".farq-gap-bubble-mark-initial")?.textContent).toBe("B");
	});

	it("no-gap pins use the restaurant photo or initials — never +0", () => {
		const initials = buildPlacePinElement({
			name: "Golden cafe",
			difference: null,
		});
		expect(initials.dataset.testid).toBe("farq-map-restaurant-pin");
		expect(initials.querySelector(".farq-place-pin-initial, .farq-3d-pin-initial")?.textContent).toBe("G");
		expect(initials.textContent).not.toMatch(/\+0|\+\?/);

		const photo = buildPlacePinElement({
			name: "Golden cafe",
			difference: null,
			includePhoto: true,
			imageUrl: "https://images.deliveryhero.io/logo.png",
		});
		expect(photo.dataset.mark).toBe("logo");
		expect(photo.querySelector("img")?.getAttribute("src")).toContain(
			"images.deliveryhero.io",
		);
		expect(photo.textContent).not.toMatch(/\+0|\+\?/);
	});

	it("reports honest logo coverage and never counts clusters", () => {
		const coverage = restaurantImageCoverage([
			{ properties: { feature_type: "place", image_url: "https://cdn.example/a.png" } },
			{ properties: { feature_type: "place", name: "X" } },
			{ properties: { feature_type: "cluster", count: 8 } },
			{ properties: { feature_type: "place", branch_image_url: "" } },
		]);
		expect(coverage).toEqual({ total: 3, withImage: 1, withoutImage: 2 });
	});
});
