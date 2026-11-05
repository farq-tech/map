/**
 * Safety controls on the outing screen: the long-press «طوارئ» button, the
 * full-screen alert others see, the rally-point card and the pin placer.
 * State lives in OutingLive; these are views plus the alarm sound.
 */

import { Navigation, Phone } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import type { Map as MapboxMap } from "mapbox-gl";
import type { Rally, Sos } from "../../lib/outings/api";
import { directionLabel, formatAgo, formatDistance } from "../../lib/outings/policy";
import { directionsUrl, formatNumber } from "../../lib/sary/domain";
import "../../styles/outing-safety.css";

export const SOS_HOLD_MS = 1_000;

/* ---------- alarm sound ---------- */

/* Browsers only let a page make sound after a tap. Open the audio context on
 * the first one, so an SOS that arrives later can actually be heard. */
let audio: AudioContext | null = null;
function unlockAudio() {
	try {
		const Ctx = window.AudioContext || (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
		if (!Ctx) return;
		audio = audio || new Ctx();
		if (audio.state === "suspended") void audio.resume();
	} catch {
		/* no Web Audio here */
	}
}

export function useAudioUnlock(): void {
	useEffect(() => {
		const on = () => unlockAudio();
		document.addEventListener("pointerdown", on, { capture: true });
		document.addEventListener("keydown", on, { capture: true });
		return () => {
			document.removeEventListener("pointerdown", on, { capture: true });
			document.removeEventListener("keydown", on, { capture: true });
		};
	}, []);
}

/** A two-tone siren and vibration while `on`, for at most 30 s. Silent where the browser does not allow it. */
export function useSiren(on: boolean): void {
	useEffect(() => {
		if (!on) return;
		try {
			navigator.vibrate?.([400, 150, 400, 150, 400, 150, 800]);
		} catch {
			/* */
		}
		const ctx = audio;
		if (!ctx || ctx.state !== "running") return;
		let stopped = false;
		const beep = (i: number) => {
			if (stopped) return;
			const osc = ctx.createOscillator();
			const gain = ctx.createGain();
			osc.type = "square";
			osc.frequency.value = i % 2 ? 660 : 880;
			gain.gain.setValueAtTime(0.0001, ctx.currentTime);
			gain.gain.exponentialRampToValueAtTime(0.18, ctx.currentTime + 0.02);
			gain.gain.exponentialRampToValueAtTime(0.0001, ctx.currentTime + 0.36);
			osc.connect(gain).connect(ctx.destination);
			osc.start();
			osc.stop(ctx.currentTime + 0.4);
		};
		let i = 0;
		beep(i);
		const t = window.setInterval(() => beep(++i), 450);
		const cap = window.setTimeout(() => window.clearInterval(t), 30_000);
		return () => {
			stopped = true;
			window.clearInterval(t);
			window.clearTimeout(cap);
			try {
				navigator.vibrate?.(0);
			} catch {
				/* */
			}
		};
	}, [on]);
}

/* ---------- the button ---------- */

/** Held for a full second, never a tap: a pocket or a bump must not call for help. */
export function SosHoldButton({ isRTL, disabled, onTrigger, onShortPress }: { isRTL: boolean; disabled?: boolean; onTrigger: () => void; onShortPress: () => void }) {
	const [holding, setHolding] = useState(false);
	const timer = useRef<number | null>(null);
	const fired = useRef(false);
	const begin = () => {
		if (disabled || timer.current) return;
		fired.current = false;
		setHolding(true);
		timer.current = window.setTimeout(() => {
			timer.current = null;
			fired.current = true;
			setHolding(false);
			try {
				navigator.vibrate?.(80);
			} catch {
				/* */
			}
			onTrigger();
		}, SOS_HOLD_MS);
	};
	const end = () => {
		if (timer.current) {
			window.clearTimeout(timer.current);
			timer.current = null;
			if (!fired.current) onShortPress();
		}
		setHolding(false);
	};
	useEffect(() => () => {
		if (timer.current) window.clearTimeout(timer.current);
	}, []);
	return (
		<button
			type="button"
			className="sary-sos-btn"
			data-holding={holding ? "1" : "0"}
			disabled={disabled}
			aria-label={isRTL ? "طوارئ — اضغط مطولًا ثانية لإرسال نداء استغاثة" : "Emergency — press and hold for one second to send an SOS"}
			onPointerDown={(e) => {
				e.preventDefault();
				(e.currentTarget as HTMLElement).setPointerCapture?.(e.pointerId);
				begin();
			}}
			onPointerUp={end}
			onPointerCancel={end}
			onContextMenu={(e) => e.preventDefault()}
			onKeyDown={(e) => {
				if ((e.key === " " || e.key === "Enter") && !e.repeat) {
					e.preventDefault();
					begin();
				}
			}}
			onKeyUp={(e) => {
				if (e.key === " " || e.key === "Enter") end();
			}}
			data-testid="outing-sos"
		>
			<span className="sary-sos-btn__ring" aria-hidden="true" />
			<span>{isRTL ? "طوارئ" : "SOS"}</span>
		</button>
	);
}

/** On the sender's screen while their SOS is out. */
export function MySosBanner({ isRTL, busy, onCancel, noFix = false }: { isRTL: boolean; busy: boolean; onCancel: () => void; noFix?: boolean }) {
	return (
		<div className="sary-sos-mine" role="status" data-testid="outing-sos-mine">
			<strong>{isRTL ? "أرسلت نداء طوارئ لكل أعضاء الطلعة" : "Your SOS went out to everyone in the outing"}</strong>
			{/* No GPS (or location blocked): the call for help still goes out, without a position. */}
			{noFix ? <small data-testid="outing-sos-nofix">{isRTL ? "موقعك غير متاح — وصلهم النداء بدون موقع." : "Your location is unavailable — the SOS went out without it."}</small> : null}
			<button type="button" disabled={busy} onClick={onCancel} data-testid="outing-sos-cancel">
				{isRTL ? "أنا بخير" : "I'm OK"}
			</button>
		</div>
	);
}

export type SosAlertView = {
	userId: string;
	name: string;
	phone: string | null;
	sos: Sos;
	distanceM: number | null;
	bearing: number | null;
	/** Age of the fix carried by the SOS, on the server clock. */
	fixAgeMs: number | null;
};

/** Full screen, red, on everyone else's phone. */
export function SosAlert({ alert, isRTL, onShow, onDismiss }: { alert: SosAlertView; isRTL: boolean; onShow: () => void; onDismiss: () => void }) {
	const f = alert.sos.fix;
	const where =
		!f
			? isRTL ? "موقعه غير معروف — لم تكن عنده قراءة GPS." : "Position unknown — no GPS fix on their phone."
			: alert.distanceM != null && alert.bearing != null
				? isRTL
					? `على بعد ${formatDistance(alert.distanceM, true)} · ${directionLabel(alert.bearing, true)}`
					: `${formatDistance(alert.distanceM, false)} away · ${directionLabel(alert.bearing, false)}`
				: isRTL ? "موقعه على الخريطة (موقعك غير معروف لحساب المسافة)" : "On the map (your own position is unknown)";
	return (
		<div className="sary-sos-alert" role="alertdialog" aria-modal="true" aria-labelledby="sos-alert-title" data-testid="outing-sos-alert" data-user={alert.userId}>
			<div className="sary-sos-alert__body">
				<span className="sary-sos-alert__badge" aria-hidden="true">SOS</span>
				<h2 id="sos-alert-title">{isRTL ? `${alert.name} يطلب فزعة` : `${alert.name} needs help`}</h2>
				<p data-testid="outing-sos-where">{where}</p>
				{f && alert.fixAgeMs != null ? (
					<p className="sary-sos-alert__age">
						{isRTL ? "آخر موقع معروف له" : "Last known position"} · {formatAgo(alert.fixAgeMs, isRTL)}
						{f.accuracy != null ? ` · ±${formatNumber(Math.round(f.accuracy), isRTL)} ${isRTL ? "م" : "m"}` : ""}
					</p>
				) : null}
				<div className="sary-sos-alert__actions">
					{alert.phone ? (
						<a className="sary-sos-alert__call" href={`tel:${alert.phone}`} data-testid="outing-sos-call">
							<Phone className="size-5" aria-hidden />
							{isRTL ? "اتصال" : "Call"}
						</a>
					) : null}
					{f ? (
						<button type="button" onClick={onShow} data-testid="outing-sos-show">
							{isRTL ? "أظهره على الخريطة" : "Show on map"}
						</button>
					) : null}
					{f ? (
						<a href={directionsUrl(f)} target="_blank" rel="noopener noreferrer">
							<Navigation className="size-4" aria-hidden />
							{isRTL ? "اتجه إليه" : "Directions"}
						</a>
					) : null}
					<button type="button" className="is-quiet" onClick={onDismiss} data-testid="outing-sos-dismiss">
						{isRTL ? "إغلاق" : "Dismiss"}
					</button>
				</div>
			</div>
		</div>
	);
}

/** After dismissing, a red strip stays until they say «أنا بخير». */
export function SosStrip({ names, isRTL, onOpen }: { names: string[]; isRTL: boolean; onOpen: () => void }) {
	return (
		<button type="button" className="sary-sos-strip" role="alert" onClick={onOpen} data-testid="outing-sos-strip">
			<b>SOS</b> {isRTL ? `${names.join("، ")} يطلب فزعة` : `${names.join(", ")} needs help`}
		</button>
	);
}

/* ---------- rally point ---------- */

export function RallyCard({
	rally,
	isRTL,
	isOwner,
	canEdit,
	busy,
	distanceM,
	bearing,
	arrivedNames,
	total,
	onShow,
	onPlace,
	onClear,
}: {
	rally: Rally | null;
	isRTL: boolean;
	isOwner: boolean;
	canEdit: boolean;
	busy: boolean;
	distanceM: number | null;
	bearing: number | null;
	arrivedNames: string[];
	total: number;
	onShow: () => void;
	onPlace: () => void;
	onClear: () => void;
}) {
	if (!rally) {
		if (!isOwner || !canEdit) return null;
		return (
			<div className="sary-rally" data-testid="outing-rally-card" data-set="0">
				<span className="sary-rally__flag" aria-hidden="true">⚑</span>
				<div>
					<strong>{isRTL ? "نقطة التجمع" : "Rally point"}</strong>
					<span>{isRTL ? "حدد مكانًا يلتقي فيه الجميع" : "Pick a spot where everyone meets"}</span>
				</div>
				<button type="button" className="sary-o-secondary" disabled={busy} onClick={onPlace} data-testid="outing-rally-set">
					{isRTL ? "حدد" : "Set"}
				</button>
			</div>
		);
	}
	return (
		<div className="sary-rally" data-testid="outing-rally-card" data-set="1">
			<span className="sary-rally__flag" aria-hidden="true">⚑</span>
			<div>
				<strong>
					{isRTL ? "نقطة التجمع" : "Rally point"}
					{rally.label ? ` · ${rally.label}` : ""}
				</strong>
				<span data-testid="outing-rally-distance">
					{distanceM != null && bearing != null
						? `${formatDistance(distanceM, isRTL)} · ${directionLabel(bearing, isRTL)}`
						: isRTL ? "موقعك غير معروف" : "Your position is unknown"}
				</span>
				<span data-testid="outing-rally-arrived">
					{isRTL ? `وصل ${formatNumber(arrivedNames.length, true)} من ${formatNumber(total, true)}` : `${arrivedNames.length} of ${total} arrived`}
					{arrivedNames.length ? `: ${arrivedNames.join(isRTL ? "، " : ", ")}` : ""}
				</span>
			</div>
			<div className="sary-rally__actions">
				<button type="button" className="sary-o-secondary" onClick={onShow} data-testid="outing-rally-show">
					{isRTL ? "أظهرها" : "Show"}
				</button>
				<a className="sary-o-secondary sary-o-linkbtn" href={directionsUrl(rally)} target="_blank" rel="noopener noreferrer">
					{isRTL ? "اتجه" : "Go"}
				</a>
				{isOwner && canEdit ? (
					<>
						<button type="button" className="sary-o-secondary" disabled={busy} onClick={onPlace} data-testid="outing-rally-move">
							{isRTL ? "نقل" : "Move"}
						</button>
						<button type="button" className="sary-o-danger" disabled={busy} onClick={onClear} data-testid="outing-rally-clear">
							{isRTL ? "إزالة" : "Clear"}
						</button>
					</>
				) : null}
			</div>
		</div>
	);
}

/** Crosshair over the map centre while the owner drags the map to the meeting spot. */
export function RallyPlacer({
	map,
	isRTL,
	busy,
	canUseMe,
	onConfirm,
	onUseMe,
	onCancel,
}: {
	map: MapboxMap | null;
	isRTL: boolean;
	busy: boolean;
	canUseMe: boolean;
	onConfirm: (p: { lat: number; lng: number }) => void;
	onUseMe: () => void;
	onCancel: () => void;
}) {
	const [xy, setXy] = useState<{ x: number; y: number } | null>(null);
	useEffect(() => {
		if (!map) return;
		/* The map's centre honours its padding (the sheet), so project it rather than guess the middle of the screen. */
		const place = () => {
			const p = map.project(map.getCenter());
			const r = map.getContainer().getBoundingClientRect();
			setXy({ x: r.left + p.x, y: r.top + p.y });
		};
		place();
		map.on("move", place);
		map.on("resize", place);
		return () => {
			map.off("move", place);
			map.off("resize", place);
		};
	}, [map]);
	return (
		<>
			{xy ? <span className="sary-rally-cross" style={{ left: xy.x, top: xy.y }} aria-hidden="true" data-testid="outing-rally-cross">⚑</span> : null}
			<div className="sary-rally-place" role="dialog" aria-label={isRTL ? "تحديد نقطة التجمع" : "Set the rally point"} data-testid="outing-rally-placer">
				<p>{isRTL ? "حرّك الخريطة حتى تكون العلامة على مكان التجمع" : "Move the map until the flag is on the meeting spot"}</p>
				<div className="sary-o-row">
					<button
						type="button"
						className="sary-o-primary"
						disabled={busy || !map}
						onClick={() => {
							if (!map) return;
							const c = map.getCenter();
							onConfirm({ lat: c.lat, lng: c.lng });
						}}
						data-testid="outing-rally-confirm"
					>
						{isRTL ? "ثبّت هنا" : "Pin here"}
					</button>
					{canUseMe ? (
						<button type="button" className="sary-o-secondary" disabled={busy} onClick={onUseMe} data-testid="outing-rally-here">
							{isRTL ? "عند موقعي" : "At my position"}
						</button>
					) : null}
					<button type="button" className="sary-o-secondary" onClick={onCancel}>
						{isRTL ? "إلغاء" : "Cancel"}
					</button>
				</div>
			</div>
		</>
	);
}

/* ---------- battery ---------- */

export function BatteryBadge({ level, charging, low, isRTL }: { level: number; charging: boolean; low: boolean; isRTL: boolean }) {
	const pct = formatNumber(Math.round(level * 100), isRTL);
	return (
		<span className="sary-batt" data-low={low ? "1" : "0"} data-testid="outing-member-battery" title={isRTL ? "البطارية" : "Battery"}>
			{charging ? "⚡" : ""}
			{isRTL ? `${pct}٪` : `${pct}%`}
			{low ? <span className="sary-batt__warn">{isRTL ? " بطارية ضعيفة" : " low"}</span> : null}
		</span>
	);
}
