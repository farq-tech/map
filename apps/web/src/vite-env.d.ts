/// <reference types="vite/client" />

interface ImportMetaEnv {
	readonly VITE_MAPBOX_ACCESS_TOKEN?: string;
	readonly VITE_API_BASE_URL?: string;
	readonly VITE_FEATURE_FLAGS?: string;
	/** Live outings WebSocket, e.g. wss://api.example/api/outings/live. Vercel cannot proxy sockets. */
	readonly VITE_LIVE_WS_URL?: string;
	readonly DEV: boolean;
}

interface ImportMeta {
	readonly env: ImportMetaEnv;
}

declare const __APP_VERSION__: string;
