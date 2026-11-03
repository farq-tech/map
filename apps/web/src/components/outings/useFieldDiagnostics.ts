import { useCallback, useEffect, useRef, useState, type MutableRefObject } from "react";
import {
	buildReport,
	clearDiag,
	createDiagState,
	detectDevice,
	diag,
	isFieldTestOn,
	loadDiag,
	saveDiag,
	setFieldTestOn,
	type DiagReport,
	type DiagState,
} from "../../lib/outings/fieldDiagnostics";
import { safeGet, safeRemove, safeSet } from "../../lib/safeStorage";
import type { ShareMode } from "../../lib/outings/policy";

const store = {
	get: (k: string) => safeGet("localStorage", k),
	set: (k: string, v: string) => safeSet("localStorage", k, v),
	remove: (k: string) => safeRemove("localStorage", k),
};

export type FieldDiag = {
	on: boolean;
	ref: MutableRefObject<DiagState | null>;
};

type BatteryLike = { level: number; charging: boolean; addEventListener?: (t: string, f: () => void) => void; removeEventListener?: (t: string, f: () => void) => void };

/**
 * Owns the on-device field-test recorder for one outing screen: the opt-in
 * flag, persistence (every 15 s and when the page goes away), visibility and
 * battery sampling. Link, fix and send events are fed by useLiveOuting; wake
 * lock and peer counts by OutingLive.
 */
export function useFieldDiagnostics(outingId: string, mode: ShareMode) {
	const [on, setOn] = useState(() => isFieldTestOn(store));
	const ref = useRef<DiagState | null>(null);
	const [hasData, setHasData] = useState(() => loadDiag(store, outingId) != null);
	const modeRef = useRef(mode);
	modeRef.current = mode;

	const persist = useCallback(() => {
		const s = ref.current;
		if (s) saveDiag(store, outingId, s);
	}, [outingId]);

	useEffect(() => {
		if (!on) return;
		const nav = typeof navigator !== "undefined" ? navigator : undefined;
		const standalone = typeof window !== "undefined" && window.matchMedia?.("(display-mode: standalone)").matches === true;
		const s = loadDiag(store, outingId) ?? createDiagState(detectDevice(nav?.userAgent ?? "", standalone), modeRef.current);
		ref.current = s;
		const now = Date.now();
		diag.startSession(s, now, modeRef.current);
		diag.visibility(s, typeof document === "undefined" || document.visibilityState !== "hidden", now);
		if (nav && "wakeLock" in nav) diag.wake(s, "supported");
		saveDiag(store, outingId, s);
		setHasData(true);

		const onVis = () => {
			if (!ref.current) return;
			diag.visibility(ref.current, document.visibilityState !== "hidden", Date.now());
			persist();
		};
		document.addEventListener("visibilitychange", onVis);
		window.addEventListener("pagehide", persist);
		const saveTimer = window.setInterval(persist, 15_000);

		/* Battery API: Chrome on Android has it; Safari does not. Sample on change and every minute. */
		let battery: BatteryLike | null = null;
		let batteryTimer = 0;
		const sampleBattery = () => {
			if (battery && ref.current) diag.battery(ref.current, battery.level, battery.charging, Date.now());
		};
		const getBattery = (nav as Navigator & { getBattery?: () => Promise<BatteryLike> } | undefined)?.getBattery;
		if (getBattery) {
			getBattery.call(nav).then(
				(b) => {
					if (ref.current !== s) return;
					battery = b;
					sampleBattery();
					b.addEventListener?.("levelchange", sampleBattery);
					b.addEventListener?.("chargingchange", sampleBattery);
					batteryTimer = window.setInterval(sampleBattery, 60_000);
				},
				() => undefined,
			);
		}

		return () => {
			document.removeEventListener("visibilitychange", onVis);
			window.removeEventListener("pagehide", persist);
			window.clearInterval(saveTimer);
			window.clearInterval(batteryTimer);
			battery?.removeEventListener?.("levelchange", sampleBattery);
			battery?.removeEventListener?.("chargingchange", sampleBattery);
			sampleBattery();
			diag.endSession(s, Date.now());
			saveDiag(store, outingId, s);
			ref.current = null;
		};
	}, [on, outingId, persist]);

	useEffect(() => {
		if (ref.current) diag.setMode(ref.current, mode);
	}, [mode]);

	const toggle = useCallback((next: boolean) => {
		setFieldTestOn(store, next);
		setOn(next);
	}, []);

	/** The current summary — from the running recorder, or what this device kept for the outing. */
	const report = useCallback((): DiagReport | null => {
		const s = ref.current ?? loadDiag(store, outingId);
		return s ? buildReport(s, ref.current ? Date.now() : null) : null;
	}, [outingId]);

	const clear = useCallback(() => {
		clearDiag(store, outingId);
		if (ref.current) {
			const fresh = createDiagState(
				{ platform: ref.current.platform, browser: ref.current.browser, standalone: ref.current.standalone },
				modeRef.current,
			);
			const now = Date.now();
			diag.startSession(fresh, now, modeRef.current);
			/* Carry the link on as it is: a wipe is not a reconnect. */
			fresh.link = ref.current.link;
			fresh.everLive = ref.current.everLive;
			fresh.outageStart = ref.current.outageStart;
			fresh.visible = ref.current.visible;
			fresh.wake.supported = ref.current.wake.supported;
			ref.current = fresh;
			saveDiag(store, outingId, fresh);
		} else setHasData(false);
	}, [outingId]);

	const fieldDiag: FieldDiag = { on, ref };
	return { on, toggle, report, clear, hasData, fieldDiag };
}

/** Saves the report as a JSON file on this device. */
export function downloadReport(report: DiagReport, fileName: string): void {
	const blob = new Blob([JSON.stringify(report, null, 2)], { type: "application/json" });
	const url = URL.createObjectURL(blob);
	const a = document.createElement("a");
	a.href = url;
	a.download = fileName;
	document.body.appendChild(a);
	a.click();
	a.remove();
	window.setTimeout(() => URL.revokeObjectURL(url), 1_000);
}
