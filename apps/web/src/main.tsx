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
			<MapPage search={search} />
		</Suspense>
	);
}

function IndexRoute() {
	const search = indexRoute.useSearch();
	return (
		<Suspense fallback={<RouteFallback />}>
			<MapPage search={search} />
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
	groceryRoute,
	merchantRoute,
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
