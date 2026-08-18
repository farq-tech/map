import type { Config } from "tailwindcss";

export default {
	content: ["./index.html", "./src/**/*.{js,ts,jsx,tsx}"],
	theme: {
		extend: {
			colors: {
				brand: {
					900: "rgb(var(--brand-900) / <alpha-value>)",
					800: "rgb(var(--brand-800) / <alpha-value>)",
					700: "rgb(var(--brand-700) / <alpha-value>)",
					200: "rgb(var(--brand-200) / <alpha-value>)",
					100: "rgb(var(--brand-100) / <alpha-value>)",
				},
				mint: {
					50: "rgb(var(--mint-50) / <alpha-value>)",
					100: "rgb(var(--mint-100) / <alpha-value>)",
					200: "rgb(var(--mint-200) / <alpha-value>)",
					300: "rgb(var(--mint-300) / <alpha-value>)",
					400: "rgb(var(--mint-400) / <alpha-value>)",
					500: "rgb(var(--mint-500) / <alpha-value>)",
					600: "rgb(var(--mint-600) / <alpha-value>)",
					700: "rgb(var(--mint-700) / <alpha-value>)",
					800: "rgb(var(--mint-800) / <alpha-value>)",
				},
				coral: {
					500: "rgb(var(--coral-500) / <alpha-value>)",
					600: "rgb(var(--coral-600) / <alpha-value>)",
					700: "rgb(var(--coral-700) / <alpha-value>)",
				},
				amber: {
					500: "rgb(var(--amber-500) / <alpha-value>)",
					600: "rgb(var(--amber-600) / <alpha-value>)",
					700: "rgb(var(--amber-700) / <alpha-value>)",
				},
				neutral: {
					50: "rgb(var(--neutral-50) / <alpha-value>)",
					100: "rgb(var(--neutral-100) / <alpha-value>)",
					200: "rgb(var(--neutral-200) / <alpha-value>)",
					300: "rgb(var(--neutral-300) / <alpha-value>)",
					400: "rgb(var(--neutral-400) / <alpha-value>)",
					500: "rgb(var(--neutral-500) / <alpha-value>)",
					600: "rgb(var(--neutral-600) / <alpha-value>)",
					700: "rgb(var(--neutral-700) / <alpha-value>)",
				},
				surface: {
					DEFAULT: "rgb(var(--surface) / <alpha-value>)",
					2: "rgb(var(--surface-2) / <alpha-value>)",
					3: "rgb(var(--surface-3) / <alpha-value>)",
				},
				ink: {
					DEFAULT: "rgb(var(--ink) / <alpha-value>)",
					subtle: "rgb(var(--ink-subtle) / <alpha-value>)",
					muted: "rgb(var(--ink-muted) / <alpha-value>)",
				},
				line: {
					DEFAULT: "rgb(var(--line) / <alpha-value>)",
					strong: "rgb(var(--line-strong) / <alpha-value>)",
				},
				teal: {
					200: "#99f6e4",
				},
			},
			fontFamily: {
				sans: ["Tajawal", "system-ui", "sans-serif"],
				arabic: ["Tajawal", "system-ui", "sans-serif"],
			},
			borderRadius: {
				"ds-md": "0.75rem",
				"ds-xl": "1rem",
				"ds-2xl": "1.25rem",
			},
		},
	},
	plugins: [],
} satisfies Config;
