import { evidenceLabel, formatKm, kindLabel, type OutdoorEntity } from "../../lib/sary/domain";

export default function SaryPlaceSheet({
	place,
	nearby,
	isRTL,
}: {
	place: OutdoorEntity;
	nearby: OutdoorEntity[];
	isRTL: boolean;
}) {
	const well = nearby.find((e) => e.kind === "well");
	const shaib = nearby.find((e) => e.kind === "shaib" || e.kind === "wadi");
	const track = nearby.find((e) => e.group === "movement");

	return (
		<div className="sary-detail" data-testid="sary-place-sheet">
			<p className="sary-kicker">{kindLabel(place.kind, isRTL)}</p>
			<h2>{place.name || (isRTL ? "غير مؤكد" : "Unconfirmed")}</h2>
			<p className="sary-meta">
				{formatKm(place.distanceM, isRTL)}
				{place.distanceM != null ? (isRTL ? " منك" : " away") : ""}
			</p>
			<h3>{isRTL ? "حول المكان" : "Around this place"}</h3>
			<ul>
				<li>
					{isRTL ? "المسارات" : "Tracks"}:{" "}
					{track ? track.name || kindLabel(track.kind, isRTL) : isRTL ? "غير مؤكد" : "Unconfirmed"}
				</li>
				<li>
					{isRTL ? "أقرب بئر" : "Nearest well"}:{" "}
					{well ? well.name || kindLabel("well", isRTL) : isRTL ? "غير مؤكد" : "Unconfirmed"}
				</li>
				<li>
					{isRTL ? "أقرب شعيب" : "Nearest shaib"}:{" "}
					{shaib ? shaib.name || kindLabel(shaib.kind, isRTL) : isRTL ? "غير مؤكد" : "Unconfirmed"}
				</li>
				<li>
					{isRTL ? "آخر Track معروف" : "Last known track"}:{" "}
					{track ? evidenceLabel(track.evidence, isRTL) : isRTL ? "غير مؤكد" : "Unconfirmed"}
				</li>
			</ul>
			<p className="sary-evidence">{evidenceLabel(place.evidence, isRTL)}</p>
		</div>
	);
}
