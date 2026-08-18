import { cn } from "../lib/cn";
import {
	getProviderLabel,
	resolveProviderDisplayLogo,
} from "../lib/platformLogos";
import { providerTintClass } from "../lib/providerTint";

function hideBrokenImage(e: { currentTarget: HTMLImageElement }): void {
	const el = e.currentTarget;
	el.onerror = null;
	el.removeAttribute("src");
	el.style.display = "none";
}

function initialFrom(label: string | null | undefined, provider: unknown): string {
	const raw = String(label || provider || "?").trim();
	return (raw.charAt(0) || "?").toUpperCase();
}

export function ProviderLogoMark({
	provider,
	label,
	size = 32,
	className,
	isRTL = false,
	restaurantLogoUrl,
	restaurantName,
	tintedFallback = false,
	rounded = "md",
}: {
	provider: unknown;
	label?: string | null;
	size?: number;
	className?: string;
	isRTL?: boolean;
	restaurantLogoUrl?: string | null;
	restaurantName?: string | null;
	tintedFallback?: boolean;
	rounded?: "md" | "full" | "xl" | "2xl";
}) {
	const display = resolveProviderDisplayLogo(provider, {
		isRTL,
		restaurantLogoUrl,
		restaurantName,
	});
	const src = display?.src || null;
	const resolvedLabel =
		label?.trim() ||
		display?.label ||
		getProviderLabel(provider, { isRTL, restaurantName }) ||
		String(provider ?? "");
	const initial = initialFrom(resolvedLabel, provider);
	const roundClass =
		rounded === "full"
			? "rounded-full"
			: rounded === "2xl"
				? "rounded-2xl"
				: rounded === "xl"
					? "rounded-xl"
					: "rounded-md";
	const tint = tintedFallback && !src;

	return (
		<span
			data-testid="provider-logo-mark"
			data-provider={String(provider ?? "")}
			title={resolvedLabel || undefined}
			className={cn(
				"relative inline-flex shrink-0 items-center justify-center overflow-hidden",
				roundClass,
				tint && providerTintClass(String(provider ?? "")),
				!src && !tint && "bg-neutral-200 text-brand-900",
				className,
			)}
			style={{ width: size, height: size }}
		>
			<span className="text-[0.65em] font-black" aria-hidden>
				{initial}
			</span>
			{src ? (
				<img
					src={src}
					alt=""
					className={cn("absolute inset-0 h-full w-full object-cover", roundClass)}
					onError={hideBrokenImage}
				/>
			) : null}
		</span>
	);
}
