import { useNavigate } from "@tanstack/react-router";
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
import { lastSeenAgeMs, positionAgeMs } from "../../lib/outings/outingState";
import { ParticipantMarkers, type ParticipantView } from "../../lib/outings/participantMarkers";
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
import { haversineMeters } from "../../lib/sary/domain";
import type { IntelligenceMapPlaces } from "../../services/intelligenceService";
import FarqBottomSheet, { sheetHeightPx, type SheetSnap } from "../intelligence/FarqBottomSheet";
import { liveStateLabel, statusLabel } from "./labels";
import { useLiveOuting } from "./useLiveOuting";
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
	const { userLocation, userHeading, userFixAt, locationPinKind, locationError, hasLocationPermission, requestLocation } = useLocation();
	const [mode, setMode] = useState<ShareMode>(() => loadShareMode());
	const live = useLiveOuting(outingId, mode);
	const { view, liveState, closed, loadError, canSend, lastRefusal, visible, held, gpsState } = live;
	const [panel, setPanel] = useState<OutingPanel>(initialPanel || "members");
	const [snap, setSnap] = useState<SheetSnap>(initialPanel === "invite" ? "half" : "peek");
	const [selected, setSelected] = useState<string | null>(null);
	const [confirmEnd, setConfirmEnd] = useState(false);
	const [busy, setBusy] = useState(false);
	const [actionError, setActionError] = useState<string | null>(null);
	const [now, setNow] = useState(() => Date.now());
	const [map, setMap] = useState<MapboxMap | null>(null);
	const [focus, setFocus] = useState<{ lat: number; lng: number; id: string; zoom?: number; kind?: "select" | "locate" | "bounds"; bounds?: [number, number, number, number] | null } | null>(null);
	const markersRef = useRef<ParticipantMarkers | null>(null);
	const [follow, setFollow] = useState(false);
	const fittedRef = useRef(false);

	useEffect(() => {
		const t = window.setInterval(() => setNow(Date.now()), 5_000);
		return () => window.clearInterval(t);
	}, []);

	const me = view?.snapshot.me;
	const outing = view?.snapshot.outing;
	const isOwner = me?.role === "owner";

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
			}));
		layer.sync(views);
	}, [rows, selected, map]);

	const groupBounds = (): [number, number, number, number] | null => {
		const pts: Array<{ lat: number; lng: number }> = rows.filter((r) => r.position).map((r) => r.position!);
		if (locationPinKind === "gps" && userLocation) pts.push(userLocation);
		if (!pts.length) return null;
		let w = Infinity, s = Infinity, e = -Infinity, n = -Infinity;
		for (const p of pts) {
			w = Math.min(w, p.lng);
			e = Math.max(e, p.lng);
			s = Math.min(s, p.lat);
			n = Math.max(n, p.lat);
		}
		const pad = 0.002;
		return [w - pad, s - pad, e + pad, n + pad];
	};

	const fitGroup = () => {
		const b = groupBounds();
		if (!b) return;
		setFollow(false);
		setFocus({ lat: (b[1] + b[3]) / 2, lng: (b[0] + b[2]) / 2, id: `group-${Date.now()}`, kind: "bounds", bounds: b });
	};

	const locateMe = () => {
		requestLocation();
		if (userLocation) {
			setFollow(true);
			setFocus({ lat: userLocation.lat, lng: userLocation.lng, id: `me-${Date.now()}`, kind: "locate", zoom: 14.5 });
		}
	};

	/* First time positions arrive, frame the whole group once. */
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
				? `${(rows.length + 1).toLocaleString("ar-SA")} مشارك · ${liveCount.toLocaleString("ar-SA")} مباشر`
				: `${rows.length + 1} members · ${liveCount} live`}
			{rows[0]?.distanceM != null ? ` · ${isRTL ? "الأقرب" : "nearest"} ${formatDistance(rows[0].distanceM, isRTL)}` : ""}
		</span>
	);

	const inviteToken = loadInviteToken(outingId);
	const invite = view?.snapshot.invite;

	return (
		<div className="sary-o-live" dir={isRTL ? "rtl" : "ltr"} data-testid="outing-live">
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
						showUserLocation={locationPinKind === "gps" && Boolean(userLocation)}
						followMode={follow}
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
					{isRTL ? "→" : "←"}
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
			</div>

			<FarqBottomSheet
				snap={snap}
				onSnap={setSnap}
				isRTL={isRTL}
				testId="outing-sheet"
				header={header}
				rail={
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
						{isOwner && outing?.status === "created" ? (
							<button type="button" className="sary-o-primary sary-o-inline" disabled={busy} onClick={() => void run(() => OutingsApi.setStatus(outingId, "start"))} data-testid="outing-start">
								{isRTL ? "ابدأ الطلعة" : "Start"}
							</button>
						) : null}
					</div>
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
							onFocus={() => {
								if (!selectedRow.position) return;
								setFollow(false);
								setFocus({ lat: selectedRow.position.lat, lng: selectedRow.position.lng, id: `peer-${Date.now()}`, kind: "select", zoom: 15 });
							}}
							onRemove={() => {
								if (!window.confirm(isRTL ? `إزالة ${selectedRow.member.display_name} من الطلعة؟ لن يستطيع العودة.` : `Remove ${selectedRow.member.display_name}? They cannot rejoin.`)) return;
								setSelected(null);
								void run(() => OutingsApi.removeMember(outingId, selectedRow.member.user_id));
							}}
						/>
					) : (
						<ul className="sary-o-members" data-testid="outing-members">
							<li className="sary-o-member is-me">
								<Face name={me ? view?.members.get(me.user_id)?.display_name || "" : ""} avatar={me ? view?.members.get(me.user_id)?.avatar || null : null} />
								<div>
									<strong>{isRTL ? "أنت" : "You"}{isOwner ? (isRTL ? " · صاحب الطلعة" : " · owner") : ""}</strong>
									<span>{sharingLine}</span>
								</div>
							</li>
							{rows.map((r) => (
								<li key={r.member.user_id}>
									<button type="button" className="sary-o-member" onClick={() => setSelected(r.member.user_id)} data-testid="outing-member" data-user={r.member.user_id} data-fresh={r.fresh || "none"}>
										<Face name={r.member.display_name} avatar={r.member.avatar} fresh={r.fresh} />
										<div>
											<strong>
												{r.member.display_name}
												{r.member.role === "owner" ? (isRTL ? " · صاحب الطلعة" : " · owner") : ""}
											</strong>
											<span>{memberLine(r, isRTL)}</span>
										</div>
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
									{isRTL ? "أي شخص معه هذا الرابط يستطيع الانضمام حتى" : "Anyone with this link can join until"}{" "}
									{invite.expires_at ? new Date(invite.expires_at).toLocaleString(isRTL ? "ar-SA" : "en") : ""}
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
											await navigator.clipboard?.writeText(url).catch(() => undefined);
											setActionError(null);
										}}
										data-testid="outing-invite-share"
									>
										{isRTL ? "مشاركة الرابط" : "Share link"}
									</button>
									<button type="button" className="sary-o-secondary" onClick={() => void navigator.clipboard?.writeText(inviteUrl(inviteToken))}>
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
						<fieldset className="sary-o-modes">
							<legend>{isRTL ? "سرعة التحديث" : "Update rate"}</legend>
							{(["precise", "balanced", "saver"] as ShareMode[]).map((m) => (
								<label key={m}>
									<input
										type="radio"
										name="share-mode"
										checked={mode === m}
										onChange={() => {
											setMode(m);
											saveShareMode(m);
										}}
									/>
									<span>
										{m === "precise"
											? isRTL ? "دقيق — أسرع من المتوازن (بطارية وبيانات أكثر)" : "Precise — faster than balanced (more battery and data)"
											: m === "balanced"
												? isRTL ? "متوازن — حسب سرعتك: ٢٫٥ ث فوق ٩٠ كم/س، ٤ ث على الطريق، ٦ ث في الرمل، ٣٠ ث واقف" : "Balanced — by speed: 2.5 s above 90 km/h, 4 s on road, 6 s on sand, 30 s parked"
												: isRTL ? "موفّر — نصف المعدل، للطلعات الطويلة" : "Saver — half the rate, for long trips"}
									</span>
								</label>
							))}
						</fieldset>
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
								<button type="button" className="sary-o-danger" disabled={busy} onClick={() => setConfirmEnd(true)} data-testid="outing-end">
									{isRTL ? "إنهاء الطلعة" : "End outing"}
								</button>
							</div>
						) : null}
						<button
							type="button"
							className="sary-o-danger"
							disabled={busy}
							onClick={() => {
								const msg = isOwner
									? isRTL ? "مغادرة الطلعة؟ ستنتقل إدارتها لأقدم مشارك." : "Leave? Ownership passes to the earliest member."
									: isRTL ? "مغادرة الطلعة؟ تتوقف مشاركة موقعك فورًا." : "Leave? Your sharing stops at once.";
								if (!window.confirm(msg)) return;
								void run(async () => {
									await OutingsApi.leave(outingId);
									void navigate({ to: "/outings" });
								});
							}}
							data-testid="outing-leave"
						>
							{isRTL ? "مغادرة الطلعة" : "Leave outing"}
						</button>
					</div>
				) : null}
			</FarqBottomSheet>

			{confirmEnd ? (
				<div className="sary-o-modal" role="dialog" aria-modal="true" data-testid="outing-end-confirm">
					<div className="sary-o-card">
						<h2>{isRTL ? "إنهاء الطلعة؟" : "End the outing?"}</h2>
						<p>
							{isRTL
								? "تتوقف مشاركة المواقع لجميع المشاركين فورًا، وتُحذف كل المواقع المحفوظة، ويُلغى رابط الدعوة. لا يمكن التراجع."
								: "Sharing stops for everyone, all stored positions are deleted and the invite is cancelled. This cannot be undone."}
						</p>
						<div className="sary-o-row">
							<button
								type="button"
								className="sary-o-danger"
								disabled={busy}
								onClick={() => {
									setConfirmEnd(false);
									void run(() => OutingsApi.setStatus(outingId, "end"));
								}}
								data-testid="outing-end-yes"
							>
								{isRTL ? "إنهاء للجميع" : "End for everyone"}
							</button>
							<button type="button" className="sary-o-secondary" onClick={() => setConfirmEnd(false)}>
								{isRTL ? "تراجع" : "Cancel"}
							</button>
						</div>
					</div>
				</div>
			) : null}
		</div>
	);
}

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
	const acc = r.position.accuracy != null ? Math.round(r.position.accuracy).toLocaleString(isRTL ? "ar-SA" : "en") : "";
	const quality = grade === "poor" ? (isRTL ? ` · موقع تقريبي ±${acc} م` : ` · approximate ±${acc} m`) : grade === "fair" ? (isRTL ? ` · دقة متوسطة ±${acc} م` : ` · fair accuracy ±${acc} m`) : "";
	const away = m.away ? (isRTL ? " · التطبيق ليس في الواجهة" : " · app not in foreground") : "";
	if (r.fresh === "live") return `${isRTL ? "مباشر" : "Live"} · ${ago}${quality}`;
	if (r.fresh === "recent") return `${isRTL ? "آخر موقع معروف" : "Last known position"} · ${ago}${quality}${gpsNote}${away}`;
	return `${isRTL ? "انقطع الاتصال — آخر موقع" : "Connection lost — last position"} ${ago}`;
}

function Face({ name, avatar, fresh }: { name: string; avatar: string | null; fresh?: Freshness | null }) {
	return (
		<span className="sary-o-face" data-fresh={fresh || undefined} style={avatar ? { backgroundImage: `url("${avatar}")` } : undefined} aria-hidden="true">
			{avatar ? "" : initials(name)}
		</span>
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
				{isRTL ? "→ كل المشاركين" : "← All members"}
			</button>
			<div className="sary-o-member is-card">
				<Face name={row.member.display_name} avatar={row.member.avatar} fresh={row.fresh} />
				<div>
					<strong>{row.member.display_name}</strong>
					<span>{memberLine(row, isRTL)}</span>
				</div>
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
						<dd>{new Date(p.recorded_at).toLocaleTimeString(isRTL ? "ar-SA" : "en")}</dd>
						{p.speed != null ? (
							<>
								<dt>{isRTL ? "السرعة" : "Speed"}</dt>
								<dd>{Math.round(p.speed * 3.6).toLocaleString(isRTL ? "ar-SA" : "en")} {isRTL ? "كم/س" : "km/h"}</dd>
							</>
						) : null}
						{p.accuracy != null ? (
							<>
								<dt>{isRTL ? "الدقة" : "Accuracy"}</dt>
								<dd>± {Math.round(p.accuracy).toLocaleString(isRTL ? "ar-SA" : "en")} {isRTL ? "م" : "m"}</dd>
							</>
						) : null}
					</>
				) : null}
			</dl>
			<div className="sary-o-row">
				<button type="button" className="sary-o-primary" disabled={!p} onClick={onFocus} data-testid="outing-member-focus">
					{isRTL ? "أظهره على الخريطة" : "Show on map"}
				</button>
				{isOwner && row.member.role !== "owner" ? (
					<button type="button" className="sary-o-danger" disabled={busy} onClick={onRemove} data-testid="outing-member-remove">
						{isRTL ? "إزالة" : "Remove"}
					</button>
				) : null}
			</div>
		</div>
	);
}
