import { useNavigate, useRouterState } from "@tanstack/react-router";
import { lazy, Suspense, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useLanguage } from "../../contexts/LanguageContext";
import { useLocation } from "../../contexts/LocationContext";
import { track } from "../../lib/farqAnalytics";
import { encodeCameraBbox, mapStayPath, parseCameraBbox, type MapSearch, type OutdoorLayerId } from "../../routes/map";
import {
	formatDuration,
	formatKm,
	haversineMeters,
	isWeakGps,
	kindLabel,
} from "../../lib/sary/domain";
import { aroundLines, summarizeAround } from "../../lib/sary/aroundYou";
import {
	appendTripPoint,
	emptyTrip,
	tripDurationMs,
	tripLine,
	tripIsMoving,
	tripStartEnd,
	type TripRecord,
} from "../../lib/sary/trip";
import { listTrips, loadTrip, saveTrip } from "../../lib/sary/tripStore";
import {
	featureToEntity,
	OutdoorService,
	type OutdoorFeatureCollection,
} from "../../services/outdoorService";
import { shouldOfferSearchHere } from "../../lib/farqMapViewport";
import type { IntelligenceMapPlaces } from "../../services/intelligenceService";
import type { SheetSnap } from "../intelligence/FarqBottomSheet";
import { sheetHeightPx } from "../intelligence/FarqBottomSheet";
import SaryExploreChrome from "./SaryExploreChrome";
import SaryPlaceSheet from "./SaryPlaceSheet";
import SaryRouteSheet from "./SaryRouteSheet";
import "../../styles/sary-map.css";

const FarqMap = lazy(() => import("../intelligence/FarqMap"));

type Phase =
	| "permission"
	| "loading"
	| "explore"
	| "search"
	| "place"
	| "route"
	| "start"
	| "tracking"
	| "weak"
	| "paused"
	| "finish"
	| "saved"
	| "trips"
	| "trip"
	| "empty"
	| "error";

function splitFc(fc: OutdoorFeatureCollection | null): {
	places: GeoJSON.FeatureCollection;
	tracks: GeoJSON.FeatureCollection;
	entities: ReturnType<typeof featureToEntity>[];
} {
	const places: GeoJSON.Feature[] = [];
	const tracks: GeoJSON.Feature[] = [];
	const entities = [];
	for (const f of fc?.features || []) {
		entities.push(featureToEntity(f));
		if (f.geometry.type === "LineString" || f.geometry.type === "MultiLineString") {
			tracks.push(f as GeoJSON.Feature);
		} else {
			places.push(f as GeoJSON.Feature);
		}
	}
	return {
		places: { type: "FeatureCollection", features: places },
		tracks: { type: "FeatureCollection", features: tracks },
		entities,
	};
}

export default function SaryMapSplit({ search }: { search: MapSearch }) {
	const { language, toggleLanguage } = useLanguage();
	const isRTL = language === "ar";
	const navigate = useNavigate();
	const pathname = useRouterState({ select: (s) => s.location.pathname });
	const {
		userLocation,
		userAccuracy,
		userHeading,
		hasLocationPermission,
		locationError,
		isLocating,
		requestLocation,
		dismissError,
	} = useLocation();

	const [features, setFeatures] = useState<OutdoorFeatureCollection | null>(null);
	const [error, setError] = useState<string | null>(null);
	const [query, setQuery] = useState(search.q || "");
	const [layer, setLayer] = useState<OutdoorLayerId>(search.layer || "around");
	const [sheetSnap, setSheetSnap] = useState<SheetSnap>("half");
	const [selectedId, setSelectedId] = useState(search.place || "");
	const [phase, setPhase] = useState<Phase>(
		hasLocationPermission ? "loading" : "permission",
	);
	const [followMode, setFollowMode] = useState(false);
	const [leftUser, setLeftUser] = useState(false);
	const [trip, setTrip] = useState<TripRecord | null>(null);
	const [savedTrips, setSavedTrips] = useState<TripRecord[]>([]);
	const [pauseStarted, setPauseStarted] = useState<number | null>(null);
	const [now, setNow] = useState(Date.now());
	const viewRef = useRef<{ bbox: string; zoom: number } | null>(null);
	const fetchedRef = useRef<string>("");
	const lastTickRef = useRef(0);

	const [initialCamera] = useState(() => {
		const b = parseCameraBbox(search.b);
		return b && typeof search.z === "number"
			? { center: [(b[0] + b[2]) / 2, (b[1] + b[3]) / 2] as [number, number], zoom: search.z }
			: null;
	});

	const patchSearch = useCallback(
		(next: Partial<MapSearch>) => {
			void navigate({
				to: mapStayPath(pathname),
				search: (prev: MapSearch) => ({ ...prev, ...next }),
			});
		},
		[navigate, pathname],
	);

	const writeCameraToUrl = useCallback(
		(bbox: [number, number, number, number], zoom: number) => {
			const b = encodeCameraBbox(bbox);
			const z = Math.round(zoom * 100) / 100;
			void navigate({
				to: mapStayPath(pathname),
				replace: true,
				search: (prev: MapSearch) => (prev.b === b && prev.z === z ? prev : { ...prev, b, z }),
			});
		},
		[navigate, pathname],
	);

	const loadViewport = useCallback(
		async (bbox: string, zoom: number) => {
			const key = `${bbox}|${zoom}|${layer}`;
			if (fetchedRef.current === key) return;
			fetchedRef.current = key;
			try {
				const types =
					layer === "tracks" ? "movement" : layer === "places" ? "place,nature" : undefined;
				const data = await OutdoorService.features({ bbox, zoom, types });
				setFeatures(data);
				setError(null);
				setPhase((p) => {
					if (p === "loading" || p === "permission") return "explore";
					if (!data.features.length && (p === "explore" || p === "empty")) return "empty";
					if (data.features.length && p === "empty") return "explore";
					return p;
				});
			} catch {
				setError(isRTL ? "تعذر تحميل بيانات البر." : "Outdoor data failed to load.");
				setPhase("error");
				track("outdoor_data_fail", { source: "viewport" });
			}
		},
		[isRTL, layer],
	);

	useEffect(() => {
		if (hasLocationPermission && phase === "permission") {
			setPhase("loading");
			if (!userLocation) requestLocation();
		}
	}, [hasLocationPermission, phase, requestLocation, userLocation]);

	useEffect(() => {
		if (locationError) track("gps_error", { source: "geo" });
	}, [locationError]);

	useEffect(() => {
		fetchedRef.current = "";
		if (layer !== "trips" && viewRef.current) {
			void loadViewport(viewRef.current.bbox, viewRef.current.zoom);
		}
	}, [layer, loadViewport]);

	useEffect(() => {
		if (phase !== "tracking" && phase !== "weak") return;
		const t = window.setInterval(() => setNow(Date.now()), 1000);
		return () => window.clearInterval(t);
	}, [phase]);

	useEffect(() => {
		if (!trip || trip.status !== "recording" || !userLocation) return;
		const t = Date.now();
		if (t - lastTickRef.current < 900) return;
		lastTickRef.current = t;
		setTrip((prev) =>
			prev
				? appendTripPoint(prev, {
						lng: userLocation.lng,
						lat: userLocation.lat,
						at: t,
						accuracy: userAccuracy,
						heading: userHeading,
					})
				: prev,
		);
	}, [trip, userLocation, userAccuracy, userHeading]);

	useEffect(() => {
		if (trip?.status === "recording" && isWeakGps(userAccuracy) && phase === "tracking") {
			setPhase("weak");
		}
	}, [trip, userAccuracy, phase]);

	const split = useMemo(() => splitFc(features), [features]);
	const selected = split.entities.find((e) => e.id === selectedId) || null;
	const nearby = useMemo(() => {
		if (!selected) return [];
		return split.entities
			.filter((e) => e.id !== selected.id)
			.map((e) => ({ ...e, distanceM: haversineMeters(selected, e) }))
			.sort((a, b) => (a.distanceM ?? 0) - (b.distanceM ?? 0))
			.slice(0, 8);
	}, [selected, split.entities]);

	const around = useMemo(
		() => summarizeAround(split.entities, userLocation, 15_000),
		[split.entities, userLocation],
	);

	const myTrack = useMemo(() => {
		const line = trip ? tripLine(trip) : null;
		return {
			type: "FeatureCollection" as const,
			features: line ? [line] : [],
		};
	}, [trip]);

	const [focusRequest, setFocusRequest] = useState<{
		lat: number;
		lng: number;
		id: string;
		zoom?: number;
		kind?: "select" | "locate";
	} | null>(null);

	const locate = () => {
		track("locate_click", { source: "sary" });
		track("gps_start", { source: "sary" });
		requestLocation();
		if (userLocation) {
			setFocusRequest({
				lat: userLocation.lat,
				lng: userLocation.lng,
				id: `locate-${Date.now()}`,
				kind: "locate",
				zoom: 14.2,
			});
			setFollowMode(true);
			setLeftUser(false);
		}
	};

	const startTrip = () => {
		if (!userLocation) {
			setPhase("permission");
			requestLocation();
			return;
		}
		track("gps_start", { source: "trip" });
		const next = emptyTrip();
		setTrip(appendTripPoint(next, { lng: userLocation.lng, lat: userLocation.lat, at: Date.now(), accuracy: userAccuracy, heading: userHeading }));
		setPhase("tracking");
		setFollowMode(true);
		setSheetSnap("peek");
	};

	const pauseTrip = () => {
		if (!trip) return;
		setTrip({ ...trip, status: "paused" });
		setPauseStarted(Date.now());
		setPhase("paused");
	};

	const resumeTrip = () => {
		if (!trip) return;
		const extra = pauseStarted ? Date.now() - pauseStarted : 0;
		setPauseStarted(null);
		setTrip({ ...trip, status: "recording", pausedMs: trip.pausedMs + extra });
		setPhase("tracking");
		setFollowMode(true);
	};

	const stopTrip = () => {
		if (!trip) return;
		track("gps_stop", { source: "trip" });
		setTrip({ ...trip, status: "finished", endedAt: Date.now() });
		setPhase("finish");
		setFollowMode(false);
		setSheetSnap("half");
	};

	const persistTrip = async () => {
		if (!trip) return;
		try {
			const named: TripRecord = {
				...trip,
				status: "finished",
				endedAt: trip.endedAt || Date.now(),
				name: trip.name || (isRTL ? "طلعة" : "Trip"),
			};
			await saveTrip(named);
			setTrip(named);
			setPhase("saved");
			const all = await listTrips();
			setSavedTrips(all);
		} catch {
			track("trip_save_fail", { source: "idb" });
			setError(isRTL ? "تعذر حفظ الطلعة على هذا الجهاز." : "Could not save the trip on this device.");
		}
	};

	const openTrips = async () => {
		setLayer("trips");
		setPhase("trips");
		setSheetSnap("half");
		try {
			setSavedTrips(await listTrips());
		} catch {
			setSavedTrips([]);
		}
	};

	const openSaved = async (id: string) => {
		const row = await loadTrip(id);
		if (!row) return;
		setTrip(row);
		setPhase("trip");
		patchSearch({ trip: id });
	};

	const onSelect = (id: string) => {
		setSelectedId(id);
		const ent = split.entities.find((e) => e.id === id);
		if (!ent) return;
		setFocusRequest({ lat: ent.lat, lng: ent.lng, id: `sel-${id}`, kind: "select", zoom: 13.6 });
		setPhase(ent.group === "movement" ? "route" : "place");
		setSheetSnap("half");
		patchSearch({ place: id });
		track("place_select", { source: "sary" });
	};

	const cta =
		phase === "permission"
			? isRTL ? "السماح" : "Allow"
			: phase === "place" || phase === "route"
				? isRTL ? "اذهب إليها" : "Go there"
				: phase === "start" || phase === "explore" || phase === "empty"
					? isRTL ? "سجّل طلعتك" : "Record your trip"
					: phase === "tracking" || phase === "weak"
						? isRTL ? "إيقاف" : "Stop"
						: phase === "paused"
							? isRTL ? "استئناف" : "Resume"
							: phase === "finish"
								? isRTL ? "حفظ الطلعة" : "Save trip"
								: phase === "saved"
									? isRTL ? "طلعاتي" : "My trips"
									: phase === "error"
										? isRTL ? "إعادة المحاولة" : "Retry"
										: undefined;

	const onCta = () => {
		if (phase === "permission") {
			requestLocation();
			setPhase("loading");
			return;
		}
		if (phase === "place" || phase === "route") {
			if (selected) {
				setFocusRequest({
					lat: selected.lat,
					lng: selected.lng,
					id: `go-${selected.id}`,
					kind: "locate",
					zoom: 14,
				});
			}
			setPhase("start");
			return;
		}
		if (phase === "start" || phase === "explore" || phase === "empty") {
			startTrip();
			return;
		}
		if (phase === "tracking" || phase === "weak") {
			stopTrip();
			return;
		}
		if (phase === "paused") {
			resumeTrip();
			return;
		}
		if (phase === "finish") {
			void persistTrip();
			return;
		}
		if (phase === "saved") {
			void openTrips();
			return;
		}
		if (phase === "error") {
			setPhase("loading");
			fetchedRef.current = "";
			if (viewRef.current) void loadViewport(viewRef.current.bbox, viewRef.current.zoom);
		}
	};

	const header = (() => {
		if (phase === "permission") return isRTL ? "نحتاج موقعك لنعرف ما حولك" : "Location is needed to describe what is around you";
		if (phase === "loading") return isRTL ? "نحدد موقعك…" : "Finding you…";
		if (phase === "search") return isRTL ? "نتائج البحث" : "Search";
		if (phase === "tracking") return isRTL ? "جاري تسجيل الطلعة" : "Recording";
		if (phase === "weak") return isRTL ? "إشارة GPS ضعيفة" : "Weak GPS";
		if (phase === "paused") return isRTL ? "التسجيل متوقف" : "Paused";
		if (phase === "finish") return isRTL ? "خلصت الطلعة" : "Trip finished";
		if (phase === "saved") return isRTL ? "تم حفظ الطلعة" : "Trip saved";
		if (phase === "trips") return isRTL ? "طلعاتي" : "My trips";
		if (phase === "empty") return isRTL ? "لا توجد معالم مرصودة هنا" : "No observed features here";
		if (phase === "error") return error || (isRTL ? "تعذر التحميل" : "Could not load");
		if (layer === "around") return isRTL ? "حولك الآن" : "Around you";
		if (layer === "tracks") return isRTL ? "المسارات" : "Tracks";
		if (layer === "places") return isRTL ? "المعالم" : "Places";
		return isRTL ? "طلعاتي" : "My trips";
	})();

	const ends = trip ? tripStartEnd(trip) : { start: null, end: null };

	return (
		<div className="sary-split farq-map-split" data-testid="sary-map-split" dir={isRTL ? "rtl" : "ltr"}>
			<div className="sary-map-pane">
				<Suspense fallback={<div className="sary-map-fallback" />}>
					<FarqMap
						mode="outdoor"
						basemap="satellite"
						places={{
							type: "FeatureCollection",
							count: split.places.features.length,
							matched: split.places.features.length,
							layer: "outdoor",
							features: split.places.features,
						} as IntelligenceMapPlaces}
						neighborhoods={null}
						tracks={split.tracks}
						userTrack={myTrack}
						selectedPlaceId={selectedId}
						onSelectPlace={onSelect}
						onSelectNeighborhood={() => undefined}
						userLocation={userLocation}
						userHeading={userHeading}
						showUserLocation={Boolean(userLocation)}
						vehicleMode={phase === "tracking" || phase === "weak" || phase === "paused" || phase === "trip" ? "prado" : "dot"}
						vehicleMotion={tripIsMoving(trip, now) ? "moving" : "idle"}
						followMode={followMode}
						onBreakFollow={() => setFollowMode(false)}
						onLeftUserLocation={setLeftUser}
						outdoorLayer={layer}
						isRTL={isRTL}
						hideAddressSearch
						sheetOpen={sheetSnap !== "peek"}
						bottomInset={sheetHeightPx(sheetSnap, typeof window === "undefined" ? 800 : window.innerHeight)}
						initialCamera={initialCamera}
						focusRequest={focusRequest}
						onViewChange={(bbox, zoom, meta) => {
							viewRef.current = { bbox, zoom };
							const box = bbox.split(",").map(Number);
							if (box.length === 4 && box.every(Number.isFinite)) {
								writeCameraToUrl([box[0], box[1], box[2], box[3]], zoom);
							}
							const first = !fetchedRef.current;
							const fetchedBbox = fetchedRef.current.split("|")[0] || null;
							const moved = shouldOfferSearchHere({
								userGesture: Boolean(meta?.userGesture),
								hasFetched: Boolean(fetchedBbox),
								fetched: fetchedBbox ? { bbox: fetchedBbox, zoom } : null,
								current: { bbox, zoom },
							});
							if (first || moved) void loadViewport(bbox, zoom);
						}}
					/>
				</Suspense>
				<SaryExploreChrome
					isRTL={isRTL}
					query={query}
					onQueryChange={setQuery}
					onSearchSubmit={() => {
						setPhase("search");
						patchSearch({ q: query || undefined });
						if (query.trim().length >= 2) {
							void OutdoorService.search(query)
								.then((data) => {
									setFeatures(data);
									if (!data.features.length) setPhase("empty");
								})
								.catch(() => setPhase("error"));
						}
					}}
					layer={layer}
					onLayer={(next) => {
						setLayer(next);
						patchSearch({ layer: next });
						if (next === "trips") void openTrips();
						else setPhase("explore");
					}}
					sheetSnap={sheetSnap}
					onSheetSnap={setSheetSnap}
					header={header}
					cta={cta}
					onCta={onCta}
					onLocate={locate}
					onRecenter={() => {
						setFollowMode(true);
						locate();
					}}
					showRecenter={leftUser && Boolean(userLocation)}
					locating={isLocating}
				>
					{phase === "permission" ? (
						<p>{isRTL ? "بدون موقع حقيقي لا نلخّص ما حولك، ولا نختلق نقطة." : "Without a real fix we will not invent what is around you."}</p>
					) : null}
					{phase === "loading" ? <p>{isRTL ? "لحظات…" : "A moment…"}</p> : null}
					{phase === "explore" || phase === "search" ? (
						<ul className="sary-around" data-testid="sary-around">
							{aroundLines(around, isRTL).map((line) => (
								<li key={line}>{line}</li>
							))}
							{!aroundLines(around, isRTL).length ? (
								<li>{isRTL ? "حرّك الخريطة أو اسمح بالموقع لرؤية ما هو مرصود." : "Pan or allow location to see observed features."}</li>
							) : null}
						</ul>
					) : null}
					{phase === "place" && selected ? <SaryPlaceSheet place={selected} nearby={nearby} isRTL={isRTL} /> : null}
					{phase === "route" && selected ? <SaryRouteSheet route={selected} nearby={nearby} isRTL={isRTL} /> : null}
					{phase === "start" ? (
						<p>{isRTL ? "سيُرسم خط GPS حقيقي خلفك. لا حركة وهمية." : "A real GPS line will grow behind you. No fake movement."}</p>
					) : null}
					{phase === "tracking" || phase === "weak" || phase === "paused" ? (
						<div className="sary-trip-hud" data-testid="sary-trip-hud">
							<p>{formatKm(trip?.distanceM ?? 0, isRTL)}</p>
							<p>{formatDuration(trip ? tripDurationMs(trip, now) : 0, isRTL)}</p>
							{phase === "weak" ? <p>{isRTL ? "الإشارة ضعيفة — لم نختلق موقعًا." : "Weak signal — no invented fix."}</p> : null}
							{phase === "paused" ? (
								<button type="button" onClick={stopTrip}>
									{isRTL ? "إنهاء" : "End"}
								</button>
							) : (
								<button type="button" onClick={pauseTrip}>
									{isRTL ? "إيقاف مؤقت" : "Pause"}
								</button>
							)}
						</div>
					) : null}
					{phase === "finish" || phase === "saved" || phase === "trip" ? (
						<div className="sary-trip-done" data-testid="sary-trip-done">
							<p>{formatKm(trip?.distanceM ?? 0, isRTL)}</p>
							<p>{formatDuration(trip ? tripDurationMs(trip) : 0, isRTL)}</p>
							<p>
								{isRTL ? "البداية" : "Start"}:{" "}
								{ends.start ? `${ends.start.lat.toFixed(4)}, ${ends.start.lng.toFixed(4)}` : isRTL ? "غير مؤكد" : "Unconfirmed"}
							</p>
							<p>
								{isRTL ? "النهاية" : "End"}:{" "}
								{ends.end ? `${ends.end.lat.toFixed(4)}, ${ends.end.lng.toFixed(4)}` : isRTL ? "غير مؤكد" : "Unconfirmed"}
							</p>
						</div>
					) : null}
					{phase === "trips" ? (
						<ul className="sary-trips" data-testid="sary-trips">
							{savedTrips.map((row) => (
								<li key={row.id}>
									<button type="button" onClick={() => void openSaved(row.id)}>
										<strong>{row.name || (isRTL ? "طلعة" : "Trip")}</strong>
										<span>
											{new Date(row.startedAt).toLocaleDateString(isRTL ? "ar-SA" : "en")} ·{" "}
											{formatKm(row.distanceM, isRTL)}
										</span>
									</button>
								</li>
							))}
							{!savedTrips.length ? <li>{isRTL ? "لا طلعات محفوظة بعد." : "No saved trips yet."}</li> : null}
						</ul>
					) : null}
					{phase === "empty" ? (
						<p>{isRTL ? "سجّل طلعتك ليظهر أثرك. لا نرسم مسارات مخترعة." : "Record a trip to leave a track. We will not draw invented routes."}</p>
					) : null}
					{locationError ? (
						<p className="sary-error">
							{locationError}{" "}
							<button type="button" onClick={dismissError}>
								{isRTL ? "حسنًا" : "OK"}
							</button>
						</p>
					) : null}
				</SaryExploreChrome>
			</div>
			<aside className="sary-desktop-panel hidden lg:block">
				<button type="button" className="sary-lang" onClick={toggleLanguage}>
					{isRTL ? "EN" : "عربي"}
				</button>
				<h1>{isRTL ? "سَرى البارق" : "Sary Albarq"}</h1>
				<p>{isRTL ? "خريطة سعودية تستكشف بها البر." : "A Saudi map for exploring the land."}</p>
				{selected ? (
					<p>
						{selected.name || kindLabel(selected.kind, isRTL)}
					</p>
				) : (
					<ul>
						{aroundLines(around, isRTL).map((line) => (
							<li key={line}>{line}</li>
						))}
					</ul>
				)}
			</aside>
		</div>
	);
}
