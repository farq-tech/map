import { useEffect } from "react";

const SARY_BG = "#1a1612";
const BODY_CLASS = "sary-body";

/**
 * Sary screens are sand-dark; the document defaults to Farq teal. Without this
 * a desktop window shows a teal strip under the map and the phone's status bar
 * stays teal. Restores whatever was there on unmount.
 */
export function useSaryChrome(enabled = true): void {
	useEffect(() => {
		if (!enabled || typeof document === "undefined") return;
		const meta = document.querySelector<HTMLMetaElement>('meta[name="theme-color"]');
		const prevTheme = meta?.content ?? null;
		const prevHtmlBg = document.documentElement.style.backgroundColor;
		document.body.classList.add(BODY_CLASS);
		document.documentElement.style.backgroundColor = SARY_BG;
		if (meta) meta.content = SARY_BG;
		return () => {
			document.body.classList.remove(BODY_CLASS);
			document.documentElement.style.backgroundColor = prevHtmlBg;
			if (meta && prevTheme != null) meta.content = prevTheme;
		};
	}, [enabled]);
}
