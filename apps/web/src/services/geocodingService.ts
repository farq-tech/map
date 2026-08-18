export interface ReverseGeocodeResult {
	label: string;
	displayName: string;
	approximate: boolean;
}

export interface SearchLocationResult {
	lat: string;
	lon: string;
	display_name: string;
}

function fallback(language: "ar" | "en"): ReverseGeocodeResult {
	const label = language === "ar" ? "الموقع التقريبي" : "Approximate location";
	return { label, displayName: label, approximate: true };
}

export class GeocodingService {
	static async reverseGeocode(
		_lat: number,
		_lng: number,
		language: "ar" | "en",
	): Promise<ReverseGeocodeResult> {
		return fallback(language);
	}

	static async searchLocations(
		_query: string,
		_language: "ar" | "en",
		_signal?: AbortSignal,
	): Promise<SearchLocationResult[]> {
		return [];
	}
}
