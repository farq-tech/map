import type { Map as MapboxMap } from "mapbox-gl";
import { useCallback, useEffect, useRef, useState } from "react";
import { getMapboxAccessToken } from "../../lib/mapboxAccess";
import {
	deleteArea,
	estimateArea,
	formatBytes,
	listAreas,
	OfflineLimitError,
	offlineSupported,
	saveArea,
	savedTileCount,
	type OfflineArea,
	type SaveProgress,
} from "../../lib/offline/offlineAreas";
import { MAX_OFFLINE_TILES, type Bbox } from "../../lib/offline/tiles";

/* The app itself, the map style, icons, Arabic glyphs and the RTL plugin: kept once, with the first area. */
const SHELL_BYTES = 3 * 1024 * 1024;

/* Below z5 the whole Kingdom is a handful of tiles; above the chosen detail the map overzooms. */
const Z_MIN = 5;
const DETAIL = [
	{ id: "normal", zMax: 14, ar: "عادي — الطرق والمعالم", en: "Normal — roads and landmarks" },
	{ id: "high", zMax: 16, ar: "مفصّل — كل الشوارع", en: "Detailed — every street" },
] as const;
type DetailId = (typeof DETAIL)[number]["id"];

function viewBbox(map: MapboxMap): Bbox {
	const b = map.getBounds()!;
	return [b.getWest(), b.getSouth(), b.getEast(), b.getNorth()];
}

const num = (n: number, ar: boolean) => (ar ? n.toLocaleString("ar-SA") : n.toLocaleString("en"));

/**
 * «حفظ المنطقة دون اتصال»: keep the area on screen on this phone before a
 * trip, so the map still shows it with no signal. Honest about size up
 * front, shows progress, can be cancelled, and saved areas can be removed.
 */
export default function OfflineAreaSheet({ isRTL, map, basemap, onClose }: { isRTL: boolean; map: MapboxMap | null; basemap: string; onClose: () => void }) {
	const ar = isRTL;
	const [detail, setDetail] = useState<DetailId>("normal");
	const [estimate, setEstimate] = useState<{ tiles: number; estimateBytes: number } | null>(null);
	const [used, setUsed] = useState(0);
	const [areas, setAreas] = useState<OfflineArea[]>([]);
	const [progress, setProgress] = useState<SaveProgress | null>(null);
	const [message, setMessage] = useState<string | null>(null);
	const abortRef = useRef<AbortController | null>(null);
	const zMax = DETAIL.find((d) => d.id === detail)!.zMax;
	const supported = offlineSupported();

	const refresh = useCallback(async () => {
		setAreas(await listAreas());
		setUsed(await savedTileCount());
	}, []);

	useEffect(() => {
		void refresh();
	}, [refresh]);

	/* The estimate follows the camera while the sheet is open. */
	useEffect(() => {
		if (!map || !supported) return;
		let alive = true;
		const run = () => {
			void estimateArea(viewBbox(map), Z_MIN, zMax).then((e) => alive && setEstimate(e));
		};
		run();
		map.on("moveend", run);
		return () => {
			alive = false;
			map.off("moveend", run);
		};
	}, [map, zMax, supported]);

	useEffect(() => () => abortRef.current?.abort(), []);

	useEffect(() => {
		const onKey = (e: KeyboardEvent) => {
			if (e.key === "Escape") onClose();
		};
		window.addEventListener("keydown", onKey);
		return () => window.removeEventListener("keydown", onKey);
	}, [onClose]);

	const room = MAX_OFFLINE_TILES - used;
	const shell = areas.length ? 0 : SHELL_BYTES;
	const tooBig = estimate ? estimate.tiles > room : false;
	const saving = progress !== null && abortRef.current !== null;

	const save = async () => {
		if (!map) return;
		const ctrl = new AbortController();
		abortRef.current = ctrl;
		setMessage(null);
		setProgress({ done: 0, total: 1, bytes: 0, failed: 0 });
		try {
			const area = await saveArea(
				{
					name: ar ? `منطقة ${new Date().toLocaleDateString("ar-SA", { day: "numeric", month: "long" })}` : `Area ${new Date().toLocaleDateString("en", { day: "numeric", month: "short" })}`,
					bbox: viewBbox(map),
					zMin: Z_MIN,
					zMax,
					token: getMapboxAccessToken(),
					basemap,
				},
				setProgress,
				ctrl.signal,
			);
			setMessage(
				area.failed
					? ar
						? `حُفظت المنطقة (${formatBytes(area.bytes, true)}) — تعذّر تنزيل ${num(area.failed, true)} جزءًا، وقد تظهر فراغات.`
						: `Saved (${formatBytes(area.bytes, false)}) — ${area.failed} pieces failed and may show as gaps.`
					: ar
						? `حُفظت المنطقة على جهازك (${formatBytes(area.bytes, true)}). ستظهر الخريطة هنا حتى بلا إنترنت.`
						: `Saved on this phone (${formatBytes(area.bytes, false)}). The map will show here with no internet.`,
			);
		} catch (e) {
			if (e instanceof DOMException && e.name === "AbortError") setMessage(ar ? "أُلغي الحفظ." : "Cancelled.");
			else if (e instanceof OfflineLimitError) setMessage(ar ? "لا تتسع: احذف منطقة محفوظة أو قرّب الخريطة." : "Not enough room: delete a saved area or zoom in.");
			else setMessage(ar ? "تعذّر الحفظ. تأكد من الاتصال وحاول مرة أخرى." : "Could not save. Check your connection and try again.");
		} finally {
			abortRef.current = null;
			setProgress(null);
			void refresh();
		}
	};

	const pct = progress && progress.total ? Math.round((progress.done / progress.total) * 100) : 0;

	return (
		<div className="sary-offline" role="dialog" aria-modal="false" aria-labelledby="sary-offline-title" dir={ar ? "rtl" : "ltr"} data-testid="sary-offline">
			<div className="sary-offline__card">
				<header className="sary-offline__head">
					<h2 id="sary-offline-title">{ar ? "حفظ المنطقة للاستخدام دون اتصال" : "Save this area for offline"}</h2>
					<button type="button" className="sary-offline__close" onClick={onClose} aria-label={ar ? "إغلاق" : "Close"} data-testid="sary-offline-close">
						×
					</button>
				</header>
				{!supported ? (
					<p>{ar ? "هذا المتصفح لا يدعم حفظ الخريطة على الجهاز." : "This browser cannot keep the map on the device."}</p>
				) : (
					<>
						<p className="sary-offline__lead">
							{ar
								? "قبل الطلعة: تُحفظ المنطقة الظاهرة على الخريطة الآن على جهازك، فتبقى الخريطة ظاهرة إذا انقطعت الشبكة. حرّك الخريطة وقرّبها لتحديد المنطقة."
								: "Before the trip: the area on screen now is kept on this phone, so the map still shows when the signal drops. Move and zoom the map to choose it."}
						</p>
						<fieldset className="sary-offline__detail" disabled={saving}>
							<legend>{ar ? "مستوى التفاصيل" : "Detail"}</legend>
							{DETAIL.map((d) => (
								<label key={d.id}>
									<input type="radio" name="sary-offline-detail" checked={detail === d.id} onChange={() => setDetail(d.id)} data-testid={`sary-offline-detail-${d.id}`} />
									{ar ? d.ar : d.en}
								</label>
							))}
						</fieldset>
						<p className="sary-offline__estimate" data-testid="sary-offline-estimate" aria-live="polite">
							{estimate
								? ar
									? `قرابة ${formatBytes(estimate.estimateBytes + shell, true)}، ${num(estimate.tiles, true)} جزءًا من الخريطة`
									: `About ${formatBytes(estimate.estimateBytes + shell, false)}, ${estimate.tiles} map tiles`
								: ar
									? "جارٍ حساب الحجم…"
									: "Estimating…"}
							{tooBig ? (
								<span className="sary-offline__warn">
									{ar
										? ` — أكبر من المسموح (${num(room, true)} جزء متبقٍ من ${num(MAX_OFFLINE_TILES, true)}). قرّب الخريطة أو اختر «عادي».`
										: ` — over the limit (${room} of ${MAX_OFFLINE_TILES} tiles left). Zoom in or choose Normal.`}
								</span>
							) : null}
						</p>
						{progress ? (
							<div className="sary-offline__progress" data-testid="sary-offline-progress">
								<progress max={100} value={pct} aria-label={ar ? "تقدّم الحفظ" : "Saving progress"} />
								<span>
									{ar
										? `${num(pct, true)}٪، ${formatBytes(progress.bytes, true)}`
										: `${pct}%, ${formatBytes(progress.bytes, false)}`}
								</span>
							</div>
						) : null}
						<div className="sary-offline__actions">
							{saving ? (
								<button type="button" className="sary-offline__btn" onClick={() => abortRef.current?.abort()} data-testid="sary-offline-cancel">
									{ar ? "إلغاء" : "Cancel"}
								</button>
							) : (
								<button
									type="button"
									className="sary-offline__btn is-primary"
									onClick={() => void save()}
									disabled={!map || !estimate || !estimate.tiles || tooBig || (typeof navigator !== "undefined" && !navigator.onLine)}
									data-testid="sary-offline-save"
								>
									{ar ? "احفظ هذه المنطقة" : "Save this area"}
								</button>
							)}
						</div>
						{message ? (
							<p className="sary-offline__msg" role="status" data-testid="sary-offline-msg">
								{message}
							</p>
						) : null}
						{areas.length ? (
							<section className="sary-offline__saved">
								<h3>{ar ? "المناطق المحفوظة" : "Saved areas"}</h3>
								<ul>
									{areas.map((a) => (
										<li key={a.id} data-testid="sary-offline-area">
											<button type="button" className="sary-offline__go" onClick={() => map?.fitBounds([[a.bbox[0], a.bbox[1]], [a.bbox[2], a.bbox[3]]], { padding: 24, duration: 600 })}>
												<b>{a.name}</b>
												<small>{formatBytes(a.bytes, ar)}</small>
											</button>
											<button
												type="button"
												className="sary-offline__del"
												disabled={saving}
												onClick={() => void deleteArea(a.id).then(refresh)}
												aria-label={ar ? `حذف ${a.name}` : `Delete ${a.name}`}
											>
												{ar ? "حذف" : "Delete"}
											</button>
										</li>
									))}
								</ul>
							</section>
						) : null}
						<p className="sary-offline__fine">
							{ar
								? `تُحفظ الخريطة الحالية فقط (${basemap === "satellite" ? "صور فضائية" : "خريطة الشوارع"}). الحد ${num(MAX_OFFLINE_TILES, true)} جزء على الجهاز. لا تُحفظ مواقع الطلعة ولا أي بيانات خاصة بك.`
								: `Only the current map style is kept (${basemap}). Limit ${MAX_OFFLINE_TILES} tiles per device. No outing positions or personal data are stored.`}
						</p>
					</>
				)}
			</div>
		</div>
	);
}
