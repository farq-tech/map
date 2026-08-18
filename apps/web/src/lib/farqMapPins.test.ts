// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import { PLATFORM_LOGOS } from "./platformLogos";
import {
	BUBBLE_SIZE_BASE,
	BUBBLE_SIZE_MAX,
	BUBBLE_SIZE_MIN,
	BUBBLE_SIZE_SCALE,
	AURA_PROMOTE_MAX,
	applyAuraRankClasses,
	buildClusterPinElement,
	buildPlacePinElement,
	bubbleSizePx,
	clusterOpportunityCount,
	clusterOpportunityLabel,
	FARQ_CLUSTERS_CLASS,
	featureMarkerKey,
	observedClusterTopGap,
	observedDifferenceAmount,
	parseDifference,
	PLACE_HERO_PX,
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
	shouldReplayBubbleMotion,
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
	it("renders a gap bubble from observed difference_amount — no app logos or names", () => {
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
		expect(el.classList.contains("farq-gap-bubble")).toBe(true);
		expect(el.querySelector("img")).toBeNull();
		expect(el.textContent).not.toContain("Ninja");
		expect(el.textContent).not.toContain("برجر ستيشن");
		expect(el.textContent).toContain("+١٨");
		expect(el.textContent).toContain("ر.س");
		expect(el.getAttribute("aria-label")).toBe(
			"فرق السعر ١٨ ريال في برجر ستيشن",
		);
		expect(el.querySelector(".farq-gap-bubble-mark")?.textContent).toBe("ب");
		expect(el.querySelector(".farq-gap-bubble-stem")).toBeTruthy();
		
		expect(el.querySelector(".farq-gap-bubble-field")).toBeTruthy();
		expect(el.classList.contains("farq-gap-bubble--aura")).toBe(true);
		expect(el.querySelector(".farq-gap-bubble-amount")?.textContent).toBe("+١٨");
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
		expect(el.querySelector("img")).toBeNull();
		expect(el.textContent).not.toContain("+");
	});

	it("cluster keeps the count and never invents a provider logo", () => {
		const el = buildClusterPinElement({ count: 14, differenceCount: 3 });
		expect(el.classList.contains(FARQ_CLUSTERS_CLASS)).toBe(true);
		expect(el.classList.contains("farq-3d-cluster--opportunity")).toBe(true);
		expect(el.querySelector(".farq-3d-cluster-count")?.textContent).toBe("3 opps");
		expect(el.querySelector(".farq-3d-cluster-gap")).toBeNull();
		expect(el.querySelector("img")).toBeNull();
		expect(el.dataset.provider).toBeUndefined();
	});

	it("opportunity cluster shows an observed top gap and never invents one", () => {
		const plain = buildClusterPinElement({ count: 24, differenceCount: 24, isRTL: true });
		expect(plain.querySelector(".farq-3d-cluster-gap")).toBeNull();
		expect(plain.querySelector(".farq-3d-cluster-count")?.textContent).toBe("٢٤ فرصة");
		expect(plain.textContent).not.toMatch(/\+/);

		const topped = buildClusterPinElement({
			count: 24,
			differenceCount: 24,
			topGap: 18,
			isRTL: true,
		});
		expect(topped.querySelector(".farq-3d-cluster-gap")?.textContent).toBe("+١٨");
		expect(topped.querySelector(".farq-3d-cluster-count")?.textContent).toBe("٢٤ فرصة");
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
	it("keys observed gaps by place_id + rounded riyals", () => {
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
		expect(key).toBe("place:FARQ-PLACE-008559:bubble:18:mark");
	});

	it("keys an observed restaurant photo so the pin remints when a logo arrives", () => {
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
		expect(key).toBe("place:FARQ-PLACE-008559:bubble:18:logo");
	});

	it("keys places without an observed gap as restaurant — not a fake +0", () => {
		const key = featureMarkerKey({
			type: "Feature",
			geometry: { type: "Point", coordinates: [46.67, 24.71] },
			properties: {
				feature_type: "place",
				place_id: "FARQ-PLACE-1",
				has_difference: false,
			},
		});
		expect(key).toBe("place:FARQ-PLACE-1:restaurant:mark");
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
		expect(bubbleSizePx(7) - bubbleSizePx(3)).toBeGreaterThanOrEqual(5);
		expect(bubbleSizePx(12) - bubbleSizePx(7)).toBeGreaterThanOrEqual(5);
		expect(bubbleSizePx(18) - bubbleSizePx(12)).toBeGreaterThanOrEqual(4);
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
	it("promotes the top 8–12 observed gaps and never invents extras", () => {
		const items = Array.from({ length: 20 }, (_, i) => ({
			placeId: `p${i}`,
			amount: i + 1,
		}));
		expect(promotedAuraLimit(20)).toBe(AURA_PROMOTE_MAX);
		expect(promotedAuraLimit(6)).toBe(6);
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
		expect(clusterOpportunityLabel(24, true)).toBe("٢٤ فرصة");
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

	it("keeps the circular restaurant hero at least as large as the max aura chip", () => {
		expect(PLACE_HERO_PX).toBeGreaterThan(restaurantMarkSizePx(52));
		expect(PLACE_HERO_PX).toBeGreaterThanOrEqual(BUBBLE_SIZE_MAX);
	});

	it("sits a real restaurant photo as the hero with a small Farq chip and tiny stem", () => {
		const src = "https://images.deliveryhero.io/image/hungerstation/restaurant/logo/abc.png";
		const el = buildPlacePinElement({
			name: "كودو",
			isRTL: true,
			imageUrl: src,
			difference: { difference_amount: 18, cheapest_provider_id: "jahez" },
		});
		const img = el.querySelector("img");
		expect(el.dataset.mark).toBe("logo");
		expect(el.classList.contains("farq-gap-bubble--logo")).toBe(true);
		expect(
			(el.querySelector(".farq-gap-bubble-mark") as HTMLElement | null)?.dataset.kind,
		).toBe("photo");
		expect(img).toBeTruthy();
		expect(img?.getAttribute("src")).toContain("images.deliveryhero.io");
		expect(el.querySelector(".farq-gap-bubble-amount")?.textContent).toBe("+١٨");
		expect(el.querySelector(".farq-gap-bubble-stem .farq-brand-mark")).toBeTruthy();
		
		expect(el.textContent).not.toContain("كودو");
		expect(el.textContent).not.toContain("جاهز");
		expect(el.textContent).not.toContain("Jahez");
		expect(el.style.getPropertyValue("--farq-hero-size")).toBe(`${PLACE_HERO_PX}px`);
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

	it("hides a broken photo and shows initials on error", () => {
		const el = buildPlacePinElement({
			name: "Burger Queen",
			imageUrl: "https://cdn.example/missing-logo.png",
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
