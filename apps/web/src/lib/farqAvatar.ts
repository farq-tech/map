/**
 * صورتك فوق سيارتك على الخريطة — وتبقى على جهازك.
 *
 * The photo is never uploaded. It is cropped, shrunk and stored in this
 * browser, and the marker reads it from there. That is not a limitation we
 * settled for; it is the design:
 *
 *   · a face is personal data, and the safest place to keep personal data is
 *     nowhere on our side
 *   · no upload means no consent flow, no storage cost, no moderation queue,
 *     no deletion request to honour, and nothing to leak
 *   · it works offline and appears instantly on the next visit
 *
 * The cost is honest and worth stating in the UI: the photo does not follow the
 * person to another device or another browser. Making it follow them needs
 * accounts and server storage, which is a different decision with a different
 * risk profile — see the note in FarqAvatarPicker.
 */

/**
 * The marker draws the avatar at 40 CSS pixels. Three times that is crisp on
 * every phone we care about and still lands around 6–10 KB, which fits a
 * synchronous store with room to spare.
 */
export const AVATAR_PX = 120;

/** Bigger than any photo needs to be before we even decode it. */
export const MAX_SOURCE_BYTES = 12 * 1024 * 1024;

const STORAGE_KEY = "farq.map.avatar.v1";

/**
 * The map marker lives far from the picker in the tree. Rather than thread a
 * photo through five components that do not care about it, the store announces
 * changes and the marker listens.
 */
export const AVATAR_CHANGED = "farq:avatar-changed";

function announce(): void {
	if (typeof window === "undefined") return;
	window.dispatchEvent(new CustomEvent(AVATAR_CHANGED));
}
const VEHICLE_KEY = "farq.map.vehicle.v1";

export type AvatarError = "not-an-image" | "too-large" | "unreadable";

/** Colours a car can be, because "any colour" is a colour picker nobody uses. */
export const VEHICLE_COLORS = [
	{ id: "navy", hex: "#1b2a4a", nameAr: "كحلي", nameEn: "Navy" },
	{ id: "white", hex: "#e8eef0", nameAr: "أبيض", nameEn: "White" },
	{ id: "silver", hex: "#9aa5ad", nameAr: "فضي", nameEn: "Silver" },
	{ id: "black", hex: "#15191c", nameAr: "أسود", nameEn: "Black" },
	{ id: "mint", hex: "#83f1b1", nameAr: "نعناعي", nameEn: "Mint" },
	{ id: "red", hex: "#b3202b", nameAr: "أحمر", nameEn: "Red" },
] as const;

export type VehicleColorId = (typeof VEHICLE_COLORS)[number]["id"];

export function vehicleColorHex(id: string | null | undefined): string {
	const found = VEHICLE_COLORS.find((c) => c.id === id);
	return (found || VEHICLE_COLORS[0]).hex;
}

/**
 * Reject before decoding. A file that is not an image, or is absurdly large,
 * should fail with a sentence a person can act on rather than a broken canvas.
 */
export function validateImageFile(
	file: { type?: string; size?: number } | null | undefined,
): AvatarError | null {
	if (!file) return "unreadable";
	if (!String(file.type || "").startsWith("image/")) return "not-an-image";
	if (Number(file.size) > MAX_SOURCE_BYTES) return "too-large";
	return null;
}

/**
 * The largest centred square inside a rectangle.
 *
 * A face photo is usually portrait and the face is usually near the top, so the
 * square is pulled slightly upward rather than centred exactly — centring a
 * portrait crop reliably cuts the forehead off.
 */
export function squareCrop(
	width: number,
	height: number,
): { sx: number; sy: number; size: number } {
	const size = Math.max(1, Math.min(width, height));
	const sx = Math.max(0, Math.round((width - size) / 2));
	const verticalBias = height > width ? 0.35 : 0.5;
	const sy = Math.max(0, Math.round((height - size) * verticalBias));
	return { sx, sy, size };
}

/**
 * A number of degrees, or null. Never a guess.
 *
 * The explicit null check is not defensive noise: `Number(null)` is 0, and 0 is
 * a perfectly valid heading meaning due north. Without this line a device that
 * reported no heading — which is every stationary device — would have its car
 * pointed north, confidently and wrongly.
 */
export function normalizeHeading(value: unknown): number | null {
	if (value === null || value === undefined || value === "") return null;
	const n = Number(value);
	if (!Number.isFinite(n)) return null;
	const wrapped = ((n % 360) + 360) % 360;
	return wrapped;
}

/**
 * Decode, crop to a square, shrink, and encode.
 *
 * Canvas rather than a library: the whole operation is twenty lines, and the
 * bundle has 148 KB of headroom that a cropping library would eat for a feature
 * this small.
 */
export async function processAvatar(file: File): Promise<string> {
	const problem = validateImageFile(file);
	if (problem) throw new Error(problem);

	const bitmap = await createImageBitmap(file).catch(() => null);
	if (!bitmap) throw new Error("unreadable" satisfies AvatarError);

	const { sx, sy, size } = squareCrop(bitmap.width, bitmap.height);
	const canvas = document.createElement("canvas");
	canvas.width = AVATAR_PX;
	canvas.height = AVATAR_PX;
	const ctx = canvas.getContext("2d");
	if (!ctx) throw new Error("unreadable" satisfies AvatarError);
	ctx.drawImage(bitmap, sx, sy, size, size, 0, 0, AVATAR_PX, AVATAR_PX);
	bitmap.close?.();

	/* WebP where it exists, JPEG everywhere else. Quality 0.82 is the point past
	 * which a 120px face stops getting visibly better and only gets heavier. */
	const webp = canvas.toDataURL("image/webp", 0.82);
	return webp.startsWith("data:image/webp") ? webp : canvas.toDataURL("image/jpeg", 0.82);
}

function safeStorage(): Storage | null {
	try {
		/* Private mode and locked-down browsers throw on access, not on use. */
		const s = window.localStorage;
		const probe = "__farq_probe__";
		s.setItem(probe, "1");
		s.removeItem(probe);
		return s;
	} catch {
		return null;
	}
}

/**
 * Synchronous on purpose. The marker needs the avatar on the first frame; an
 * async store would show a generic dot and then swap it, which reads as a bug.
 */
export function loadAvatar(): string | null {
	const s = safeStorage();
	if (!s) return null;
	const value = s.getItem(STORAGE_KEY);
	return value && value.startsWith("data:image/") ? value : null;
}

export function saveAvatar(dataUrl: string): boolean {
	const s = safeStorage();
	if (!s || !dataUrl.startsWith("data:image/")) return false;
	try {
		s.setItem(STORAGE_KEY, dataUrl);
		announce();
		return true;
	} catch {
		/* Quota. Nothing to do but tell the truth to the caller. */
		return false;
	}
}

export function clearAvatar(): void {
	safeStorage()?.removeItem(STORAGE_KEY);
	announce();
}

export function loadVehicleColor(): VehicleColorId {
	const s = safeStorage();
	const stored = s?.getItem(VEHICLE_KEY);
	return (VEHICLE_COLORS.find((c) => c.id === stored)?.id || "navy") as VehicleColorId;
}

export function saveVehicleColor(id: VehicleColorId): void {
	safeStorage()?.setItem(VEHICLE_KEY, id);
	announce();
}

/**
 * A top-down car, drawn rather than shipped as an asset so it can be tinted to
 * the chosen colour and stay crisp at any zoom. The map is flat — pitch 0 — so
 * top-down is the only view that is honest about where the car is.
 */
export function vehicleSvg(hex: string): string {
	const glass = "rgba(255,255,255,0.22)";
	return `<svg viewBox="0 0 40 78" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
  <defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="0">
    <stop offset="0" stop-color="${hex}" stop-opacity="0.75"/>
    <stop offset="0.5" stop-color="${hex}"/>
    <stop offset="1" stop-color="${hex}" stop-opacity="0.75"/>
  </linearGradient></defs>
  <rect x="3" y="2" width="34" height="74" rx="15" fill="url(#g)"/>
  <path d="M9 16 Q20 10 31 16 L29 27 Q20 24 11 27 Z" fill="${glass}"/>
  <path d="M10 52 Q20 49 30 52 L28 63 Q20 67 12 63 Z" fill="${glass}"/>
  <rect x="6" y="30" width="28" height="18" rx="6" fill="rgba(255,255,255,0.10)"/>
  <rect x="1" y="20" width="4" height="10" rx="2" fill="${hex}"/>
  <rect x="35" y="20" width="4" height="10" rx="2" fill="${hex}"/>
  <rect x="1" y="48" width="4" height="10" rx="2" fill="${hex}"/>
  <rect x="35" y="48" width="4" height="10" rx="2" fill="${hex}"/>
</svg>`;
}
