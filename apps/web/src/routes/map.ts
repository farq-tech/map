export type MapSearch = {
	neighborhood?: string;
	category?: string;
	city?: string;
	q?: string;
	place?: string;
};

export function parseMapSearch(s: Record<string, unknown>): MapSearch {
	const trim = (v: unknown, max: number): string | undefined => {
		if (typeof v !== "string") return undefined;
		const t = v.trim().slice(0, max);
		return t || undefined;
	};
	return {
		neighborhood: trim(s.neighborhood, 120),
		category: trim(s.category, 40),
		city: trim(s.city, 40),
		q: trim(s.q, 200),
		place: trim(s.place, 80),
	};
}
