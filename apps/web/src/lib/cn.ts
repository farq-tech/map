/**
 * Tiny className joiner — deliberately dependency-free.
 *
 * Farq's Button system controls its own class strings (there are no
 * user-supplied Tailwind classes that could conflict), so we do NOT need
 * `clsx` + `tailwind-merge`. This keeps the button primitive at ~zero bundle
 * cost while still supporting the ergonomic conditional-class API.
 *
 * Accepts strings, falsy values (skipped), and `Record<string, boolean>`
 * objects (keys whose value is truthy are included).
 */
export type ClassValue =
	| string
	| number
	| null
	| false
	| undefined
	| Record<string, boolean | null | undefined>;

export function cn(...inputs: ClassValue[]): string {
	const out: string[] = [];
	for (const input of inputs) {
		if (!input) continue;
		if (typeof input === "string" || typeof input === "number") {
			out.push(String(input));
		} else if (typeof input === "object") {
			for (const key in input) {
				if (input[key]) out.push(key);
			}
		}
	}
	return out.join(" ");
}
