import { useNavigate, useRouterState } from "@tanstack/react-router";
import { lazy, Suspense, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useLanguage } from "../../contexts/LanguageContext";
import { useLocation } from "../../contexts/LocationContext";
import { track } from "../../lib/farqAnalytics";
import { encodeCameraBbox, mapStayPath, parseCameraBbox, type MapSearch, type OutdoorLayerId } from "../../routes/map";
import {
	formatDate,
	formatDuration,
	formatKm,
	formatNumber,
	formatTime,
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
import type { Map as MapboxMap } from "mapbox-gl";
import "../../styles/sary-map.css";

const FarqMap = lazy(() => import("../intelligence/FarqMap"));
const OfflineAreaSheet = lazy(() => import("./OfflineAreaSheet"));

/** navigator.onLine, live. */
function useOnline(): boolean {
	const [online, setOnline] = useState(() => (typeof navigator === "undefined" ? true : navigator.onLine));
	useEffect(() => {
		const on = () => setOnline(true);
		const off = () => setOnline(false);
		window.addEventListener("online", on);
		window.addEventListener("offline", off);
		return () => {
			window.removeEventListener("online", on);
			window.removeEventListener("offline", off);
		};
	}, []);
	return online;
}

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
		userSpeed,
		locationPinKind,
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
	const [mapInstance, setMapInstance] = useState<MapboxMap | null>(null);
	const [offlineOpen, setOfflineOpen] = useState(false);
	const online = useOnline();
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
	const [searchHint, setSearchHint] = useState<string | null>(null);
	const [focusRequest, setFocusRequest] = useState<{
		lat: number;
		lng: number;
		id: string;
		zoom?: number;
		kind?: "select" | "locate";
	} | null>(null);
	const [tripName, setTripName] = useState("");
	const [confirmDiscard, setConfirmDiscard] = useState(false);
	/* «موقعي» pressed before the first fix: fly there as soon as it lands. */
	const pendingLocateRef = useRef(false);
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

	useEffect(() => {
		if (!pendingLocateRef.current || !userLocation || locationPinKind !== "gps") return;
		pendingLocateRef.current = false;
		setFocusRequest({ lat: userLocation.lat, lng: userLocation.lng, id: `locate-${Date.now()}`, kind: "locate", zoom: 14.2 });
		setFollowMode(true);
		setLeftUser(false);
	}, [userLocation, locationPinKind]);

	/* A track being recorded, or finished and not yet saved, lives only in this tab. */
	const unsavedTrack = Boolean(trip && (trip.status === "recording" || trip.status === "paused" || phase === "finish"));
	useEffect(() => {
		if (!unsavedTrack) return;
		const warn = (e: BeforeUnloadEvent) => {
			e.preventDefault();
			e.returnValue = "";
		};
		window.addEventListener("beforeunload", warn);
		return () => window.removeEventListener("beforeunload", warn);
	}, [unsavedTrack]);

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


	const locate = () => {
		track("locate_click", { source: "sary" });
		track("gps_start", { source: "sary" });
		requestLocation();
		if (!userLocation || locationPinKind !== "gps") {
			pendingLocateRef.current = true;
			return;
		}
		{
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
		setTripName(defaultTripName(trip));
		setConfirmDiscard(false);
		setPhase("finish");
		setFollowMode(false);
		setSheetSnap("half");
	};

	const defaultTripName = (t: TripRecord) => (isRTL ? `مسار ${formatDate(t.startedAt, true)}` : `Track ${formatDate(t.startedAt, false)}`);

	const persistTrip = async () => {
		if (!trip) return;
		try {
			const named: TripRecord = {
				...trip,
				status: "finished",
				endedAt: trip.endedAt || Date.now(),
				name: tripName.trim().slice(0, 60) || trip.name || defaultTripName(trip),
			};
			await saveTrip(named);
			setTrip(named);
			setPhase("saved");
			const all = await listTrips();
			setSavedTrips(all);
		} catch {
			track("trip_save_fail", { source: "idb" });
			setError(isRTL ? "تعذر حفظ المسار على هذا الجهاز." : "Could not save the track on this device.");
		}
	};

	const discardTrip = () => {
		setTrip(null);
		setTripName("");
		setConfirmDiscard(false);
		setPhase("explore");
		setSheetSnap("half");
	};

	const showSelectedOnMap = () => {
		if (!selected) return;
		setFollowMode(false);
		setFocusRequest({ lat: selected.lat, lng: selected.lng, id: `show-${selected.id}-${Date.now()}`, kind: "select", zoom: 14 });
		setSheetSnap("peek");
	};

	const submitSearch = () => {
		const q = query.trim();
		patchSearch({ q: q || undefined });
		if (!q) {
			setSearchHint(null);
			backToExplore();
			return;
		}
		if (q.length < 2) {
			setSearchHint(isRTL ? "اكتب حرفين على الأقل." : "Type at least two letters.");
			return;
		}
		setSearchHint(null);
		setPhase("search");
		void OutdoorService.search(q)
			.then((data) => {
				setFeatures(data);
				if (!data.features.length) setPhase("empty");
			})
			.catch(() => setPhase("error"));
	};

	const backToExplore = () => {
		setPhase("explore");
		fetchedRef.current = "";
		if (viewRef.current) void loadViewport(viewRef.current.bbox, viewRef.current.zoom);
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
			? isRTL ? "اسمح بالموقع" : "Allow location"
			: phase === "start" || phase === "explore" || phase === "empty" || phase === "trips"
				? isRTL ? "سجّل مسارك" : "Record a track"
				: phase === "tracking" || phase === "weak"
					? isRTL ? "إنهاء التسجيل" : "Finish recording"
					: phase === "paused"
						? isRTL ? "استئناف التسجيل" : "Resume recording"
						: phase === "finish"
							? isRTL ? "حفظ المسار" : "Save track"
							: phase === "saved"
								? isRTL ? "مساراتي" : "My tracks"
								: phase === "error"
									? isRTL ? "إعادة المحاولة" : "Retry"
									: undefined;

	const onCta = () => {
		if (phase === "permission") {
			requestLocation();
			setPhase("loading");
			return;
		}
		if (phase === "start" || phase === "explore" || phase === "empty" || phase === "trips") {
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
		if (phase === "tracking" || phase === "weak" || phase === "paused") {
			/* The sheet sits at peek while driving: the numbers belong in the line you can see. */
			const km = formatKm(trip?.distanceM ?? 0, isRTL);
			const dur = formatDuration(trip ? tripDurationMs(trip, now) : 0, isRTL);
			const lead =
				phase === "paused"
					? isRTL ? "متوقف مؤقتًا" : "Paused"
					: phase === "weak"
						? isRTL ? "إشارة GPS ضعيفة" : "Weak GPS"
						: isRTL ? "جارٍ التسجيل" : "Recording";
			return `${lead} · ${km} · ${dur}`;
		}
		if (phase === "finish") return isRTL ? "انتهى التسجيل — احفظ مسارك" : "Recording finished — save your track";
		if (phase === "saved") return isRTL ? "تم حفظ المسار على جهازك" : "Track saved on this device";
		if (phase === "trips") return isRTL ? "مساراتي المسجلة" : "My recorded tracks";
		if (phase === "empty") return isRTL ? "لا توجد معالم مرصودة هنا" : "No observed features here";
		if (phase === "error") return error || (isRTL ? "تعذر التحميل" : "Could not load");
		if (layer === "around") return isRTL ? "حولك الآن" : "Around you";
		if (layer === "tracks") return isRTL ? "المسارات" : "Tracks";
		if (layer === "places") return isRTL ? "المعالم" : "Places";
		return isRTL ? "مساراتي" : "My tracks";
	})();

	const ends = trip ? tripStartEnd(trip) : { start: null, end: null };
	const distanceFromMeM =
		selected && userLocation && locationPinKind === "gps" ? haversineMeters(userLocation, selected) : null;
	const speedText =
		userSpeed != null && locationPinKind === "gps"
			? isRTL ? `${formatNumber(Math.round(userSpeed * 3.6), true)} كم/س` : `${Math.round(userSpeed * 3.6)} km/h`
			: "—";

	return (
		<div className="sary-split farq-map-split" data-testid="sary-map-split" dir={isRTL ? "rtl" : "ltr"}>
			<div className="sary-map-pane">
				<Suspense fallback={<div className="sary-map-fallback" />}>
					<FarqMap
						mode="outdoor"
						basemap="satellite"
						onMapReady={setMapInstance}
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
						userAccuracy={userAccuracy}
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
					onSearchSubmit={submitSearch}
					onSearchClear={() => {
						setSearchHint(null);
						patchSearch({ q: undefined });
						backToExplore();
					}}
					searchHint={searchHint}
					onToggleLanguage={toggleLanguage}
					onOffline={() => setOfflineOpen(true)}
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
								<li>
									{userLocation && locationPinKind === "gps"
										? isRTL
											? "لا توجد معالم برية مرصودة ضمن ١٥ كم منك. ابحث باسم روضة أو نفود، أو حرّك الخريطة إلى البر."
											: "No observed outdoor features within 15 km of you. Search for a rawdah or nafud, or pan out to the desert."
										: isRTL
											? "اسمح بالموقع لنلخّص ما حولك، أو حرّك الخريطة وابحث."
											: "Allow location to summarise what is around you, or pan and search."}
								</li>
							) : null}
						</ul>
					) : null}
					{phase === "place" && selected ? (
						<SaryPlaceSheet place={selected} nearby={nearby} isRTL={isRTL} distanceFromMeM={distanceFromMeM} onShowOnMap={showSelectedOnMap} />
					) : null}
					{phase === "route" && selected ? (
						<SaryRouteSheet route={selected} nearby={nearby} isRTL={isRTL} distanceFromMeM={distanceFromMeM} onShowOnMap={showSelectedOnMap} />
					) : null}
					{phase === "start" ? (
						<p>{isRTL ? "سيُرسم خط GPS حقيقي خلفك. لا حركة وهمية." : "A real GPS line will grow behind you. No fake movement."}</p>
					) : null}
					{phase === "tracking" || phase === "weak" || phase === "paused" ? (
						<div className="sary-trip-hud" data-testid="sary-trip-hud">
							<dl className="sary-stats">
								<div>
									<dt>{isRTL ? "المسافة" : "Distance"}</dt>
									<dd>{formatKm(trip?.distanceM ?? 0, isRTL)}</dd>
								</div>
								<div>
									<dt>{isRTL ? "المدة" : "Time"}</dt>
									<dd>{formatDuration(trip ? tripDurationMs(trip, now) : 0, isRTL)}</dd>
								</div>
								<div>
									<dt>{isRTL ? "السرعة الآن" : "Speed now"}</dt>
									<dd data-testid="sary-trip-speed">{phase === "paused" ? "—" : speedText}</dd>
								</div>
							</dl>
							{phase === "weak" ? <p>{isRTL ? "إشارة GPS ضعيفة — لن نرسم موقعًا لم نقِسه." : "Weak GPS — we will not draw a position we did not measure."}</p> : null}
							{phase === "paused" ? (
								<button type="button" className="sary-action" onClick={stopTrip}>
									{isRTL ? "إنهاء التسجيل" : "Finish recording"}
								</button>
							) : (
								<button type="button" className="sary-action" onClick={pauseTrip}>
									{isRTL ? "إيقاف مؤقت" : "Pause"}
								</button>
							)}
						</div>
					) : null}
					{phase === "finish" || phase === "saved" || phase === "trip" ? (
						<div className="sary-trip-done" data-testid="sary-trip-done">
							<dl className="sary-stats">
								<div>
									<dt>{isRTL ? "المسافة" : "Distance"}</dt>
									<dd>{formatKm(trip?.distanceM ?? 0, isRTL)}</dd>
								</div>
								<div>
									<dt>{isRTL ? "المدة" : "Time"}</dt>
									<dd>{formatDuration(trip ? tripDurationMs(trip) : 0, isRTL)}</dd>
								</div>
								<div>
									<dt>{isRTL ? "البداية" : "Start"}</dt>
									<dd>{ends.start ? formatTime(ends.start.at, isRTL) : "—"}</dd>
								</div>
								<div>
									<dt>{isRTL ? "النهاية" : "End"}</dt>
									<dd>{ends.end ? formatTime(trip?.endedAt ?? ends.end.at, isRTL) : "—"}</dd>
								</div>
							</dl>
							{phase === "finish" ? (
								<>
									<label className="sary-field">
										<span>{isRTL ? "اسم المسار" : "Track name"}</span>
										<input
											value={tripName}
											onChange={(e) => setTripName(e.target.value)}
											maxLength={60}
											data-testid="sary-trip-name"
										/>
									</label>
									{confirmDiscard ? (
										<div className="sary-confirm" role="alertdialog" data-testid="sary-discard-confirm">
											<p>{isRTL ? "تجاهل المسار؟ لن يُحفظ ولا يمكن استرجاعه." : "Discard this track? It will not be saved."}</p>
											<div className="sary-actions">
												<button type="button" className="sary-action is-danger" onClick={discardTrip} data-testid="sary-discard-yes">
													{isRTL ? "تجاهل" : "Discard"}
												</button>
												<button type="button" className="sary-action" onClick={() => setConfirmDiscard(false)}>
													{isRTL ? "رجوع" : "Back"}
												</button>
											</div>
										</div>
									) : (
										<button type="button" className="sary-action is-danger" onClick={() => setConfirmDiscard(true)} data-testid="sary-discard">
											{isRTL ? "تجاهل المسار" : "Discard track"}
										</button>
									)}
								</>
							) : (
								<p className="sary-meta">{trip?.name}</p>
							)}
						</div>
					) : null}
					{phase === "trips" ? (
						<ul className="sary-trips" data-testid="sary-trips">
							{savedTrips.map((row) => (
								<li key={row.id}>
									<button type="button" onClick={() => void openSaved(row.id)}>
										<strong>{row.name || defaultTripName(row)}</strong>
										<span>
											{formatDate(row.startedAt, isRTL)} · {formatKm(row.distanceM, isRTL)} ·{" "}
											{formatDuration(tripDurationMs(row), isRTL)}
										</span>
									</button>
								</li>
							))}
							{!savedTrips.length ? (
								<li className="sary-empty" data-testid="sary-trips-empty">
									{isRTL
										? "لا مسارات محفوظة على هذا الجهاز بعد. اضغط «سجّل مسارك» وسنرسم خطك الحقيقي من GPS أثناء تحركك."
										: "No tracks saved on this device yet. Tap “Record a track” and we will draw your real GPS line as you move."}
								</li>
							) : null}
						</ul>
					) : null}
					{phase === "empty" ? (
						<p>{isRTL ? "لا معالم مرصودة في هذه المنطقة. حرّك الخريطة، أو سجّل مسارك ليظهر أثرك — لا نرسم مسارات مخترعة." : "Nothing observed here. Move the map, or record a track — we never draw invented routes."}</p>
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
				{!online ? (
					<p className="sary-offline-badge" role="status" data-testid="sary-offline-badge">
						{isRTL ? "دون اتصال — تظهر المناطق المحفوظة فقط" : "Offline — saved areas only"}
					</p>
				) : null}
				{offlineOpen ? (
					<Suspense fallback={null}>
						<OfflineAreaSheet isRTL={isRTL} map={mapInstance} basemap="satellite" onClose={() => setOfflineOpen(false)} />
					</Suspense>
				) : null}
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
