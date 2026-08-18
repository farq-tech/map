import { useEffect, useState } from "react";

const QUERY = "(prefers-reduced-motion: reduce)";

/**
 * Live `prefers-reduced-motion` state. Components use this to swap smooth
 * scrolling and scroll-linked transforms for instant/opacity-only variants —
 * CSS `@media` can't reach JS-driven `scrollIntoView`/inline-style motion.
 */
export function usePrefersReducedMotion(): boolean {
	const [reduced, setReduced] = useState<boolean>(() => {
		if (typeof window === "undefined" || !window.matchMedia) return false;
		return window.matchMedia(QUERY).matches;
	});

	useEffect(() => {
		if (!window.matchMedia) return;
		const mq = window.matchMedia(QUERY);
		const onChange = () => setReduced(mq.matches);
		mq.addEventListener("change", onChange);
		return () => mq.removeEventListener("change", onChange);
	}, []);

	return reduced;
}
