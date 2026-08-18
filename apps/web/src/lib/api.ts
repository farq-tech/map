const viteEnv: Record<string, string | boolean | undefined> =
	(typeof import.meta !== "undefined" && import.meta.env) || {};

function resolveApiBaseUrl(): string {
	if (typeof window !== "undefined") {
		const host = window.location.hostname;
		if (host.endsWith(".vercel.app") || host === "localhost") return "";
	}
	const raw = viteEnv.VITE_API_BASE_URL;
	if (raw == null || String(raw).trim() === "") return "";
	return String(raw).replace(/\/$/, "");
}

export const API_BASE_URL = resolveApiBaseUrl();

export interface ApiEnvelope<T> {
	ok: boolean;
	data: T;
	partialResults: boolean;
	errors: Array<{ message: string }>;
	message: string;
	meta: Record<string, unknown>;
}

export class ApiRequestError extends Error {
	status: number;
	constructor(message: string, status: number) {
		super(message);
		this.name = "ApiRequestError";
		this.status = status;
	}
}

export async function fetchApi<T>(
	path: string,
	init?: RequestInit,
	options?: { timeoutMs?: number },
): Promise<ApiEnvelope<T>> {
	const controller = new AbortController();
	const timeout = setTimeout(
		() => controller.abort(),
		options?.timeoutMs ?? 15_000,
	);
	if (init?.signal) {
		init.signal.addEventListener("abort", () => controller.abort(), {
			once: true,
		});
	}
	try {
		const response = await fetch(`${API_BASE_URL}${path}`, {
			...init,
			signal: controller.signal,
		});
		const payload: unknown = await response.json().catch(() => null);
		if (!response.ok) {
			throw new ApiRequestError(
				`HTTP error! status: ${response.status}`,
				response.status,
			);
		}
		if (
			payload &&
			typeof payload === "object" &&
			"ok" in payload &&
			"data" in payload
		) {
			return payload as ApiEnvelope<T>;
		}
		return {
			ok: true,
			data: payload as T,
			partialResults: false,
			errors: [],
			message: "OK",
			meta: {},
		};
	} finally {
		clearTimeout(timeout);
	}
}
