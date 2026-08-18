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

function readInitial(): Language {
	const stored = safeGet("localStorage", "farq_map_lang");
	if (stored === "en" || stored === "ar") return stored;
	return "ar";
}

export function LanguageProvider({ children }: { children: ReactNode }) {
	const [language, setLanguage] = useState<Language>(readInitial);

	const toggleLanguage = useCallback(() => {
		setLanguage((prev) => {
			const next = prev === "ar" ? "en" : "ar";
			safeSet("localStorage", "farq_map_lang", next);
			document.documentElement.lang = next;
			document.documentElement.dir = next === "ar" ? "rtl" : "ltr";
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
