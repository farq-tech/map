import { directionsUrl, evidenceLabel, formatKm, kindLabel, type OutdoorEntity } from "../../lib/sary/domain";

/**
 * One place. Only what we actually know is listed: an unknown row is dropped
 * rather than repeated as «غير مؤكد», and the distance is from a real GPS fix.
 */
export default function SaryPlaceSheet({
	place,
	nearby,
	isRTL,
	distanceFromMeM,
	onShowOnMap,
}: {
	place: OutdoorEntity;
	nearby: OutdoorEntity[];
	isRTL: boolean;
	/** From the person's real GPS fix; null when there is none. */
	distanceFromMeM?: number | null;
	onShowOnMap?: () => void;
}) {
	const well = nearby.find((e) => e.kind === "well");
	const shaib = nearby.find((e) => e.kind === "shaib" || e.kind === "wadi");
	const track = nearby.find((e) => e.group === "movement");
	const rows: Array<{ label: string; e: OutdoorEntity }> = [];
	if (track) rows.push({ label: isRTL ? "أقرب مسار" : "Nearest track", e: track });
	if (well) rows.push({ label: isRTL ? "أقرب قليب" : "Nearest well", e: well });
	if (shaib) rows.push({ label: isRTL ? "أقرب شعيب" : "Nearest shaib", e: shaib });

	return (
		<div className="sary-detail" data-testid="sary-place-sheet">
			<p className="sary-kicker">{kindLabel(place.kind, isRTL)}</p>
			<h2>{place.name || kindLabel(place.kind, isRTL)}</h2>
			{distanceFromMeM != null ? (
				<p className="sary-meta" data-testid="sary-place-distance">
					{isRTL ? `يبعد عنك ${formatKm(distanceFromMeM, true)}` : `${formatKm(distanceFromMeM, false)} from you`}
				</p>
			) : null}
			<SaryPlaceActions place={place} isRTL={isRTL} onShowOnMap={onShowOnMap} />
			<h3>{isRTL ? "حول المكان" : "Around this place"}</h3>
			{rows.length ? (
				<ul>
					{rows.map((r) => (
						<li key={r.label}>
							{r.label}: {r.e.name || kindLabel(r.e.kind, isRTL)}
							{r.e.distanceM != null ? ` — ${formatKm(r.e.distanceM, isRTL)}` : ""}
						</li>
					))}
				</ul>
			) : (
				<p className="sary-meta">{isRTL ? "لا نعرف بعد ما حول هذا المكان في البيانات العامة." : "Public data does not describe what is around this place yet."}</p>
			)}
			<p className="sary-evidence">{evidenceLabel(place.evidence, isRTL)}</p>
		</div>
	);
}

/** «اعرضها على الخريطة» moves our camera; «اتجه إليها» hands real coordinates to the phone's navigation app. */
export function SaryPlaceActions({
	place,
	isRTL,
	onShowOnMap,
}: {
	place: Pick<OutdoorEntity, "lat" | "lng">;
	isRTL: boolean;
	onShowOnMap?: () => void;
}) {
	return (
		<div className="sary-actions">
			{onShowOnMap ? (
				<button type="button" className="sary-action" onClick={onShowOnMap} data-testid="sary-show-on-map">
					{isRTL ? "اعرضها على الخريطة" : "Show on map"}
				</button>
			) : null}
			<a
				className="sary-action is-primary"
				href={directionsUrl(place)}
				target="_blank"
				rel="noopener noreferrer"
				data-testid="sary-directions"
			>
				{isRTL ? "اتجه إليها" : "Directions"}
			</a>
		</div>
	);
}
