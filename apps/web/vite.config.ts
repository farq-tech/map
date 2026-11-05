import react from "@vitejs/plugin-react";
import { defineConfig, loadEnv, type Plugin } from "vite";
import { INVITE_PAGE_FILE, inviteHtml, publicOrigin } from "./src/lib/outings/inviteMeta";

/** Emits outings-join.html next to index.html: the invite link's preview card (see inviteMeta.ts). */
function invitePreviewPage(origin: string): Plugin {
	return {
		name: "sary-invite-preview",
		apply: "build",
		enforce: "post",
		generateBundle(_opts, bundle) {
			const index = bundle["index.html"];
			if (!index || index.type !== "asset") return;
			this.emitFile({ type: "asset", fileName: INVITE_PAGE_FILE, source: inviteHtml(String(index.source), origin) });
		},
	};
}

export default defineConfig(({ mode }) => {
	const envDir = new URL("../..", import.meta.url).pathname;
	const env = loadEnv(mode, envDir, "");
	const apiTarget = env.VITE_API_BASE_URL || "http://127.0.0.1:4001";

	return {
		envDir,
		plugins: [react(), invitePreviewPage(publicOrigin({ ...env, ...process.env }))],
		define: {
			__APP_VERSION__: JSON.stringify(
				process.env.VERCEL_GIT_COMMIT_SHA?.slice(0, 7) || "dev",
			),
		},
		server: {
			port: 5173,
			host: true,
			proxy: {
				"/api": {
					target: apiTarget,
					changeOrigin: true,
					/* /api/outings/live is a WebSocket. */
					ws: true,
				},
			},
		},
		preview: {
			port: 4173,
		},
		build: {
			sourcemap: false,
		},
	};
});
