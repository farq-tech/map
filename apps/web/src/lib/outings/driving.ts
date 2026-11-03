/**
 * Driving mode: bigger buttons and text on the outing screen while the car is
 * moving, so it can be read at a glance and hit with a thumb on a bumpy track.
 *
 * Hysteresis so it does not flicker at a junction: on above ~11 km/h, off only
 * after 20 s below ~5 km/h (or no speed at all).
 */

export const DRIVE_ON_MPS = 3;
export const DRIVE_OFF_MPS = 1.5;
export const DRIVE_HOLD_MS = 20_000;

export type DrivePref = "auto" | "on" | "off";

export type DriveState = { moving: boolean; slowSince: number | null };

export const DRIVE_IDLE: DriveState = { moving: false, slowSince: null };

export function nextDriveState(s: DriveState, speedMps: number | null | undefined, now: number): DriveState {
	const v = speedMps != null && Number.isFinite(speedMps) ? speedMps : 0;
	if (v > DRIVE_ON_MPS) return { moving: true, slowSince: null };
	if (!s.moving) return s.slowSince === null ? s : DRIVE_IDLE;
	if (v >= DRIVE_OFF_MPS) return { moving: true, slowSince: null };
	const since = s.slowSince ?? now;
	if (now - since >= DRIVE_HOLD_MS) return DRIVE_IDLE;
	return { moving: true, slowSince: since };
}

export function drivingOn(pref: DrivePref, s: DriveState): boolean {
	return pref === "on" || (pref === "auto" && s.moving);
}
