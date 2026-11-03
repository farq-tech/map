/**
 * Keeps the screen on during an outing. Sharing runs only while the outing
 * screen is open, so a phone that dims and locks drops off the map; on by
 * default, the person can turn it off (saved per device).
 *
 * The browser releases a wake lock whenever the page is hidden (and may at any
 * other time, e.g. low battery), so the keeper re-acquires it when the page is
 * visible again — as long as it is still wanted.
 */

type Sentinel = { released?: boolean; release: () => Promise<void>; addEventListener?: (t: "release", fn: () => void) => void };
export type WakeNavigator = { wakeLock?: { request: (t: "screen") => Promise<Sentinel> } };
export type WakeDocument = {
	visibilityState: DocumentVisibilityState | string;
	addEventListener: (t: "visibilitychange", fn: () => void) => void;
	removeEventListener: (t: "visibilitychange", fn: () => void) => void;
};

/** Saved preference → on/off. Only an explicit "0" turns it off. */
export function wakePreference(saved: string | null): boolean {
	return saved !== "0";
}

export type WakeKeeper = {
	readonly supported: boolean;
	readonly held: boolean;
	/** Want the lock (outing active and sharing) or not. */
	set(wanted: boolean): void;
	dispose(): void;
};

export function createWakeKeeper(nav: WakeNavigator, doc: WakeDocument, onChange: (held: boolean) => void = () => undefined): WakeKeeper {
	const supported = Boolean(nav.wakeLock);
	let wanted = false;
	let sentinel: Sentinel | null = null;
	let pending = false;
	let held = false;

	const setHeld = (v: boolean) => {
		if (held === v) return;
		held = v;
		onChange(v);
	};

	function acquire() {
		if (!supported || !wanted || pending || sentinel || doc.visibilityState !== "visible") return;
		pending = true;
		nav.wakeLock!.request("screen").then(
			(s) => {
				pending = false;
				if (!wanted) {
					void s.release().catch(() => undefined);
					return;
				}
				sentinel = s;
				setHeld(true);
				s.addEventListener?.("release", () => {
					if (sentinel === s) sentinel = null;
					setHeld(false);
					/* Released by the system while still visible (battery saver…): try again. */
					if (wanted && doc.visibilityState === "visible") queueMicrotask(acquire);
				});
			},
			() => {
				pending = false;
				setHeld(false);
			},
		);
	}

	function release() {
		const s = sentinel;
		sentinel = null;
		setHeld(false);
		if (s) void s.release().catch(() => undefined);
	}

	const onVisibility = () => {
		if (doc.visibilityState === "visible") acquire();
		else {
			/* The browser drops it anyway; forget ours so we ask again on return. */
			sentinel = null;
			setHeld(false);
		}
	};
	doc.addEventListener("visibilitychange", onVisibility);

	return {
		supported,
		get held() {
			return held;
		},
		set(next: boolean) {
			wanted = next;
			if (next) acquire();
			else release();
		},
		dispose() {
			wanted = false;
			release();
			doc.removeEventListener("visibilitychange", onVisibility);
		},
	};
}
