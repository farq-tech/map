import { lazy, Suspense } from "react";
import ReactDOM from "react-dom/client";
import {
	Outlet,
	RouterProvider,
	createRootRoute,
	createRoute,
	createRouter,
} from "@tanstack/react-router";
import { LanguageProvider } from "./contexts/LanguageContext";
import { LocationProvider } from "./contexts/LocationContext";
import RouteFallback from "./components/RouteFallback";
import { parseMapSearch } from "./routes/map";
import "./index.css";

const MapPage = lazy(() => import("./pages/MapPage"));
const MerchantPage = lazy(() => import("./pages/MerchantPage"));
const GroceryStubPage = lazy(() => import("./pages/GroceryStubPage"));
const OutingsHome = lazy(() => import("./components/outings/OutingsHome"));
const OutingJoin = lazy(() => import("./components/outings/OutingJoin"));
const OutingLive = lazy(() => import("./components/outings/OutingLive"));

function RootLayout() {
	return (
		<LanguageProvider>
			<LocationProvider>
				<Outlet />
			</LocationProvider>
		</LanguageProvider>
	);
}

function MapRoute() {
	const search = mapRoute.useSearch();
	return (
		<Suspense fallback={<RouteFallback />}>
			<MapPage search={search} product="outdoor" />
		</Suspense>
	);
}

function IndexRoute() {
	const search = indexRoute.useSearch();
	return (
		<Suspense fallback={<RouteFallback />}>
			<MapPage search={search} product="outdoor" />
		</Suspense>
	);
}

function CompareRoute() {
	const search = compareRoute.useSearch();
	return (
		<Suspense fallback={<RouteFallback />}>
			<MapPage search={search} product="restaurants" />
		</Suspense>
	);
}

const rootRoute = createRootRoute({
	component: RootLayout,
});

const indexRoute = createRoute({
	getParentRoute: () => rootRoute,
	path: "/",
	validateSearch: parseMapSearch,
	component: IndexRoute,
});

const mapRoute = createRoute({
	getParentRoute: () => rootRoute,
	path: "/map",
	validateSearch: parseMapSearch,
	component: MapRoute,
});

const compareRoute = createRoute({
	getParentRoute: () => rootRoute,
	path: "/compare",
	validateSearch: parseMapSearch,
	component: CompareRoute,
});

const groceryRoute = createRoute({
	getParentRoute: () => rootRoute,
	path: "/grocery",
	validateSearch: (s: Record<string, unknown>) => ({
		q: typeof s.q === "string" && s.q.trim() ? s.q.trim() : undefined,
	}),
	component: () => (
		<Suspense fallback={<RouteFallback />}>
			<GroceryStubPage />
		</Suspense>
	),
});

/* طلعة مشتركة — shared outings. The invite token rides in the URL fragment (/outings/join#…). */
const outingsRoute = createRoute({
	getParentRoute: () => rootRoute,
	path: "/outings",
	component: () => (
		<Suspense fallback={<RouteFallback />}>
			<OutingsHome />
		</Suspense>
	),
});

const outingJoinRoute = createRoute({
	getParentRoute: () => rootRoute,
	path: "/outings/join",
	component: () => (
		<Suspense fallback={<RouteFallback />}>
			<OutingJoin />
		</Suspense>
	),
});

const outingLiveRoute = createRoute({
	getParentRoute: () => rootRoute,
	path: "/outings/$id",
	validateSearch: (s: Record<string, unknown>): { panel?: "members" | "invite" | "settings" } => ({
		panel: s.panel === "invite" || s.panel === "settings" || s.panel === "members" ? s.panel : undefined,
	}),
	component: function OutingLiveRoute() {
		const { id } = outingLiveRoute.useParams();
		const { panel } = outingLiveRoute.useSearch();
		return (
			<Suspense fallback={<RouteFallback />}>
				<OutingLive key={id} outingId={id} initialPanel={panel} />
			</Suspense>
		);
	},
});

const merchantRoute = createRoute({
	getParentRoute: () => rootRoute,
	path: "/merchant/$type/$id",
	validateSearch: (
		s: Record<string, unknown>,
	): {
		branch?: string;
		name?: string;
		image?: string;
		item?: string;
		itemName?: string;
		closed?: boolean;
	} => ({
		branch: typeof s.branch === "string" ? s.branch : undefined,
		name: typeof s.name === "string" ? s.name : undefined,
		image: typeof s.image === "string" ? s.image : undefined,
		item: typeof s.item === "string" && s.item.trim() ? s.item.trim() : undefined,
		itemName:
			typeof s.itemName === "string" && s.itemName.trim()
				? s.itemName.trim()
				: undefined,
		closed: s.closed === true || s.closed === "true" || s.closed === "1",
	}),
	component: () => (
		<Suspense fallback={<RouteFallback />}>
			<MerchantPage />
		</Suspense>
	),
});

const routeTree = rootRoute.addChildren([
	indexRoute,
	mapRoute,
	compareRoute,
	groceryRoute,
	merchantRoute,
	outingsRoute,
	outingJoinRoute,
	outingLiveRoute,
]);

const router = createRouter({ routeTree });

declare module "@tanstack/react-router" {
	interface Register {
		router: typeof router;
	}
}

const el = document.getElementById("root");
if (!el) throw new Error("root missing");
ReactDOM.createRoot(el).render(<RouterProvider router={router} />);
