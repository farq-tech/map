/**
 * Visual tint for a known delivery provider id — brand recognition only.
 * Never used to invent a winner; call sites must already have API data.
 */
export function providerTintClass(id: string | null | undefined): string {
	const k = String(id || "").toLowerCase();
	if (k.includes("jahez")) return "bg-red-600";
	if (k.includes("hunger")) return "bg-orange-500";
	if (k.includes("chef")) return "bg-violet-600";
	if (k.includes("toyou") || k.includes("to_you") || k === "to you")
		return "bg-teal-600";
	if (k.includes("keeta")) return "bg-amber-500";
	if (k.includes("ninja")) return "bg-slate-700";
	if (k.includes("mrsool") || k.includes("mersol")) return "bg-sky-700";
	return "bg-neutral-400";
}

export function providerTintSoftClass(id: string | null | undefined): string {
	const k = String(id || "").toLowerCase();
	if (k.includes("jahez")) return "bg-red-600/20 ring-1 ring-red-600/40";
	if (k.includes("hunger")) return "bg-orange-500/20 ring-1 ring-orange-500/40";
	if (k.includes("chef")) return "bg-violet-600/20 ring-1 ring-violet-600/40";
	if (k.includes("toyou") || k.includes("to_you") || k === "to you")
		return "bg-teal-600/20 ring-1 ring-teal-600/40";
	if (k.includes("keeta")) return "bg-amber-500/20 ring-1 ring-amber-500/40";
	if (k.includes("ninja")) return "bg-slate-700/20 ring-1 ring-slate-700/40";
	return "bg-neutral-200 ring-1 ring-neutral-300 dark:bg-neutral-700";
}
