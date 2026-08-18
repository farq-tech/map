import { useEffect, useRef, useState } from "react";
import { usePrefersReducedMotion } from "./usePrefersReducedMotion";

/** Ease-out cubic: fast start, gentle settle — reads as a number "landing". */
const easeOutCubic = (t: number): number => 1 - (1 - t) ** 3;

/**
 * Animate a number toward `target` (count-up / count-down) for reveal moments —
 * e.g. a savings figure counting up from 0 when a comparison resolves.
 *
 * - First mount animates from 0 → target (the reveal); later target changes
 *   animate from wherever the number currently is (interrupt-safe).
 * - Honors `prefers-reduced-motion`: jumps straight to `target`, no animation.
 * - rAF-driven and self-cancelling, so it never leaks a frame loop.
 *
 * Returns the live value; format it at the call site (e.g. via formatPrice).
 */
export function useCountUp(
	target: number,
	options: { durationMs?: number } = {},
): number {
	const { durationMs = 700 } = options;
	const reduced = usePrefersReducedMotion();

	const [value, setValue] = useState(reduced ? target : 0);
	// Where the next animation starts from — kept in sync each frame so an
	// interrupting target change eases from the currently-shown value.
	const fromRef = useRef(reduced ? target : 0);
	const rafRef = useRef(0);

	useEffect(() => {
		if (reduced || durationMs <= 0) {
			fromRef.current = target;
			setValue(target);
			return;
		}
		const from = fromRef.current;
		if (from === target) return;

		let startTs: number | null = null;
		const step = (ts: number) => {
			if (startTs === null) startTs = ts;
			const t = Math.min(1, (ts - startTs) / durationMs);
			const current = from + (target - from) * easeOutCubic(t);
			fromRef.current = current;
			setValue(current);
			if (t < 1) {
				rafRef.current = requestAnimationFrame(step);
			} else {
				fromRef.current = target;
			}
		};
		rafRef.current = requestAnimationFrame(step);
		return () => cancelAnimationFrame(rafRef.current);
	}, [target, durationMs, reduced]);

	return value;
}
