import {
	createContext,
	type ReactNode,
	useCallback,
	useContext,
	useMemo,
	useState,
} from "react";
import { safeGet, safeSet } from "../lib/safeStorage";

export type Language = "en" | "ar";

type LanguageContextType = {
	language: Language;
	toggleLanguage: () => void;
	languageSwitching: boolean;
	t: (key: string) => string;
	translateTag: (tag: string) => string;
};

const LanguageContext = createContext<LanguageContextType | undefined>(
	undefined,
);

export function applyDocumentLanguage(language: Language): void {
	if (typeof document === "undefined") return;
	document.documentElement.lang = language;
	document.documentElement.dir = language === "ar" ? "rtl" : "ltr";
}

function readInitial(): Language {
	const stored = safeGet("localStorage", "farq_map_lang");
	if (stored === "en" || stored === "ar") return stored;
	return "ar";
}

export function LanguageProvider({ children }: { children: ReactNode }) {
	const [language, setLanguage] = useState<Language>(() => {
		const initial = readInitial();
		applyDocumentLanguage(initial);
		return initial;
	});

	const toggleLanguage = useCallback(() => {
		setLanguage((prev) => {
			const next = prev === "ar" ? "en" : "ar";
			safeSet("localStorage", "farq_map_lang", next);
			applyDocumentLanguage(next);
			return next;
		});
	}, []);

	const value = useMemo<LanguageContextType>(
		() => ({
			language,
			toggleLanguage,
			languageSwitching: false,
			t: (key) => key,
			translateTag: (tag) => tag,
		}),
		[language, toggleLanguage],
	);

	return (
		<LanguageContext.Provider value={value}>{children}</LanguageContext.Provider>
	);
}

export function useLanguage(): LanguageContextType {
	const ctx = useContext(LanguageContext);
	if (!ctx) throw new Error("useLanguage must be used within LanguageProvider");
	return ctx;
}
