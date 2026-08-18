import react from "@vitejs/plugin-react";
import { defineConfig, loadEnv } from "vite";

export default defineConfig(({ mode }) => {
	const envDir = new URL("../..", import.meta.url).pathname;
	const env = loadEnv(mode, envDir, "");
	const apiTarget = env.VITE_API_BASE_URL || "http://127.0.0.1:4001";

	return {
		envDir,
		plugins: [react()],
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
