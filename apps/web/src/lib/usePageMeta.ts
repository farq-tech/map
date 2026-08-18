import { useEffect } from "react";

export function usePageMeta(opts: {
	title: string;
	description?: string;
	path?: string;
	robots?: string;
}): void {
	useEffect(() => {
		document.title = opts.title;
		const desc = document.querySelector('meta[name="description"]');
		if (desc && opts.description) {
			desc.setAttribute("content", opts.description);
		}
		const robots = document.querySelector('meta[name="robots"]');
		if (robots && opts.robots) {
			robots.setAttribute("content", opts.robots);
		}
	}, [opts.title, opts.description, opts.path, opts.robots]);
}
