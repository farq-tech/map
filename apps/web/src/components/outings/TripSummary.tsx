import { useEffect, useRef, useState } from "react";
import { useLocation } from "../../contexts/LocationContext";
import { OutingApiError, OutingsApi, outingErrorText, type SharedSummary } from "../../lib/outings/api";
import { addFix, totals, type TripState } from "../../lib/outings/trip";
import { clearTrip, loadTrip, saveTrip } from "../../lib/outings/tripStore";
import { formatDuration, formatKm } from "../../lib/sary/domain";

/**
 * Adds this device's own GPS fixes to its running totals while the outing is
 * active. Runs whether or not location sharing is on: the totals stay on the
 * phone unless the person later taps «شارك ملخصي».
 */
export function useMyTrip(outingId: string, recording: boolean) {
	const { userLocation, userAccuracy, userHeading, userSpeed, userFixAt, locationPinKind } = useLocation();
	const tripRef = useRef<TripState>(loadTrip(outingId));
	useEffect(() => {
		tripRef.current = loadTrip(outingId);
	}, [outingId]);
	useEffect(() => {
		if (!recording || locationPinKind !== "gps" || !userLocation || userFixAt == null) return;
		const next = addFix(tripRef.current, { lat: userLocation.lat, lng: userLocation.lng, accuracy: userAccuracy, heading: userHeading, speed: userSpeed, at: userFixAt });
		if (next === tripRef.current) return;
		tripRef.current = next;
		/* ~150 bytes per accepted fix: saved at once, so the end-of-outing card never misses the last stretch. */
		saveTrip(outingId, next);
	}, [recording, locationPinKind, userLocation, userAccuracy, userHeading, userSpeed, userFixAt, outingId]);
	useEffect(() => {
		if (!recording) return;
		const flush = () => saveTrip(outingId, tripRef.current);
		window.addEventListener("pagehide", flush);
		return () => {
			window.removeEventListener("pagehide", flush);
			if (tripRef.current.firstAt != null) flush();
		};
	}, [recording, outingId]);
}

export function SummaryList({ rows, isRTL, meId }: { rows: SharedSummary[]; isRTL: boolean; meId?: string }) {
	if (!rows.length) return null;
	return (
		<ul className="sary-o-summaries" data-testid="outing-summaries">
			{rows.map((r) => (
				<li key={r.user_id} data-user={r.user_id}>
					<strong>{r.user_id === meId ? (isRTL ? "أنت" : "You") : r.display_name}</strong>
					<span>
						{formatKm(r.distance_m, isRTL)} · {formatDuration(r.duration_s * 1000, isRTL)}
						{r.moving_s < r.duration_s ? ` (${isRTL ? "حركة" : "moving"} ${formatDuration(r.moving_s * 1000, isRTL)})` : ""}
					</span>
				</li>
			))}
		</ul>
	);
}

/**
 * At the end: your own totals, shown only to you, with an explicit choice.
 * Sharing sends three numbers — never a point.
 */
export function TripSummaryCard({ outingId, isRTL, meId }: { outingId: string; isRTL: boolean; meId?: string }) {
	const [trip] = useState(() => loadTrip(outingId));
	const mine = totals(trip);
	const [shared, setShared] = useState<SharedSummary[] | null>(null);
	const [busy, setBusy] = useState(false);
	const [error, setError] = useState<string | null>(null);
	const [done, setDone] = useState<"shared" | "dismissed" | null>(null);

	useEffect(() => {
		let off = false;
		OutingsApi.get(outingId).then(
			(s) => !off && setShared(s.summaries || []),
			() => !off && setShared([]),
		);
		return () => {
			off = true;
		};
	}, [outingId, done]);

	const already = shared?.some((s) => s.user_id === meId);
	const hasTrip = trip.firstAt != null;

	const share = async () => {
		setBusy(true);
		setError(null);
		try {
			await OutingsApi.shareSummary(outingId, mine);
			clearTrip(outingId);
			setDone("shared");
		} catch (e) {
			setError(outingErrorText(e instanceof OutingApiError ? e.code : "network", isRTL));
		} finally {
			setBusy(false);
		}
	};

	return (
		<div className="sary-o-trip" data-testid="outing-trip-summary">
			{hasTrip && !done && !already ? (
				<>
					<h3>{isRTL ? "ملخص طلعتك" : "Your trip"}</h3>
					<p className="sary-o-trip-big" data-testid="outing-trip-mine">
						{formatKm(mine.distance_m, isRTL)} · {formatDuration(mine.duration_s * 1000, isRTL)}
					</p>
					<p className="sary-o-note">
						{isRTL
							? "حُسب على جوالك من مواقعك أنت فقط، ولا يراه أحد إلا إذا شاركته. نرسل المجموع فقط — لا مسار ولا نقاط."
							: "Worked out on your phone from your own fixes; nobody sees it unless you share. Only the totals are sent — no route, no points."}
					</p>
					{error ? <p className="sary-o-error" role="alert">{error}</p> : null}
					<div className="sary-o-row">
						<button type="button" className="sary-o-primary" disabled={busy} onClick={() => void share()} data-testid="outing-trip-share">
							{isRTL ? "شارك ملخصي" : "Share my summary"}
						</button>
						<button
							type="button"
							className="sary-o-secondary"
							disabled={busy}
							onClick={() => {
								clearTrip(outingId);
								setDone("dismissed");
							}}
							data-testid="outing-trip-dismiss"
						>
							{isRTL ? "لا، احذفه" : "No, delete it"}
						</button>
					</div>
				</>
			) : done === "shared" ? (
				<p className="sary-o-note" role="status">{isRTL ? "شاركت ملخصك مع أصحاب الطلعة ✓" : "You shared your summary ✓"}</p>
			) : null}
			{shared?.length ? (
				<>
					<h3>{isRTL ? "ملخصات شاركها أصحابها" : "Shared by their owners"}</h3>
					<SummaryList rows={shared} isRTL={isRTL} meId={meId} />
				</>
			) : null}
		</div>
	);
}
