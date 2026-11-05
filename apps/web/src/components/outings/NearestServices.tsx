import { Navigation } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";
import { API_BASE_URL } from "../../lib/api";
import { coarseBbox, groupMotion, NEAR_BOX, needWider, rankAlong, shareLine, type Candidate, type Mover, type Ranked } from "../../lib/outings/ahead";
import { directionLabel } from "../../lib/outings/policy";
import { directionsUrl, formatKm } from "../../lib/sary/domain";

type Feature = { properties: { id: string; kind: string; name: string | null; brand?: string; lng: number; lat: number } };

/**
 * «أقرب محطة»: nearest fuel (and water) along the group's way, from the OSM
 * outdoor dataset (ODbL). The request carries only a coarse ~1° box — the
 * ranking happens here — and no identity token.
 */
export function NearestServices({ people, isRTL, onShare, onClose, busy }: { people: Mover[]; isRTL: boolean; onShare: (text: string) => void; onClose: () => void; busy: boolean }) {
	const motion = useMemo(() => groupMotion(people), [people]);
	const near = motion ? coarseBbox(motion.origin, NEAR_BOX.grid, NEAR_BOX.half).join(",") : null;
	const wide = motion ? coarseBbox(motion.origin).join(",") : null;
	const heading = motion?.heading ?? null;
	const originRef = useRef(motion);
	originRef.current = motion;
	const [items, setItems] = useState<Candidate[] | null>(null);
	const [error, setError] = useState(false);

	/* Near box first; only when it has too few fuel answers along the way, the wide one too. */
	useEffect(() => {
		if (!near || !wide) return;
		let off = false;
		setError(false);
		setItems(null);
		const load = (box: string) =>
			fetch(`${API_BASE_URL}/api/outdoor/features?bbox=${box}&types=fuel,well,spring&limit=400`, { headers: { accept: "application/json" } })
				.then((r) => (r.ok ? r.json() : Promise.reject(new Error(String(r.status)))))
				.then((fc: { features?: Feature[] }) =>
					(fc.features || []).map((f) => ({ id: f.properties.id, kind: f.properties.kind, name: f.properties.name, brand: f.properties.brand || null, lat: f.properties.lat, lng: f.properties.lng })),
				);
		(async () => {
			let got = await load(near);
			const m = originRef.current;
			if (m && needWider(rankAlong(m.origin, m.heading, got.filter((c) => c.kind === "fuel")), m.heading)) {
				const seen = new Set(got.map((c) => c.id));
				got = [...got, ...(await load(wide)).filter((c) => !seen.has(c.id))];
			}
			if (!off) setItems(got);
		})().catch(() => !off && setError(true));
		return () => {
			off = true;
		};
	}, [near, wide]);

	const fuel = useMemo(() => (motion && items ? rankAlong(motion.origin, heading, items.filter((c) => c.kind === "fuel")) : []), [motion, items, heading]);
	const water = useMemo(() => (motion && items ? rankAlong(motion.origin, heading, items.filter((c) => c.kind === "well" || c.kind === "spring"), { limit: 2 }) : []), [motion, items, heading]);

	return (
		<div className="sary-o-modal" role="dialog" aria-modal="true" aria-labelledby="outing-nearest-title" data-testid="outing-nearest">
			<div className="sary-o-card">
				<h2 id="outing-nearest-title">{isRTL ? "أقرب محطة" : "Nearest station"}</h2>
				<p className="sary-o-note" data-testid="outing-nearest-basis">
					{!motion
						? isRTL ? "لا نعرف موقع المجموعة بعد." : "We don't know where the group is yet."
						: heading != null
							? isRTL ? `باتجاه سير المجموعة (${directionLabel(heading, true)}) — من مواقع ${motion.movers} ${motion.movers === 1 ? "سيارة" : "سيارات"} تتحرك.` : `Along the group's heading (${directionLabel(heading, false)}), from ${motion.movers} moving car(s).`
							: isRTL ? "المجموعة واقفة أو اتجاهاتها مختلفة — نعرض الأقرب في أي اتجاه." : "The group is parked or split — showing nearest in any direction."}
				</p>
				{error ? <p className="sary-o-error" role="alert">{isRTL ? "تعذّر جلب البيانات. أعد المحاولة." : "Could not load the data. Try again."}</p> : null}
				{motion && items === null && !error ? <p className="sary-o-note">…</p> : null}
				{items ? (
					<>
						<h3>{isRTL ? "⛽ محطات البنزين" : "⛽ Fuel"}</h3>
						{fuel.length ? (
							<ResultList rows={fuel} isRTL={isRTL} onShare={onShare} busy={busy} />
						) : (
							<p className="sary-o-note" data-testid="outing-nearest-nofuel">
								{isRTL
									? "لا توجد محطة بنزين مسجّلة في بيانات OSM المحمّلة قرب المجموعة. لا نخمّن مكانها."
									: "No fuel station in the loaded OSM data near the group. We don't guess."}
							</p>
						)}
						{water.length ? (
							<>
								<h3>{isRTL ? "💧 آبار وعيون" : "💧 Wells & springs"}</h3>
								<ResultList rows={water} isRTL={isRTL} onShare={onShare} busy={busy} />
							</>
						) : null}
					</>
				) : null}
				<p className="sary-o-note sary-o-attrib">© OpenStreetMap contributors · ODbL</p>
				<div className="sary-o-row">
					<button type="button" className="sary-o-secondary" onClick={onClose} data-testid="outing-nearest-close">
						{isRTL ? "إغلاق" : "Close"}
					</button>
				</div>
			</div>
		</div>
	);
}

function ResultList({ rows, isRTL, onShare, busy }: { rows: Ranked[]; isRTL: boolean; onShare: (text: string) => void; busy: boolean }) {
	return (
		<ul className="sary-o-nearest">
			{rows.map((r) => {
				const where = r.ahead == null ? "" : r.ahead ? (isRTL ? "قدّامكم" : "ahead") : isRTL ? "مو على طريقكم" : "off your way";
				return (
					<li key={r.id} data-testid="outing-nearest-row" data-kind={r.kind} data-ahead={r.ahead == null ? "na" : r.ahead ? "1" : "0"}>
						<div>
							<strong>{r.name || r.brand || (r.kind === "fuel" ? (isRTL ? "محطة بلا اسم في OSM" : "Unnamed station (OSM)") : isRTL ? "قليب بلا اسم" : "Unnamed well")}</strong>
							<span>
								{formatKm(r.distanceM, isRTL)} · {directionLabel(r.bearing, isRTL)}
								{where ? ` · ${where}` : ""}
								{r.alongM != null && r.ahead ? ` (${isRTL ? "على الاتجاه" : "along"} ${formatKm(Math.max(0, r.alongM), isRTL)})` : ""}
							</span>
						</div>
						<div className="sary-o-row">
							<button type="button" className="sary-o-primary" disabled={busy} onClick={() => onShare(shareLine(r, isRTL, formatKm))} data-testid="outing-nearest-share">
								{isRTL ? "أرسلها للمجموعة" : "Send to group"}
							</button>
							<a className="sary-o-secondary sary-o-linkbtn" href={directionsUrl(r)} target="_blank" rel="noopener noreferrer">
								<Navigation className="size-4" aria-hidden />
								{isRTL ? "اتجه" : "Go"}
							</a>
						</div>
					</li>
				);
			})}
		</ul>
	);
}
