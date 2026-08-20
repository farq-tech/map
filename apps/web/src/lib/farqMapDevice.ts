/**
 * Map chrome / camera device gates. iPhone + Safari + coarse pointers
 * skip globe intro and Standard 3D objects. Terrain stays off everywhere.
 */

export function isCoarsePointerDevice(): boolean {
	if (typeof window === "undefined" || !window.matchMedia) return false;
	return window.matchMedia("(pointer: coarse)").matches;
}

export function isIPhoneOrSafari(): boolean {
	if (typeof navigator === "undefined") return false;
	const ua = navigator.userAgent || "";
	if (/iPhone|iPod/i.test(ua)) return true;
	return /Safari/i.test(ua) && !/Chrome|Chromium|Android|CriOS|FxiOS|EdgiOS/i.test(ua);
}

export function shouldShow3dObjects(opts?: {
	coarsePointer?: boolean;
	iphoneOrSafari?: boolean;
}): boolean {
	const coarse = opts?.coarsePointer ?? isCoarsePointerDevice();
	const safari = opts?.iphoneOrSafari ?? isIPhoneOrSafari();
	return !coarse && !safari;
}

export function shouldSkipGlobeIntro(opts?: {
	reducedMotion?: boolean;
	coarsePointer?: boolean;
	iphoneOrSafari?: boolean;
}): boolean {
	if (opts?.reducedMotion) return true;
	const coarse = opts?.coarsePointer ?? isCoarsePointerDevice();
	const safari = opts?.iphoneOrSafari ?? isIPhoneOrSafari();
	return coarse || safari;
}
