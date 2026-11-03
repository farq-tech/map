import { useCallback, useEffect, useRef, useState } from "react";
import { useLocation } from "../../contexts/LocationContext";
import { loadIdentity, OutingApiError, OutingsApi, type GpsState, type OutingSnapshot } from "../../lib/outings/api";
import { LiveChannel, type ClosedReason, type LiveState } from "../../lib/outings/live";
import { clearCachedView, loadCachedView, saveCachedView } from "../../lib/outings/lastKnown";
import { applyEvent, mergeSnapshot, type OutingView } from "../../lib/outings/outingState";
import { diag } from "../../lib/outings/fieldDiagnostics";
import type { FieldDiag } from "./useFieldDiagnostics";
import {
	FixFilter,
	heartbeatMs,
	LINK_HEARTBEAT_MS,
	shouldSend,
	WEAK_ACCURACY_M,
	type DeviceFix,
	type ShareMode,
} from "../../lib/outings/policy";

/**
 * Everything live about one outing while its screen is mounted:
 * the server picture, the socket, and — only while the outing is active, my
 * sharing is on, the page is visible and the fix is real GPS — sending my fix.
 * Unmounting stops all of it: no fix leaves this device off this screen.
 */
export function useLiveOuting(outingId: string, mode: ShareMode, fieldDiag?: FieldDiag) {
	const {
		userLocation,
		userAccuracy,
		userHeading,
		userSpeed,
		userFixAt,
		locationPinKind,
		hasLocationPermission,
		locationError,
		requestLocation,
	} = useLocation();
	/* The last known picture survives a reload on a dead network: shown with its age, never as live. */
	const [view, setView] = useState<OutingView | null>(() => loadCachedView(outingId));
	const [liveState, setLiveState] = useState<LiveState>("connecting");
	const [closed, setClosed] = useState<ClosedReason | null>(null);
	const [loadError, setLoadError] = useState<string | null>(null);
	const [visible, setVisible] = useState(() => typeof document === "undefined" || document.visibilityState !== "hidden");
	const [lastRefusal, setLastRefusal] = useState<string | null>(null);
	const [held, setHeld] = useState(false);
	const channelRef = useRef<LiveChannel | null>(null);
	const lastSentRef = useRef<{ fix: DeviceFix; sentAt: number } | null>(null);
	const filterRef = useRef(new FixFilter());
	/* Field-test recorder (opt-in); a ref so the channel handlers always see the current one. */
	const diagRef = fieldDiag?.ref;
	const diagOn = fieldDiag?.on ?? false;
	const lastSeenFixAtRef = useRef<number | null>(null);

	const onSnapshot = useCallback((s: OutingSnapshot) => setView((prev) => mergeSnapshot(prev, s)), []);

	const reload = useCallback(async () => {
		try {
			onSnapshot(await OutingsApi.get(outingId));
			setLoadError(null);
		} catch (e) {
			setLoadError(e instanceof OutingApiError ? e.code : "network");
		}
	}, [onSnapshot, outingId]);

	useEffect(() => {
		const id = loadIdentity();
		if (!id) {
			setLoadError("unauthorized");
			return;
		}
		void reload();
		const ch = new LiveChannel(outingId, id.token, {
			onSnapshot,
			onEvent: (e) => {
				setView((prev) => (prev ? applyEvent(prev, e) : prev));
				/* A new role changes what the server shows me (the invite state): fetch it. */
				if ((e.type === "member_role" && e.user_id === id.user.id) || e.type === "owner_changed") void reload();
			},
			onState: setLiveState,
			onClosed: (r) => {
				setClosed(r);
				channelRef.current = null;
			},
			onAck: (ok, reason) => setLastRefusal(ok ? null : reason || "refused"),
			onDiag: (e) => {
				const s = diagRef?.current;
				if (!s) return;
				const now = Date.now();
				if (e.kind === "send") diag.sendAttempt(s, e.transport, now);
				else if (e.kind === "ack") diag.ack(s, e.ok, e.reason, e.latencyMs, now);
				else diag.fixRejected(s, e.reason);
			},
		});
		channelRef.current = ch;
		ch.start();
		requestLocation();
		return () => {
			ch.stop();
			channelRef.current = null;
			lastSentRef.current = null;
			filterRef.current.reset();
		};
		// requestLocation is stable; one channel per outing screen.
		// eslint-disable-next-line react-hooks/exhaustive-deps
	}, [outingId, onSnapshot, reload]);

	/* Keep (or wipe) the on-device copy of the last known picture. */
	useEffect(() => {
		if (closed || view?.snapshot.outing.status === "ended") {
			clearCachedView(outingId);
			return;
		}
		if (view) saveCachedView(outingId, view);
	}, [view, closed, outingId]);

	/* Background / foreground. Hidden: stop sending and say so; visible: fresh fix, reconnect. */
	useEffect(() => {
		const onVis = () => {
			const v = document.visibilityState !== "hidden";
			setVisible(v);
			channelRef.current?.setAway(!v);
			if (v) {
				requestLocation();
				channelRef.current?.reconnectNow();
			}
		};
		document.addEventListener("visibilitychange", onVis);
		return () => document.removeEventListener("visibilitychange", onVis);
	}, [requestLocation]);

	/* Field test: time in each link state (the recorder may start after the channel). */
	useEffect(() => {
		const s = diagRef?.current;
		if (s) diag.link(s, liveState, Date.now());
	}, [liveState, diagOn, diagRef]);

	const status = view?.snapshot.outing.status;
	const sharing = view?.snapshot.me.sharing ?? false;
	const canSend = status === "active" && sharing && visible && !closed && locationPinKind === "gps";

	useEffect(() => {
		if (!canSend || !userLocation || userFixAt == null) return;
		const raw: DeviceFix = {
			lat: userLocation.lat,
			lng: userLocation.lng,
			accuracy: userAccuracy,
			heading: userHeading,
			speed: userSpeed,
			at: userFixAt,
		};
		/* The effect also reruns on a mode change: only a new device fix counts as "seen". */
		const ds = diagRef?.current ?? null;
		const isNewFix = lastSeenFixAtRef.current !== userFixAt;
		lastSeenFixAtRef.current = userFixAt;
		if (ds && isNewFix) diag.fixSeen(ds, userAccuracy, Date.now());
		const fix = filterRef.current.accept(raw);
		setHeld(!fix);
		if (ds && isNewFix) {
			const why = filterRef.current.lastReject;
			if (fix) diag.fixAccepted(ds);
			else if (why) diag.fixRejected(ds, why);
		}
		if (!fix) return; // glitch held back until the next fix agrees, or too inaccurate to send
		const now = Date.now();
		if (!shouldSend(fix, lastSentRef.current, mode, now)) return;
		lastSentRef.current = { fix, sentAt: now };
		if (ds) diag.fixSent(ds);
		channelRef.current?.sendFix(fix, mode);
	}, [canSend, userLocation, userAccuracy, userHeading, userSpeed, userFixAt, mode, diagRef]);

	/* Parked: a still phone may not fire the watch, so ask for a fresh real fix. Never re-send an old one. */
	useEffect(() => {
		if (!canSend) return;
		const t = window.setInterval(() => {
			const last = lastSentRef.current;
			if (last && Date.now() - last.sentAt >= heartbeatMs(mode)) requestLocation();
		}, 2_000);
		return () => window.clearInterval(t);
	}, [canSend, mode, requestLocation]);

	/* Connection heartbeat — no coordinates. Lets others tell "no GPS" from "no network". */
	const gpsState: GpsState =
		hasLocationPermission === false
			? "denied"
			: locationPinKind !== "gps" || !userFixAt || Date.now() - userFixAt > 45_000 || (locationError && !userLocation)
				? "unavailable"
				: (userAccuracy ?? 0) > WEAK_ACCURACY_M
					? "weak"
					: "ok";
	const gpsRef = useRef(gpsState);
	gpsRef.current = gpsState;
	useEffect(() => {
		if (!visible || closed) return;
		const beat = () => channelRef.current?.heartbeat(gpsRef.current);
		beat();
		const t = window.setInterval(beat, LINK_HEARTBEAT_MS);
		return () => window.clearInterval(t);
	}, [visible, closed, liveState]);

	useEffect(() => {
		if (!canSend) lastSentRef.current = null;
	}, [canSend]);

	return { view, setView, liveState, closed, loadError, visible, canSend, lastRefusal, held, gpsState, reload };
}
