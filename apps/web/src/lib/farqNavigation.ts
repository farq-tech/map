/**
 * "خذني هناك" — sending a person to the branch the price actually came from.
 *
 * The destination is decided on the server (apps/api/lib/place-navigation.js)
 * and arrives already resolved, because getting it wrong is not a rendering
 * mistake. A canonical restaurant carries one pin, but each delivery app lists
 * its own branch, and measured against production 591 Riyadh opportunities have
 * the cheapest branch more than a kilometre from the pin we draw — the worst by
 * 28.7 km. Drawing the pin there costs a glance; sending a person there costs
 * their evening.
 *
 * So this module only builds the link, and refuses to build one when the server
 * said it could not name a branch.
 */

export type NavigationDestination = {
	lat: number | null;
	lng: number | null;
	/** `branch` the cheapest app's own pin · `place` the restaurant pin · null unknown */
	source: "branch" | "place" | null;
	provider?: string | null;
	confidence:
		| "exact-branch"
		| "place-pin"
		| "place-pin-approximate"
		| "ambiguous-branch"
		| "unknown";
	/** How far the branch sits from the pin we drew, in metres. */
	disagreementMeters?: number | null;
	reason?: string;
};

export function canNavigate(
	destination: NavigationDestination | null | undefined,
): destination is NavigationDestination & { lat: number; lng: number } {
	return Boolean(
		destination &&
			typeof destination.lat === "number" &&
			typeof destination.lng === "number" &&
			Number.isFinite(destination.lat) &&
			Number.isFinite(destination.lng),
	);
}

/**
 * Six decimals is about 11 cm — past any pin's real accuracy and short of the
 * float noise that reprojection tools leave behind.
 */
function fixed(value: number): string {
	return value.toFixed(6);
}

/**
 * A universal directions link.
 *
 * Coordinates, never the restaurant's name. A name lets the map provider resolve
 * the destination to ITS OWN idea of which branch you meant, which is exactly
 * the thing this whole path exists to get right — and it would fail silently,
 * looking correct while sending someone to a different branch of the same chain.
 *
 * The universal `google.com/maps/dir` form opens the installed app on Android
 * and iOS and falls back to the browser elsewhere, so one link serves every
 * client the web app runs in.
 */
export function navigationUrl(
	destination: NavigationDestination | null | undefined,
): string | null {
	if (!canNavigate(destination)) return null;
	const target = `${fixed(destination.lat)},${fixed(destination.lng)}`;
	return `https://www.google.com/maps/dir/?api=1&destination=${encodeURIComponent(target)}&travelmode=driving`;
}

/**
 * What to say beside the button, when there is something worth saying.
 *
 * Silence for the ordinary case: 96% of destinations are the exact branch and a
 * label on all of them would be noise. A word only where the answer is weaker
 * than the button implies.
 */
export function navigationNote(
	destination: NavigationDestination | null | undefined,
	isRTL: boolean,
): string | null {
	if (!destination) return null;
	switch (destination.confidence) {
		case "ambiguous-branch":
			return isRTL
				? "هذا الاسم يغطي أكثر من فرع، وما نعرف أي فرع فيه هذا السعر"
				: "This listing covers several branches; we cannot tell which one holds this price";
		case "place-pin-approximate":
			return isRTL
				? "الموقع تقريبي — التطبيق ما نشر إحداثيات فرعه"
				: "Approximate — this app did not publish its branch coordinates";
		case "unknown":
			return isRTL ? "ما عندنا موقع مرصود لهذا المكان" : "No observed location for this place";
		default:
			return null;
	}
}

/** The app whose price we quoted, so the button can name the branch it means. */
export function navigationTarget(
	destination: NavigationDestination | null | undefined,
	providerLabel: (id: string) => string,
	isRTL: boolean,
): string | null {
	if (!destination || destination.source !== "branch" || !destination.provider) return null;
	const label = providerLabel(destination.provider);
	return isRTL ? `فرع ${label}` : `${label} branch`;
}
