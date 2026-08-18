import { type RefObject, useEffect } from "react";

const FOCUSABLE_SELECTOR = [
	"a[href]",
	"button:not([disabled])",
	"input:not([disabled])",
	"select:not([disabled])",
	"textarea:not([disabled])",
	'[tabindex]:not([tabindex="-1"])',
].join(",");

/**
 * Trap keyboard focus inside `containerRef` while `active`. Tab / Shift+Tab
 * cycle within the container's focusable children and never escape to the
 * page behind an overlay (the app root — BottomTabBar, etc. — stays mounted
 * under hand-rolled modals). Pairs with the existing move-focus-in / restore
 * logic in the dialogs; this only wires the Tab cycling.
 *
 * For Radix-based dialogs (Sheet, AuthModal) focus trapping already comes for
 * free — this is for the few full-screen modals built on a bare <div>.
 */
export function useFocusTrap(
	containerRef: RefObject<HTMLElement | null>,
	active: boolean,
): void {
	useEffect(() => {
		if (!active) return;
		const container = containerRef.current;
		if (!container) return;

		const onKeyDown = (e: KeyboardEvent) => {
			if (e.key !== "Tab") return;
			const focusable = Array.from(
				container.querySelectorAll<HTMLElement>(FOCUSABLE_SELECTOR),
			).filter(
				(el) => el.offsetWidth > 0 || el.offsetHeight > 0 || el === document.activeElement,
			);
			if (focusable.length === 0) {
				// Nothing focusable inside — keep focus on the container itself.
				e.preventDefault();
				container.focus();
				return;
			}
			const first = focusable[0];
			const last = focusable[focusable.length - 1];
			const activeEl = document.activeElement as HTMLElement | null;

			if (e.shiftKey) {
				if (activeEl === first || !container.contains(activeEl)) {
					e.preventDefault();
					last.focus();
				}
			} else if (activeEl === last || !container.contains(activeEl)) {
				e.preventDefault();
				first.focus();
			}
		};

		document.addEventListener("keydown", onKeyDown);
		return () => document.removeEventListener("keydown", onKeyDown);
	}, [active, containerRef]);
}
