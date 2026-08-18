import {
	type ButtonHTMLAttributes,
	Children,
	cloneElement,
	forwardRef,
	isValidElement,
	type ReactElement,
	type ReactNode,
} from "react";
import { cn } from "../../lib/cn";

export type ButtonVariant =
	| "primary"
	| "secondary"
	| "outline"
	| "ghost"
	| "destructive"
	| "warning"
	| "success"
	| "link";

export type ButtonSize = "sm" | "md" | "lg" | "icon";

export interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
	variant?: ButtonVariant;
	size?: ButtonSize;
	loading?: boolean;
	fullWidth?: boolean;
	startIcon?: ReactNode;
	endIcon?: ReactNode;
	shape?: "rounded" | "pill";
	asChild?: boolean;
}

const variants: Record<ButtonVariant, string> = {
	primary: "border border-brand-900 bg-brand-900 text-mint-500 hover:bg-brand-800",
	secondary: "border border-line bg-surface text-ink hover:bg-surface-2",
	outline: "border border-brand-900/30 text-brand-900 hover:bg-brand-900/5",
	ghost: "text-ink hover:bg-ink/5",
	destructive: "bg-coral-500 text-white",
	warning: "bg-amber-500 text-brand-900",
	success: "bg-mint-500 text-brand-900",
	link: "text-brand-900 underline-offset-4 hover:underline",
};

const sizes: Record<Exclude<ButtonSize, "icon">, string> = {
	sm: "h-9 min-w-16 px-3 text-sm",
	md: "h-11 min-w-20 px-5 text-sm",
	lg: "h-12 min-w-24 px-6 text-base",
};

export const Button = forwardRef<HTMLButtonElement, ButtonProps>(
	function Button(
		{
			variant = "primary",
			size = "md",
			loading = false,
			fullWidth = false,
			startIcon,
			endIcon,
			shape,
			asChild = false,
			className,
			children,
			disabled,
			type,
			...rest
		},
		ref,
	) {
		const isIcon = size === "icon";
		const effectiveShape = shape ?? (isIcon ? "pill" : "rounded");
		const classes = cn(
			"inline-flex items-center justify-center gap-2 font-semibold",
			variants[variant],
			isIcon ? "h-11 w-11 p-0" : sizes[size],
			effectiveShape === "pill" ? "rounded-full" : "rounded-2xl",
			fullWidth && "w-full",
			(disabled || loading) && "pointer-events-none opacity-60",
			className,
		);

		if (asChild && isValidElement(children)) {
			const child = Children.only(children) as ReactElement<{
				className?: string;
			}>;
			return cloneElement(child, {
				className: cn(classes, child.props.className),
				...rest,
			});
		}

		return (
			<button
				ref={ref}
				type={type ?? "button"}
				disabled={disabled || loading}
				className={classes}
				{...rest}
			>
				{startIcon}
				{children}
				{endIcon}
			</button>
		);
	},
);

export const IconButton = Button;
