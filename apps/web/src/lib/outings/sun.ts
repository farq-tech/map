/**
 * Where the sun is, from the date and a position only — no network. Good to
 * about a minute, which is plenty for "is it dark out there".
 * (Low-precision solar position, Astronomical Almanac.)
 */

const RAD = Math.PI / 180;

/** Sun's elevation above the horizon, degrees. */
export function solarElevationDeg(date: Date, lat: number, lng: number): number {
	const d = date.getTime() / 86_400_000 + 2440587.5 - 2451545.0;
	const g = (357.529 + 0.98560028 * d) * RAD;
	const q = 280.459 + 0.98564736 * d;
	const L = (q + 1.915 * Math.sin(g) + 0.02 * Math.sin(2 * g)) * RAD;
	const e = (23.439 - 0.00000036 * d) * RAD;
	const ra = Math.atan2(Math.cos(e) * Math.sin(L), Math.cos(L));
	const dec = Math.asin(Math.sin(e) * Math.sin(L));
	const gmst = (18.697374558 + 24.06570982441908 * d) % 24;
	const ha = (gmst * 15 + lng) * RAD - ra;
	const phi = lat * RAD;
	return Math.asin(Math.sin(phi) * Math.sin(dec) + Math.cos(phi) * Math.cos(dec) * Math.cos(ha)) / RAD;
}

/** Upper limb on the horizon, with refraction. */
const SUNSET_ELEVATION = -0.833;

/**
 * Sunset (UTC) on the local solar day of `date`, or null for polar day/night.
 * Searches minute by minute after solar noon.
 */
export function sunsetUtc(date: Date, lat: number, lng: number): Date | null {
	const day = Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate());
	/* Local solar noon is about 12:00 minus 4 min per degree east. */
	const noon = day + (12 - lng / 15) * 3_600_000;
	let prev = solarElevationDeg(new Date(noon), lat, lng);
	for (let m = 1; m <= 14 * 60; m += 1) {
		const t = noon + m * 60_000;
		const el = solarElevationDeg(new Date(t), lat, lng);
		if (prev >= SUNSET_ELEVATION && el < SUNSET_ELEVATION) return new Date(t);
		prev = el;
	}
	return null;
}

export type LightPreset = "dawn" | "day" | "dusk" | "night";

/**
 * Basemap light for the moment: day above a few degrees, dusk/dawn through
 * civil twilight, night once the sun is 6° under.
 */
export function lightPresetAt(date: Date, lat: number, lng: number): LightPreset {
	const el = solarElevationDeg(date, lat, lng);
	if (el > 4) return "day";
	if (el <= -6) return "night";
	/* Morning or evening: is the sun rising? */
	const later = solarElevationDeg(new Date(date.getTime() + 10 * 60_000), lat, lng);
	return later > el ? "dawn" : "dusk";
}
