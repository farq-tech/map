import { useNavigate } from "@tanstack/react-router";
import { ChevronLeft, ChevronRight, MessageCircle, Navigation, Phone } from "lucide-react";
import type { Map as MapboxMap } from "mapbox-gl";
import { lazy, Suspense, useEffect, useMemo, useRef, useState } from "react";
import { useLanguage } from "../../contexts/LanguageContext";
import { useLocation } from "../../contexts/LocationContext";
import { usePrefersReducedMotion } from "../../hooks/usePrefersReducedMotion";
import {
	inviteUrl,
	loadInviteToken,
	loadShareMode,
	loadWakeLock,
	OutingApiError,
	OutingsApi,
	outingErrorText,
	saveShareMode,
	saveWakeLock,
	type Member,
	type Position,
} from "../../lib/outings/api";
import { expiresIn } from "../../lib/outings/format";
import { lastSeenAgeMs, positionAgeMs } from "../../lib/outings/outingState";
import { ParticipantMarkers, type ParticipantView } from "../../lib/outings/participantMarkers";
import { memberColors } from "../../lib/outings/carColors";
import {
	accuracyGrade,
	bearingDeg,
	directionLabel,
	formatAgo,
	formatDistance,
	freshness,
	initials,
	trustedHeading,
	type Freshness,
	type ShareMode,
} from "../../lib/outings/policy";
import { directionsUrl, formatNumber, formatTime, haversineMeters } from "../../lib/sary/domain";
import { usePageMeta } from "../../lib/usePageMeta";
import { useSaryChrome } from "../../lib/sary/useSaryChrome";
import type { IntelligenceMapPlaces } from "../../services/intelligenceService";
import FarqBottomSheet, { sheetHeightPx, type SheetSnap } from "../intelligence/FarqBottomSheet";
import { liveStateLabel, statusLabel } from "./labels";
import { useLiveOuting } from "./useLiveOuting";
import "../../styles/sary-map.css";
import "../../styles/outings.css";

const FarqMap = lazy(() => import("../intelligence/FarqMap"));

export type OutingPanel = "members" | "invite" | "settings";

const EMPTY_PLACES = { type: "FeatureCollection", count: 0, matched: 0, layer: "outdoor", features: [] } as unknown as IntelligenceMapPlaces;

type Row = {
	member: Member;
	position: Position | null;
	ageMs: number | null;
	seenAgeMs: number | null;
	fresh: Freshness | null;
	distanceM: number | null;
	bearing: number | null;
};

export default function OutingLive({ outingId, initialPanel }: { outingId: string; initialPanel?: OutingPanel }) {
	const { language } = useLanguage();
	const isRTL = language === "ar";
	const navigate = useNavigate();
	const reducedMotion = usePrefersReducedMotion();
	const { userLocation, userHeading, userFixAt, userAccuracy, locationPinKind, locationError, hasLocationPermission, requestLocation } = useLocation();
	const [mode, setMode] = useState<ShareMode>(() => loadShareMode());
	const live = useLiveOuting(outingId, mode);
	const { view, liveState, closed, loadError, canSend, lastRefusal, visible, held, gpsState } = live;
	const [panel, setPanel] = useState<OutingPanel>(initialPanel || "members");
	const [snap, setSnap] = useState<SheetSnap>(initialPanel === "invite" ? "half" : "peek");
	const [selected, setSelected] = useState<string | null>(null);
	/* One in-app confirmation for every irreversible step (no browser dialogs). */
	const [confirm, setConfirm] = useState<{ kind: "end" | "leave" | "remove"; userId?: string; name?: string } | null>(null);
	const [toast, setToast] = useState<string | null>(null);
	const [busy, setBusy] = useState(false);
	const [actionError, setActionError] = useState<string | null>(null);
	const [now, setNow] = useState(() => Date.now());
	const [map, setMap] = useState<MapboxMap | null>(null);
	const [focus, setFocus] = useState<{ lat: number; lng: number; id: string; zoom?: number; kind?: "select" | "locate" | "bounds"; bounds?: [number, number, number, number] | null; topInset?: number; maxZoom?: number } | null>(null);
	const markersRef = useRef<ParticipantMarkers | null>(null);
	const fitWithRef = useRef<(id: string) => void>(() => undefined);
	const [composing, setComposing] = useState(false);
	const [noteDraft, setNoteDraft] = useState("");
	const [noteError, setNoteError] = useState<string | null>(null);
	const [noteAlert, setNoteAlert] = useState<{ userId: string; name: string; text: string; color: string } | null>(null);
	const [follow, setFollow] = useState(false);
	const fittedRef = useRef(false);

	useEffect(() => {
		if (!toast) return;
		const t = window.setTimeout(() => setToast(null), 2_000);
		return () => window.clearTimeout(t);
	}, [toast]);

	useEffect(() => {
		const t = window.setInterval(() => setNow(Date.now()), 5_000);
		return () => window.clearInterval(t);
	}, []);

	const me = view?.snapshot.me;
	const outing = view?.snapshot.outing;
	const isOwner = me?.role === "owner";

	useSaryChrome();
	usePageMeta({
		title: outing?.name
			? isRTL ? `${outing.name} — طلعة مشتركة · سَرى البارق` : `${outing.name} — Shared outing · Sary Albarq`
			: isRTL ? "طلعة مشتركة · سَرى البارق" : "Shared outing · Sary Albarq",
		path: `/outings/${outingId}`,
		robots: "noindex",
	});

	/* One colour per person, the same on every phone (join order). */
	const colors = useMemo(() => memberColors(view ? [...view.members.values()] : []), [view]);
	const myColor = me ? colors.get(me.user_id) : undefined;
	/* A note lives 15 minutes on the server; hide it here on the same clock. */
	const liveNote = (m: { note?: { text: string; at: string } | null } | undefined) =>
		m?.note && now - new Date(m.note.at).getTime() < NOTE_TTL_MS ? m.note.text : null;
	const myNote = me ? liveNote(view?.members.get(me.user_id)) : null;

	/* Someone put a line over their car: say it out loud on everyone else's screen. */
	const seenNotesRef = useRef<Map<string, string> | null>(null);
	useEffect(() => {
		if (!view) return;
		const first = seenNotesRef.current === null;
		const seen = seenNotesRef.current || new Map<string, string>();
		for (const m of view.members.values()) {
			const at = m.note?.at || "";
			if (seen.get(m.user_id) === at) continue;
			seen.set(m.user_id, at);
			if (first || !m.note || m.user_id === me?.user_id) continue;
			setNoteAlert({ userId: m.user_id, name: m.display_name, text: m.note.text, color: colors.get(m.user_id) || "#e8eef0" });
			try {
				navigator.vibrate?.([140, 70, 140]);
			} catch {
				/* */
			}
			if (typeof Notification !== "undefined" && Notification.permission === "granted" && document.visibilityState !== "visible") {
				try {
					new Notification(m.display_name, { body: m.note.text, tag: `sary-note-${m.user_id}` });
				} catch {
					/* */
				}
			}
		}
		seenNotesRef.current = seen;
	}, [view, me?.user_id, colors]);

	useEffect(() => {
		if (!noteAlert) return;
		const t = window.setTimeout(() => setNoteAlert(null), 7_000);
		return () => window.clearTimeout(t);
	}, [noteAlert]);

	const openComposer = () => {
		setNoteDraft("");
		setNoteError(null);
		setComposing(true);
		/* Ask once, from a tap, so a note can reach a phone whose screen is dimmed. */
		try {
			if (typeof Notification !== "undefined" && Notification.permission === "default") void Notification.requestPermission();
		} catch {
			/* */
		}
	};

	const sendNote = async (text: string) => {
		setNoteError(null);
		setBusy(true);
		try {
			await OutingsApi.note(outingId, text);
			setComposing(false);
			setToast(text ? (isRTL ? "وصلت رسالتك لأصحابك ✓" : "Sent to the group ✓") : isRTL ? "مُسحت الرسالة" : "Note cleared");
		} catch (e) {
			setNoteError(outingErrorText(e instanceof OutingApiError ? e.code : "network", isRTL));
		} finally {
			setBusy(false);
		}
	};

	const rows: Row[] = useMemo(() => {
		if (!view) return [];
		const out: Row[] = [];
		for (const m of view.members.values()) {
			if (m.user_id === me?.user_id) continue;
			const p = view.positions.get(m.user_id) || null;
			const ageMs = p ? positionAgeMs(view, p, now) : null;
			const seenAgeMs = lastSeenAgeMs(view, m, now);
			const here = locationPinKind === "gps" ? userLocation : null;
			out.push({
				member: m,
				position: p,
				ageMs,
				seenAgeMs,
				fresh: ageMs == null ? null : freshness({ fixAgeMs: ageMs, speedMps: p?.speed, lastSeenAgeMs: seenAgeMs }),
				distanceM: p && here ? haversineMeters(here, p) : null,
				bearing: p && here ? bearingDeg(here, p) : null,
			});
		}
		return out.sort((a, b) => (a.distanceM ?? Infinity) - (b.distanceM ?? Infinity));
	}, [view, me?.user_id, now, userLocation, locationPinKind]);

	/* Participant markers on the map. */
	useEffect(() => {
		if (!map) return;
		const layer = new ParticipantMarkers(map, (id) => {
			setSelected(id);
			fitWithRef.current(id);
			setPanel("members");
			setSnap("half");
		}, () => reducedMotion, isRTL);
		markersRef.current = layer;
		return () => {
			layer.destroy();
			markersRef.current = null;
		};
		// one layer per map instance
		// eslint-disable-next-line react-hooks/exhaustive-deps
	}, [map]);

	useEffect(() => {
		const layer = markersRef.current;
		if (!layer) return;
		const views: ParticipantView[] = rows
			.filter((r) => r.position)
			.map((r) => ({
				userId: r.member.user_id,
				name: r.member.display_name,
				avatar: r.member.avatar,
				lng: r.position!.lng,
				lat: r.position!.lat,
				at: new Date(r.position!.recorded_at).getTime(),
				heading: trustedHeading(r.position!.heading, r.position!.speed),
				accuracyM: r.position!.accuracy,
				freshness: r.fresh || "lost",
				approximate: accuracyGrade(r.position!.accuracy) === "poor",
				weak: accuracyGrade(r.position!.accuracy) !== "good",
				selected: r.member.user_id === selected,
				color: colors.get(r.member.user_id) || "#e8eef0",
				note: liveNote(r.member),
			}));
		layer.sync(views);
	}, [rows, selected, map, colors]);

	const groupBounds = (only?: string): [number, number, number, number] | null => {
		const pts: Array<{ lat: number; lng: number }> = rows.filter((r) => r.position && (!only || r.member.user_id === only)).map((r) => r.position!);
		if (locationPinKind === "gps" && userLocation) pts.push(userLocation);
		if (!pts.length) return null;
		let w = Infinity, s = Infinity, e = -Infinity, n = -Infinity;
		for (const p of pts) {
			w = Math.min(w, p.lng);
			e = Math.max(e, p.lng);
			s = Math.min(s, p.lat);
			n = Math.max(n, p.lat);
		}
		/* ~60 m around: enough to see the street, close enough that two cars side by side separate. */
		const pad = 0.0006;
		return [w - pad, s - pad, e + pad, n + pad];
	};

	/* "Keep everyone on screen": on by default, off once you move the map
	 * yourself, back on with «المجموعة». */
	const [keepGroup, setKeepGroup] = useState(true);
	const keepGroupRef = useRef(keepGroup);
	keepGroupRef.current = keepGroup;

	/* How far down the screen our own bars reach, plus room for a name and a note over a car. */
	const topInset = () => {
		let bottom = 0;
		for (const el of document.querySelectorAll(".sary-o-bar, .sary-o-share, .sary-o-warn")) bottom = Math.max(bottom, el.getBoundingClientRect().bottom);
		return Math.round(bottom + 70);
	};
	const frame = (b: [number, number, number, number], id: string) =>
		setFocus({ lat: (b[1] + b[3]) / 2, lng: (b[0] + b[2]) / 2, id, kind: "bounds", bounds: b, topInset: topInset(), maxZoom: 17.5 });

	const fitGroup = () => {
		const b = groupBounds();
		if (!b) return;
		setFollow(false);
		setKeepGroup(true);
		frame(b, `group-${Date.now()}`);
	};

	/* You and one friend, together on screen. */
	const fitWith = (userId: string) => {
		const b = groupBounds(userId);
		if (!b) return;
		setFollow(false);
		setKeepGroup(false);
		frame(b, `pair-${userId}-${Date.now()}`);
	};

	fitWithRef.current = fitWith;

	/* A finger on the map means "let me look": stop reframing until asked. */
	useEffect(() => {
		if (!map) return;
		const stop = (e: unknown) => {
			if ((e as { originalEvent?: unknown }).originalEvent) setKeepGroup(false);
		};
		map.on("dragstart", stop);
		map.on("zoomstart", stop);
		map.on("rotatestart", stop);
		return () => {
			map.off("dragstart", stop);
			map.off("zoomstart", stop);
			map.off("rotatestart", stop);
		};
	}, [map]);

	/* While keeping the group: if anyone (you included) drifts off screen, reframe. */
	useEffect(() => {
		if (!map || !keepGroup || follow || !fittedRef.current) return;
		const pts: Array<{ lat: number; lng: number }> = rows.filter((r) => r.position).map((r) => r.position!);
		if (locationPinKind === "gps" && userLocation) pts.push(userLocation);
		if (pts.length < 2) return;
		const view = map.getBounds();
		if (!view) return;
		/* Inset the view a little so a car at the very edge counts as off screen. */
		const w = view.getWest(), e = view.getEast(), s = view.getSouth(), n = view.getNorth();
		const dx = (e - w) * 0.08, dy = (n - s) * 0.12;
		const out = pts.some((p) => p.lng < w + dx || p.lng > e - dx || p.lat < s + dy || p.lat > n - dy);
		if (out) fitGroup();
		// eslint-disable-next-line react-hooks/exhaustive-deps
	}, [rows, userLocation, keepGroup, follow, map]);

	const locateMe = () => {
		requestLocation();
		setKeepGroup(false);
		if (userLocation) {
			setFollow(true);
			setFocus({ lat: userLocation.lat, lng: userLocation.lng, id: `me-${Date.now()}`, kind: "locate", zoom: 14.5 });
		}
	};

	/* Frame the whole group when positions first arrive, and again each time
	 * someone new appears, so nobody is left off-screen. */
	const placedRef = useRef<Set<string>>(new Set());
	useEffect(() => {
		if (!map) return;
		const placed = rows.filter((r) => r.position).map((r) => r.member.user_id);
		const newcomer = placed.some((id) => !placedRef.current.has(id));
		placed.forEach((id) => placedRef.current.add(id));
		if (newcomer && fittedRef.current && !follow) fitGroup();
	}, [rows, map]);

	useEffect(() => {
		if (fittedRef.current || !map) return;
		if (rows.some((r) => r.position)) {
			fittedRef.current = true;
			fitGroup();
		} else if (userLocation && locationPinKind === "gps") {
			fittedRef.current = true;
			setFocus({ lat: userLocation.lat, lng: userLocation.lng, id: "me-first", kind: "locate", zoom: 13.5 });
		}
		// eslint-disable-next-line react-hooks/exhaustive-deps
	}, [rows, map, userLocation]);

	/* Optional: keep the screen on, since sharing stops when the phone sleeps. */
	const [wake, setWake] = useState(() => loadWakeLock());
	useEffect(() => {
		const nav = navigator as Navigator & { wakeLock?: { request: (t: "screen") => Promise<{ release: () => Promise<void> }> } };
		if (!wake || !canSend || !visible || !nav.wakeLock) return;
		let sentinel: { release: () => Promise<void> } | null = null;
		let cancelled = false;
		nav.wakeLock.request("screen").then(
			(s) => {
				if (cancelled) void s.release();
				else sentinel = s;
			},
			() => undefined,
		);
		return () => {
			cancelled = true;
			void sentinel?.release();
		};
	}, [wake, canSend, visible]);

	const run = async (fn: () => Promise<unknown>) => {
		setBusy(true);
		setActionError(null);
		try {
			await fn();
			await live.reload();
		} catch (e) {
			setActionError(outingErrorText(e instanceof OutingApiError ? e.code : "network", isRTL));
		} finally {
			setBusy(false);
		}
	};

	/* --- terminal and error states --- */
	const terminal = closed || (outing?.status === "ended" ? "outing_ended" : null) || (loadError === "not_a_member" ? "not_a_member" : null);
	if (terminal || (loadError && !view)) {
		const text =
			terminal === "outing_ended"
				? isRTL ? "انتهت الطلعة. توقفت مشاركة المواقع وحُذفت." : "The outing ended. Location sharing stopped and positions were deleted."
				: terminal === "removed"
					? isRTL ? "أزالك صاحب الطلعة. توقفت مشاركة موقعك." : "You were removed. Your location is no longer shared."
					: terminal === "left"
						? isRTL ? "غادرت الطلعة." : "You left the outing."
						: terminal === "replaced"
							? isRTL ? "الطلعة مفتوحة في نافذة أخرى على هذا الجهاز." : "This outing is open in another window."
							: outingErrorText(terminal || loadError || "network", isRTL);
		return (
			<main className="sary-o-page" dir={isRTL ? "rtl" : "ltr"} data-testid="outing-closed">
				<section className="sary-o-card" role="status">
					<h2>{outing?.name || (isRTL ? "طلعة مشتركة" : "Shared outing")}</h2>
					<p data-testid="outing-closed-reason">{text}</p>
					{loadError && !terminal ? (
						<button type="button" className="sary-o-primary" onClick={() => void live.reload()}>
							{isRTL ? "إعادة المحاولة" : "Retry"}
						</button>
					) : null}
					<button type="button" className="sary-o-secondary" onClick={() => void navigate({ to: "/outings" })}>
						{isRTL ? "طلعاتي" : "My outings"}
					</button>
				</section>
			</main>
		);
	}

	const selectedRow = rows.find((r) => r.member.user_id === selected) || null;
	void userFixAt;
	void locationError;
	const gpsProblem =
		hasLocationPermission === false || gpsState === "denied"
			? isRTL ? "الموقع غير مسموح — أصحابك لا يرون موقعك. فعّله من إعدادات المتصفح." : "Location is denied — friends cannot see you. Allow it in browser settings."
			: canSend && gpsState === "unavailable"
				? isRTL ? "لا توجد قراءة GPS حديثة — أصحابك يرون آخر موقع معروف لك مع وقته." : "No recent GPS fix — friends see your last known position with its time."
				: canSend && held
					? isRTL ? "قراءة GPS غير منطقية أو ضعيفة — لم نرسلها، بانتظار قراءة تؤكدها." : "GPS reading looked wrong or weak — held back until the next one confirms it."
					: null;

	const sharingLine = (() => {
		if (!outing || !me) return "";
		if (outing.status === "created") return isRTL ? "لم تبدأ الطلعة — لا تُرسَل المواقع بعد" : "Not started — no positions are shared yet";
		if (outing.status === "paused") return isRTL ? "الطلعة متوقفة مؤقتًا — المشاركة متوقفة للجميع" : "Paused — sharing is off for everyone";
		if (!me.sharing) return isRTL ? "أوقفت مشاركة موقعك" : "You paused sharing";
		if (!visible) return isRTL ? "التطبيق في الخلفية — لا يُرسَل موقعك" : "In background — not sending";
		if (canSend) return isRTL ? "موقعك مُشارَك الآن مع أعضاء الطلعة" : "Your location is being shared with members";
		return isRTL ? "بانتظار موقعك…" : "Waiting for your location…";
	})();

	const liveCount = rows.filter((r) => r.fresh === "live").length;
	const header = (
		<span data-testid="outing-summary">
			{isRTL
				? `${formatNumber(rows.length + 1, true)} مشارك · ${formatNumber(liveCount, true)} مباشر`
				: `${rows.length + 1} members · ${liveCount} live`}
			{rows[0]?.distanceM != null ? ` · ${isRTL ? "الأقرب" : "nearest"} ${formatDistance(rows[0].distanceM, isRTL)}` : ""}
		</span>
	);

	const inviteToken = loadInviteToken(outingId);
	const invite = view?.snapshot.invite;

	return (
		<div className="sary-o-live" dir={isRTL ? "rtl" : "ltr"} data-testid="outing-live" data-snap={snap}>
			<div className="sary-o-map">
				<Suspense fallback={<div className="sary-map-fallback" />}>
					<FarqMap
						mode="outdoor"
						basemap="satellite"
						places={EMPTY_PLACES}
						neighborhoods={null}
						onSelectPlace={() => undefined}
						onSelectNeighborhood={() => undefined}
						userLocation={locationPinKind === "gps" ? userLocation : null}
						userHeading={userHeading}
						userAccuracy={userAccuracy}
						showUserLocation={locationPinKind === "gps" && Boolean(userLocation)}
						followMode={follow}
						vehicleMode={canSend ? "prado" : "dot"}
						vehicleHex={myColor}
						vehicleLabel={isRTL ? "أنت" : "You"}
						vehicleNote={myNote}
						onVehicleTap={openComposer}
						onBreakFollow={() => setFollow(false)}
						isRTL={isRTL}
						hideAddressSearch
						sheetOpen={snap !== "peek"}
						bottomInset={sheetHeightPx(snap, typeof window === "undefined" ? 800 : window.innerHeight)}
						focusRequest={focus}
						onMapReady={setMap}
					/>
				</Suspense>
			</div>

			<header className="sary-o-bar">
				<button type="button" className="sary-o-round" onClick={() => void navigate({ to: "/outings" })} aria-label={isRTL ? "رجوع" : "Back"}>
					{isRTL ? <ChevronRight className="size-5" aria-hidden /> : <ChevronLeft className="size-5" aria-hidden />}
				</button>
				<div className="sary-o-title">
					<strong data-testid="outing-title">{outing?.name || "…"}</strong>
					<span>
						{outing ? statusLabel(outing.status, isRTL) : ""} · <span data-testid="outing-link-state" data-state={liveState}>{liveStateLabel(liveState, isRTL)}</span>
					</span>
				</div>
			</header>

			<div className={`sary-o-share${canSend ? " is-on" : ""}`} role="status" data-testid="outing-sharing-indicator" data-on={canSend ? "1" : "0"}>
				<span className="sary-o-dot" aria-hidden="true" />
				{sharingLine}
			</div>
			{gpsProblem ? (
				<div className="sary-o-warn" role="alert" data-testid="outing-gps-warning">
					{gpsProblem}{" "}
					<button type="button" onClick={requestLocation}>{isRTL ? "تفعيل" : "Enable"}</button>
				</div>
			) : liveState === "offline" ? (
				<div className="sary-o-warn" role="alert">{isRTL ? "لا يوجد إنترنت — نعرض آخر المواقع المعروفة مع وقتها." : "Offline — showing last known positions with their time."}</div>
			) : null}

			<div className="sary-o-fabs">
				<button type="button" className="sary-fab" onClick={locateMe} data-testid="outing-locate">{isRTL ? "موقعي" : "Me"}</button>
				<button type="button" className="sary-fab" onClick={fitGroup} data-testid="outing-fit">{isRTL ? "المجموعة" : "Group"}</button>
				{outing?.status === "active" || outing?.status === "paused" ? (
					<button type="button" className="sary-fab" onClick={openComposer} data-testid="outing-note-open">
						{isRTL ? "رسالة" : "Message"}
					</button>
				) : null}
			</div>

			<FarqBottomSheet
				snap={snap}
				onSnap={setSnap}
				isRTL={isRTL}
				testId="outing-sheet"
				header={header}
				rail={
					<>
					{isOwner && outing?.status === "created" ? (
						<div className="sary-o-stage" data-testid="outing-stage">
							<p>{isRTL ? "شارك الرابط مع أصحابك ثم ابدأ" : "Share the link with your friends, then start"}</p>
							<button type="button" className="sary-o-primary" disabled={busy} onClick={() => void run(() => OutingsApi.setStatus(outingId, "start"))} data-testid="outing-start">
								{isRTL ? "ابدأ الطلعة" : "Start the outing"}
							</button>
						</div>
					) : !isOwner && outing?.status === "created" ? (
						<p className="sary-o-stage-line" data-testid="outing-stage">{isRTL ? "بانتظار صاحب الطلعة ليبدأ" : "Waiting for the owner to start"}</p>
					) : outing?.status === "paused" ? (
						<p className="sary-o-stage-line" data-testid="outing-stage">
							{isOwner ? (isRTL ? "أوقفت الطلعة مؤقتًا — المشاركة متوقفة للجميع" : "You paused the outing — sharing is off for everyone") : isRTL ? "صاحب الطلعة أوقفها مؤقتًا" : "The owner paused the outing"}
						</p>
					) : null}
					<div className="sary-o-tabs" role="tablist">
						{(["members", ...(isOwner ? ["invite"] : []), "settings"] as OutingPanel[]).map((p) => (
							<button
								key={p}
								type="button"
								role="tab"
								aria-selected={panel === p}
								className={`sary-layer-chip${panel === p ? " is-on" : ""}`}
								onClick={() => {
									setPanel(p);
									if (snap === "peek") setSnap("half");
								}}
								data-testid={`outing-tab-${p}`}
							>
								{p === "members" ? (isRTL ? "المشاركون" : "Members") : p === "invite" ? (isRTL ? "الدعوة" : "Invite") : isRTL ? "الإعدادات" : "Settings"}
							</button>
						))}
					</div>
					</>
				}
			>
				{actionError ? <p className="sary-o-error" role="alert">{actionError}</p> : null}
				{lastRefusal === "outing_paused" || lastRefusal === "outing_created" ? null : lastRefusal ? (
					<p className="sary-o-note">{isRTL ? "لم يُقبل آخر موقع (إشارة ضعيفة أو قديمة)." : "Last fix was not accepted (weak or stale)."}</p>
				) : null}

				{panel === "members" ? (
					selectedRow ? (
						<MemberCard
							row={selectedRow}
							isRTL={isRTL}
							isOwner={isOwner}
							busy={busy}
							onBack={() => setSelected(null)}
							onFocus={() => fitWith(selectedRow.member.user_id)}
							onRemove={() => setConfirm({ kind: "remove", userId: selectedRow.member.user_id, name: selectedRow.member.display_name })}
						/>
					) : (
						<ul className="sary-o-members" data-testid="outing-members">
							<li className="sary-o-member is-me">
								<Face name={me ? view?.members.get(me.user_id)?.display_name || "" : ""} avatar={me ? view?.members.get(me.user_id)?.avatar || null : null} color={myColor} />
								<div>
									<strong>{isRTL ? "أنت" : "You"}{isOwner ? (isRTL ? " · صاحب الطلعة" : " · owner") : ""}</strong>
									<span>{sharingLine}</span>
								</div>
							</li>
							<li>
								<MyPhone current={me ? view?.members.get(me.user_id)?.phone || null : null} isRTL={isRTL} onSaved={(t) => setToast(t)} />
							</li>
							{rows.map((r) => (
								<li key={r.member.user_id}>
									<button type="button" className="sary-o-member" onClick={() => setSelected(r.member.user_id)} data-testid="outing-member" data-user={r.member.user_id} data-fresh={r.fresh || "none"}>
										<Face name={r.member.display_name} avatar={r.member.avatar} fresh={r.fresh} color={colors.get(r.member.user_id)} />
										<div>
											<strong>
												{r.member.display_name}
												{r.member.role === "owner" ? (isRTL ? " · صاحب الطلعة" : " · owner") : ""}
											</strong>
											<span>{memberLine(r, isRTL)}</span>
										</div>
										<StatusPill row={r} isRTL={isRTL} />
										{r.distanceM != null && r.bearing != null ? (
											<span className="sary-o-dist" data-testid="outing-member-distance">
												<span className="sary-o-compass" style={{ transform: `rotate(${r.bearing}deg)` }} aria-hidden="true">↑</span>
												{formatDistance(r.distanceM, isRTL)}
												<small>{directionLabel(r.bearing, isRTL)}</small>
											</span>
										) : null}
									</button>
								</li>
							))}
							{!rows.length ? (
								<li className="sary-o-note">{isRTL ? "لا أحد بعد — أرسل رابط الدعوة لأصحابك." : "Nobody yet — send the invite link."}</li>
							) : null}
						</ul>
					)
				) : null}

				{panel === "invite" && isOwner ? (
					<div className="sary-o-panel" data-testid="outing-invite-panel">
						{inviteToken && invite?.active ? (
							<>
								<p className="sary-o-note">
									{isRTL ? "أي شخص معه هذا الرابط يستطيع الانضمام" : "Anyone with this link can join"}
									{invite.expires_at ? ` · ${expiresIn(invite.expires_at, isRTL, now)}` : ""}
								</p>
								<input className="sary-o-link" readOnly value={inviteUrl(inviteToken)} onFocus={(e) => e.currentTarget.select()} data-testid="outing-invite-link" dir="ltr" />
								<div className="sary-o-row">
									<button
										type="button"
										className="sary-o-primary"
										onClick={async () => {
											const url = inviteUrl(inviteToken);
											const text = isRTL ? `انضم لطلعتي «${outing?.name}» على سَرى البارق` : `Join my outing “${outing?.name}” on Sary Albarq`;
											const nav = navigator as Navigator & { share?: (d: ShareData) => Promise<void> };
											if (nav.share) {
												try {
													await nav.share({ title: outing?.name, text, url });
													return;
												} catch {
													/* cancelled — fall through to copy */
												}
											}
											const ok = await navigator.clipboard?.writeText(url).then(() => true, () => false);
											setActionError(null);
											setToast(ok ? (isRTL ? "تم نسخ الرابط ✓" : "Link copied ✓") : isRTL ? "انسخ الرابط من الحقل أعلاه" : "Copy the link from the field above");
										}}
										data-testid="outing-invite-share"
									>
										{isRTL ? "مشاركة الرابط" : "Share link"}
									</button>
									<button
										type="button"
										className="sary-o-secondary"
										onClick={() =>
											void navigator.clipboard?.writeText(inviteUrl(inviteToken)).then(
												() => setToast(isRTL ? "تم نسخ الرابط ✓" : "Link copied ✓"),
												() => setToast(isRTL ? "انسخ الرابط من الحقل أعلاه" : "Copy the link from the field above"),
											)
										}
										data-testid="outing-invite-copy"
									>
										{isRTL ? "نسخ" : "Copy"}
									</button>
								</div>
								<div className="sary-o-row">
									<button type="button" className="sary-o-secondary" disabled={busy} onClick={() => void run(() => OutingsApi.rotateInvite(outingId))}>
										{isRTL ? "رابط جديد (يلغي القديم)" : "New link (cancels old)"}
									</button>
									<button type="button" className="sary-o-danger" disabled={busy} onClick={() => void run(() => OutingsApi.revokeInvites(outingId))} data-testid="outing-invite-revoke">
										{isRTL ? "إلغاء الدعوة" : "Cancel invite"}
									</button>
								</div>
							</>
						) : (
							<>
								<p className="sary-o-note">
									{invite?.active
										? isRTL ? "الرابط الحالي محفوظ على جهاز آخر. أنشئ رابطًا جديدًا (يُلغى القديم)." : "The current link is on another device. Create a new one (the old one stops working)."
										: isRTL ? "لا يوجد رابط دعوة فعّال." : "No active invite link."}
								</p>
								<button type="button" className="sary-o-primary" disabled={busy || outing?.status === "ended"} onClick={() => void run(() => OutingsApi.rotateInvite(outingId))} data-testid="outing-invite-create">
									{isRTL ? "إنشاء رابط دعوة" : "Create invite link"}
								</button>
							</>
						)}
					</div>
				) : null}

				{panel === "settings" ? (
					<div className="sary-o-panel" data-testid="outing-settings">
						<label className="sary-o-switch">
							<input
								type="checkbox"
								checked={Boolean(me?.sharing)}
								disabled={busy}
								onChange={(e) => {
									const on = e.target.checked;
									void run(() => OutingsApi.setSharing(outingId, on));
								}}
								data-testid="outing-sharing-toggle"
							/>
							<span>{isRTL ? "مشاركة موقعي" : "Share my location"}</span>
						</label>
						<p className="sary-o-note">
							{isRTL ? "عند الإيقاف يُحذف موقعك من الخادم فورًا ولا يراه أحد." : "Turning it off deletes your position from the server at once."}
						</p>
						<div className="sary-o-modes" role="radiogroup" aria-label={isRTL ? "سرعة التحديث" : "Update rate"} data-testid="outing-rate">
							<span className="sary-o-modes-label">{isRTL ? "سرعة التحديث" : "Update rate"}</span>
							<div className="sary-o-seg">
								{(["saver", "balanced", "precise"] as ShareMode[]).map((m) => (
									<button
										key={m}
										type="button"
										role="radio"
										aria-checked={mode === m}
										className={mode === m ? "is-on" : undefined}
										onClick={() => {
											setMode(m);
											saveShareMode(m);
										}}
										data-testid={`outing-rate-${m}`}
									>
										{m === "saver" ? (isRTL ? "موفّر" : "Saver") : m === "balanced" ? (isRTL ? "متوازن" : "Balanced") : isRTL ? "دقيق" : "Precise"}
									</button>
								))}
							</div>
							<p className="sary-o-note">
								{mode === "saver"
									? isRTL ? "نصف المعدل — للطلعات الطويلة وتوفير البطارية والبيانات." : "Half the rate — for long trips, saves battery and data."
									: mode === "balanced"
										? isRTL ? "حسب سرعتك: كل ٢٫٥ ث فوق ٩٠ كم/س، ٤ ث على الطريق، ٦ ث في الرمل، ٣٠ ث وأنت واقف." : "By speed: 2.5 s above 90 km/h, 4 s on road, 6 s on sand, 30 s parked."
										: isRTL ? "أسرع من المتوازن — دقة أعلى واستهلاك أكثر للبطارية والبيانات." : "Faster than balanced — more precise, more battery and data."}
							</p>
						</div>
						<label className="sary-o-switch">
							<input
								type="checkbox"
								checked={wake}
								onChange={(e) => {
									setWake(e.target.checked);
									saveWakeLock(e.target.checked);
								}}
							/>
							<span>{isRTL ? "إبقاء الشاشة مضاءة أثناء المشاركة" : "Keep the screen on while sharing"}</span>
						</label>
						<p className="sary-o-note">
							{isRTL
								? "المشاركة تعمل والتطبيق مفتوح على هذه الشاشة فقط؛ إذا أُغلقت الشاشة أو خرجت منها يتوقف الإرسال."
								: "Sharing runs only while this screen is open; locking the phone or leaving stops it."}
						</p>

						{isOwner ? (
							<div className="sary-o-row">
								{outing?.status === "active" ? (
									<button type="button" className="sary-o-secondary" disabled={busy} onClick={() => void run(() => OutingsApi.setStatus(outingId, "pause"))} data-testid="outing-pause">
										{isRTL ? "إيقاف مؤقت للطلعة" : "Pause outing"}
									</button>
								) : null}
								{outing?.status === "paused" ? (
									<button type="button" className="sary-o-primary" disabled={busy} onClick={() => void run(() => OutingsApi.setStatus(outingId, "resume"))} data-testid="outing-resume">
										{isRTL ? "استئناف الطلعة" : "Resume outing"}
									</button>
								) : null}
								<button type="button" className="sary-o-danger" disabled={busy} onClick={() => setConfirm({ kind: "end" })} data-testid="outing-end">
									{isRTL ? "إنهاء الطلعة" : "End outing"}
								</button>
							</div>
						) : null}
						<button
							type="button"
							className="sary-o-danger"
							disabled={busy}
							onClick={() => setConfirm({ kind: "leave" })}
							data-testid="outing-leave"
						>
							{isRTL ? "مغادرة الطلعة" : "Leave outing"}
						</button>
					</div>
				) : null}
			</FarqBottomSheet>

			{confirm ? (
				<div
					className="sary-o-modal"
					role="dialog"
					aria-modal="true"
					aria-labelledby="outing-confirm-title"
					data-testid={confirm.kind === "end" ? "outing-end-confirm" : `outing-${confirm.kind}-confirm`}
				>
					<div className="sary-o-card">
						<h2 id="outing-confirm-title">
							{confirm.kind === "end"
								? isRTL ? "إنهاء الطلعة؟" : "End the outing?"
								: confirm.kind === "leave"
									? isRTL ? "مغادرة الطلعة؟" : "Leave the outing?"
									: isRTL ? `إزالة ${confirm.name}؟` : `Remove ${confirm.name}?`}
						</h2>
						<p>
							{confirm.kind === "end"
								? isRTL
									? "تتوقف مشاركة المواقع لجميع المشاركين فورًا، وتُحذف كل المواقع المحفوظة، ويُلغى رابط الدعوة. لا يمكن التراجع."
									: "Sharing stops for everyone, all stored positions are deleted and the invite is cancelled. This cannot be undone."
								: confirm.kind === "leave"
									? isOwner
										? isRTL ? "تتوقف مشاركة موقعك فورًا، وتنتقل إدارة الطلعة لأقدم مشارك." : "Your sharing stops at once and ownership passes to the earliest member."
										: isRTL ? "تتوقف مشاركة موقعك فورًا ولا ترى مواقع المجموعة." : "Your sharing stops at once and you no longer see the group."
									: isRTL ? "يُحذف موقعه فورًا ولا يستطيع العودة لهذه الطلعة." : "Their position is deleted at once and they cannot rejoin this outing."}
						</p>
						<div className="sary-o-row">
							<button
								type="button"
								className="sary-o-danger"
								disabled={busy}
								onClick={() => {
									const c = confirm;
									setConfirm(null);
									if (c.kind === "end") void run(() => OutingsApi.setStatus(outingId, "end"));
									else if (c.kind === "leave")
										void run(async () => {
											await OutingsApi.leave(outingId);
											void navigate({ to: "/outings" });
										});
									else if (c.userId) {
										setSelected(null);
										void run(() => OutingsApi.removeMember(outingId, c.userId!));
									}
								}}
								data-testid={confirm.kind === "end" ? "outing-end-yes" : `outing-${confirm.kind}-yes`}
							>
								{confirm.kind === "end" ? (isRTL ? "إنهاء للجميع" : "End for everyone") : confirm.kind === "leave" ? (isRTL ? "مغادرة" : "Leave") : isRTL ? "إزالة" : "Remove"}
							</button>
							<button type="button" className="sary-o-secondary" onClick={() => setConfirm(null)}>
								{isRTL ? "تراجع" : "Cancel"}
							</button>
						</div>
					</div>
				</div>
			) : null}

			{composing ? (
				<div className="sary-o-modal" role="dialog" aria-modal="true" aria-labelledby="outing-note-title" data-testid="outing-note">
					<form
						className="sary-o-card"
						onSubmit={(e) => {
							e.preventDefault();
							if (noteDraft.trim()) void sendNote(noteDraft.trim());
						}}
					>
						<h2 id="outing-note-title">{isRTL ? "رسالة فوق سيارتك" : "A line over your car"}</h2>
						<p className="sary-o-note">
							{isRTL ? "تظهر فوق سيارتك على خريطة الجميع، ويجيهم تنبيه. تختفي بعد ١٥ دقيقة." : "Shows over your car on everyone's map, with an alert. Gone after 15 minutes."}
						</p>
						<div className="sary-o-presets">
							{(isRTL ? NOTE_PRESETS_AR : NOTE_PRESETS_EN).map((p) => (
								<button key={p} type="button" className="sary-o-preset" disabled={busy} onClick={() => void sendNote(p)} data-testid="outing-note-preset">
									{p}
								</button>
							))}
						</div>
						<label className="sary-o-form">
							<span>{isRTL ? "أو اكتب عبارتك" : "Or write your own"}</span>
							<input
								value={noteDraft}
								onChange={(e) => setNoteDraft(e.target.value)}
								maxLength={80}
								enterKeyHint="send"
								placeholder={isRTL ? "مثال: بوقف عند المحطة" : "e.g. Stopping for fuel"}
								data-testid="outing-note-input"
								autoFocus
							/>
						</label>
						{noteError ? <p className="sary-o-error" role="alert">{noteError}</p> : null}
						<div className="sary-o-row">
							<button type="submit" className="sary-o-primary" disabled={busy || !noteDraft.trim()} data-testid="outing-note-send">
								{isRTL ? "أرسل" : "Send"}
							</button>
							{myNote ? (
								<button type="button" className="sary-o-secondary" disabled={busy} onClick={() => void sendNote("")} data-testid="outing-note-clear">
									{isRTL ? "امسح رسالتي" : "Clear my note"}
								</button>
							) : null}
							<button type="button" className="sary-o-secondary" onClick={() => setComposing(false)}>
								{isRTL ? "إلغاء" : "Cancel"}
							</button>
						</div>
					</form>
				</div>
			) : null}

			{noteAlert ? (
				<button
					type="button"
					className="sary-o-alert"
					role="alert"
					style={{ "--car": noteAlert.color } as React.CSSProperties}
					onClick={() => {
						setSelected(noteAlert.userId);
						setPanel("members");
						setSnap("half");
						setNoteAlert(null);
					}}
					data-testid="outing-note-alert"
				>
					<i aria-hidden="true" />
					<strong>{noteAlert.name}</strong>
					<span>{noteAlert.text}</span>
				</button>
			) : null}

			{toast ? (
				<div className="sary-o-toast" role="status" data-testid="outing-toast">
					{toast}
				</div>
			) : null}
		</div>
	);
}

const NOTE_TTL_MS = 15 * 60_000;
const NOTE_PRESETS_AR = ["بوقف عند المحطة ⛽", "انتظروني", "وقفت، تعالوا", "عندي عطل", "تمام، ماشي"];
const NOTE_PRESETS_EN = ["Stopping for fuel ⛽", "Wait for me", "Stopped — come over", "Car trouble", "All good, moving"];

function memberLine(r: Row, isRTL: boolean): string {
	const m = r.member;
	if (!m.sharing) return isRTL ? "أوقف مشاركة موقعه" : "Paused sharing";
	const gpsNote =
		m.gps === "unavailable" ? (isRTL ? " · تعذّر تحديد موقعه" : " · cannot get a GPS fix") : m.gps === "denied" ? (isRTL ? " · الموقع غير مسموح عنده" : " · location denied") : "";
	if (!r.position || r.ageMs == null) {
		if (r.seenAgeMs != null && r.seenAgeMs <= 60_000) return (isRTL ? "متصل · بانتظار موقعه" : "Connected · waiting for position") + gpsNote;
		return isRTL ? "غير متصل — لا يوجد موقع" : "Not connected — no position";
	}
	const ago = formatAgo(r.ageMs, isRTL);
	const grade = accuracyGrade(r.position.accuracy);
	const acc = r.position.accuracy != null ? formatNumber(Math.round(r.position.accuracy), isRTL) : "";
	const quality = grade === "poor" ? (isRTL ? ` · موقع تقريبي ±${acc} م` : ` · approximate ±${acc} m`) : grade === "fair" ? (isRTL ? ` · دقة متوسطة ±${acc} م` : ` · fair accuracy ±${acc} m`) : "";
	const away = m.away ? (isRTL ? " · التطبيق ليس في الواجهة" : " · app not in foreground") : "";
	/* The status pill already says «مباشر»; the line adds what it cannot: when, and how sure. */
	if (r.fresh === "live") return `${isRTL ? "آخر تحديث" : "Updated"} ${ago}${quality}`;
	if (r.fresh === "recent") return `${isRTL ? "آخر موقع معروف" : "Last known position"} · ${ago}${quality}${gpsNote}${away}`;
	return `${isRTL ? "انقطع الاتصال — آخر موقع" : "Connection lost — last position"} ${ago}`;
}

type PillKind = "live" | "recent" | "lost" | "paused" | "waiting";

function pillOf(r: Row): PillKind {
	if (!r.member.sharing) return "paused";
	if (!r.position) return r.seenAgeMs != null && r.seenAgeMs <= 60_000 ? "waiting" : "lost";
	return r.fresh || "lost";
}

/** Status in words and colour — never colour alone. */
function StatusPill({ row, isRTL }: { row: Row; isRTL: boolean }) {
	const k = pillOf(row);
	const ar = { live: "مباشر", recent: "آخر موقع معروف", lost: "انقطع الاتصال", paused: "أوقف المشاركة", waiting: "بانتظار موقعه" };
	const en = { live: "Live", recent: "Last known", lost: "Connection lost", paused: "Paused sharing", waiting: "Waiting" };
	return (
		<span className="sary-o-pill" data-kind={k} data-testid="outing-member-status">
			{(isRTL ? ar : en)[k]}
		</span>
	);
}

function Face({ name, avatar, fresh, color }: { name: string; avatar: string | null; fresh?: Freshness | null; color?: string }) {
	const style = { ...(avatar ? { backgroundImage: `url("${avatar}")` } : {}), ...(color ? { "--car": color } : {}) } as React.CSSProperties;
	return (
		<span className="sary-o-face" data-fresh={fresh || undefined} style={style} aria-hidden="true">
			{avatar ? "" : initials(name)}
		</span>
	);
}

/** Your optional number, so friends in the outing can call or WhatsApp you. */
function MyPhone({ current, isRTL, onSaved }: { current: string | null; isRTL: boolean; onSaved: (toast: string) => void }) {
	const [open, setOpen] = useState(false);
	const [value, setValue] = useState("");
	const [busy, setBusy] = useState(false);
	const [error, setError] = useState<string | null>(null);
	const save = async (phone: string) => {
		setBusy(true);
		setError(null);
		try {
			await OutingsApi.updateProfile({ phone });
			setOpen(false);
			onSaved(phone ? (isRTL ? "أصحابك يقدرون يتصلون عليك الآن ✓" : "Friends can call you now ✓") : isRTL ? "حُذف رقمك" : "Number removed");
		} catch (e) {
			setError(outingErrorText(e instanceof OutingApiError ? e.code : "network", isRTL));
		} finally {
			setBusy(false);
		}
	};
	if (!open) {
		return (
			<div className="sary-o-myphone" data-testid="outing-my-phone">
				<Phone className="size-4" aria-hidden />
				<span dir="ltr">{current || (isRTL ? "لم تضف رقمك" : "No number added")}</span>
				<button
					type="button"
					className="sary-o-link-btn"
					onClick={() => {
						setValue(current || "");
						setOpen(true);
					}}
					data-testid="outing-my-phone-edit"
				>
					{current ? (isRTL ? "تعديل" : "Edit") : isRTL ? "أضف رقمك ليتصل بك أصحابك" : "Add your number so friends can call"}
				</button>
			</div>
		);
	}
	return (
		<form
			className="sary-o-form sary-o-myphone-form"
			onSubmit={(e) => {
				e.preventDefault();
				void save(value.trim());
			}}
		>
			<label>
				<span>{isRTL ? "رقم جوالك (يظهر لأعضاء طلعاتك فقط)" : "Your mobile (shown to your outing members only)"}</span>
				<input
					type="tel"
					inputMode="tel"
					autoComplete="tel"
					dir="ltr"
					value={value}
					onChange={(e) => setValue(e.target.value)}
					placeholder="05XXXXXXXX"
					maxLength={20}
					data-testid="outing-my-phone-input"
					autoFocus
				/>
			</label>
			{error ? <p className="sary-o-error" role="alert">{error}</p> : null}
			<div className="sary-o-row">
				<button type="submit" className="sary-o-primary" disabled={busy || !value.trim()} data-testid="outing-my-phone-save">
					{isRTL ? "حفظ" : "Save"}
				</button>
				{current ? (
					<button type="button" className="sary-o-secondary" disabled={busy} onClick={() => void save("")}>
						{isRTL ? "احذف رقمي" : "Remove"}
					</button>
				) : null}
				<button type="button" className="sary-o-secondary" onClick={() => setOpen(false)}>
					{isRTL ? "إلغاء" : "Cancel"}
				</button>
			</div>
		</form>
	);
}

function MemberCard({
	row,
	isRTL,
	isOwner,
	busy,
	onBack,
	onFocus,
	onRemove,
}: {
	row: Row;
	isRTL: boolean;
	isOwner: boolean;
	busy: boolean;
	onBack: () => void;
	onFocus: () => void;
	onRemove: () => void;
}) {
	const p = row.position;
	return (
		<div className="sary-o-panel" data-testid="outing-member-card">
			<button type="button" className="sary-o-link-btn" onClick={onBack}>
				{isRTL ? <ChevronRight className="size-4" aria-hidden /> : <ChevronLeft className="size-4" aria-hidden />}
				{isRTL ? "كل المشاركين" : "All members"}
			</button>
			<div className="sary-o-member is-card">
				<Face name={row.member.display_name} avatar={row.member.avatar} fresh={row.fresh} />
				<div>
					<strong>{row.member.display_name}</strong>
					<span>{memberLine(row, isRTL)}</span>
				</div>
				<StatusPill row={row} isRTL={isRTL} />
			</div>
			<dl className="sary-o-facts">
				{row.distanceM != null && row.bearing != null ? (
					<>
						<dt>{isRTL ? "المسافة" : "Distance"}</dt>
						<dd>
							{formatDistance(row.distanceM, isRTL)} · {directionLabel(row.bearing, isRTL)}
						</dd>
					</>
				) : null}
				{p ? (
					<>
						<dt>{isRTL ? "آخر تحديث" : "Last update"}</dt>
						<dd>{formatTime(p.recorded_at, isRTL)}</dd>
						{p.speed != null ? (
							<>
								<dt>{isRTL ? "السرعة" : "Speed"}</dt>
								<dd>{formatNumber(Math.round(p.speed * 3.6), isRTL)} {isRTL ? "كم/س" : "km/h"}</dd>
							</>
						) : null}
						{p.accuracy != null ? (
							<>
								<dt>{isRTL ? "الدقة" : "Accuracy"}</dt>
								<dd>± {formatNumber(Math.round(p.accuracy), isRTL)} {isRTL ? "م" : "m"}</dd>
							</>
						) : null}
					</>
				) : null}
			</dl>
			{row.member.phone ? (
				<div className="sary-o-row sary-o-contact">
					<a className="sary-o-primary sary-o-linkbtn" href={`tel:${row.member.phone}`} data-testid="outing-member-call">
						<Phone className="size-4" aria-hidden />
						{isRTL ? "اتصال" : "Call"}
					</a>
					<a
						className="sary-o-secondary sary-o-linkbtn"
						href={`https://wa.me/${row.member.phone.replace(/^\+/, "")}`}
						target="_blank"
						rel="noopener noreferrer"
						data-testid="outing-member-whatsapp"
					>
						<MessageCircle className="size-4" aria-hidden />
						{isRTL ? "واتساب" : "WhatsApp"}
					</a>
				</div>
			) : (
				<p className="sary-o-note" data-testid="outing-member-no-phone">
					{isRTL ? `لم يضف ${row.member.display_name} رقم جواله بعد.` : `${row.member.display_name} hasn't added a phone number.`}
				</p>
			)}
			<div className="sary-o-row">
				<button type="button" className="sary-o-secondary" disabled={!p} onClick={onFocus} data-testid="outing-member-focus">
					{isRTL ? "أنا وياه على الخريطة" : "Both of us on the map"}
				</button>
				{p ? (
					<a
						className="sary-o-secondary sary-o-linkbtn"
						href={directionsUrl(p)}
						target="_blank"
						rel="noopener noreferrer"
						data-testid="outing-member-directions"
					>
						<Navigation className="size-4" aria-hidden />
						{isRTL ? "اتجه إليه" : "Directions"}
					</a>
				) : null}
				{isOwner && row.member.role !== "owner" ? (
					<button type="button" className="sary-o-danger" disabled={busy} onClick={onRemove} data-testid="outing-member-remove">
						{isRTL ? "إزالة" : "Remove"}
					</button>
				) : null}
			</div>
		</div>
	);
}
