import { evidenceLabel, formatKm, kindLabel, type OutdoorEntity } from "../../lib/sary/domain";
import { SaryPlaceActions } from "./SaryPlaceSheet";

export default function SaryRouteSheet({
	route,
	nearby,
	isRTL,
	distanceFromMeM,
	onShowOnMap,
}: {
	route: OutdoorEntity;
	nearby: OutdoorEntity[];
	isRTL: boolean;
	distanceFromMeM?: number | null;
	onShowOnMap?: () => void;
}) {
	const length = route.lengthM ?? null;
	const source =
		route.source === "osm"
			? isRTL ? "بيانات عامة من OpenStreetMap" : "Public data from OpenStreetMap"
			: isRTL ? "مسار GPS" : "GPS track";
	return (
		<div className="sary-detail" data-testid="sary-route-sheet">
			<p className="sary-kicker">{kindLabel(route.kind, isRTL)}</p>
			<h2>{route.name || (isRTL ? "مسار بلا اسم" : "Unnamed track")}</h2>
			{length != null ? (
				<p className="sary-meta">
					{isRTL ? "طول المسار" : "Length"}: {formatKm(length, isRTL)}
				</p>
			) : null}
			{distanceFromMeM != null ? (
				<p className="sary-meta" data-testid="sary-place-distance">
					{isRTL ? `يبعد عنك ${formatKm(distanceFromMeM, true)}` : `${formatKm(distanceFromMeM, false)} from you`}
				</p>
			) : null}
			<SaryPlaceActions place={route} isRTL={isRTL} onShowOnMap={onShowOnMap} />
			<p className="sary-meta">
				{isRTL ? "المصدر" : "Source"}: {source}
			</p>
			<p className="sary-evidence">{evidenceLabel(route.evidence, isRTL)}</p>
			{nearby.length ? (
				<>
					<h3>{isRTL ? "أماكن قريبة" : "Nearby"}</h3>
					<ul>
						{nearby.slice(0, 4).map((e) => (
							<li key={e.id}>
								{e.name || kindLabel(e.kind, isRTL)}
								{e.distanceM != null ? ` — ${formatKm(e.distanceM, isRTL)}` : ""}
							</li>
						))}
					</ul>
				</>
			) : null}
		</div>
	);
}
