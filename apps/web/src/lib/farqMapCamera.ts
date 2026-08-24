/** First-frame camera: a link's bbox wins; the last pan is only a fallback. */

export type LandingCamera = {
	center: [number, number];
	zoom: number;
	pitch: number;
	bearing: number;
};

export function resolveLandingCamera(opts: {
	initialCamera?: { center: [number, number]; zoom: number } | null;
	session?: { center: [number, number]; zoom: number; pitch: number; bearing: number } | null;
	resumeSession: boolean;
	fallback: { center: [number, number]; zoom: number };
}): LandingCamera {
	const session = opts.resumeSession ? opts.session : null;
	if (opts.initialCamera) {
		return {
			center: opts.initialCamera.center,
			zoom: opts.initialCamera.zoom,
			pitch: session ? Math.min(session.pitch, 36) : 0,
			bearing: session ? session.bearing : 0,
		};
	}
	if (session) {
		return {
			center: session.center,
			zoom: session.zoom,
			pitch: Math.min(session.pitch, 36),
			bearing: session.bearing,
		};
	}
	return {
		center: opts.fallback.center,
		zoom: opts.fallback.zoom,
		pitch: 0,
		bearing: 0,
	};
}
