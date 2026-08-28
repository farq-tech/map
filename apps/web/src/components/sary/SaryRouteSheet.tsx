import { evidenceLabel, formatKm, kindLabel, type OutdoorEntity } from "../../lib/sary/domain";

export default function SaryRouteSheet({
	route,
	nearby,
	isRTL,
}: {
	route: OutdoorEntity;
	nearby: OutdoorEntity[];
	isRTL: boolean;
}) {
	return (
		<div className="sary-detail" data-testid="sary-route-sheet">
			<p className="sary-kicker">{kindLabel(route.kind, isRTL)}</p>
			<h2>{route.name || (isRTL ? "مسار بلا اسم" : "Unnamed track")}</h2>
			<p className="sary-meta">
				{isRTL ? "المسافة" : "Distance"}: {formatKm(route.lengthM ?? route.distanceM, isRTL)}
			</p>
			<p>
				{isRTL ? "المصدر" : "Source"}: {route.source === "osm" ? "OpenStreetMap" : "GPS"}
			</p>
			<p className="sary-evidence">{evidenceLabel(route.evidence, isRTL)}</p>
			<h3>{isRTL ? "أماكن قريبة" : "Nearby"}</h3>
			<ul>
				{nearby.slice(0, 4).map((e) => (
					<li key={e.id}>
						{e.name || kindLabel(e.kind, isRTL)} — {formatKm(e.distanceM, isRTL)}
					</li>
				))}
				{nearby.length === 0 ? <li>{isRTL ? "غير مؤكد" : "Unconfirmed"}</li> : null}
			</ul>
		</div>
	);
}
