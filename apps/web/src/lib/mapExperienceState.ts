export type MapExperienceState =
	| "idle"
	| "exploring"
	| "opportunity_selected"
	| "sheet_peek"
	| "sheet_expanded"
	| "drawer_open"
	| "searching";

export type MapExperienceEvent =
	| { type: "EXPLORE" }
	| { type: "SELECT_OPPORTUNITY" }
	| { type: "PEEK_SHEET" }
	| { type: "EXPAND_SHEET" }
	| { type: "OPEN_DRAWER" }
	| { type: "CLOSE_DRAWER" }
	| { type: "SEARCH" }
	| { type: "CLEAR_SELECTION" }
	| { type: "CLOSE_SHEET" };

export function transition(state: MapExperienceState, event: MapExperienceEvent): MapExperienceState {
	switch (event.type) {
		case "EXPLORE": return "exploring";
		case "SELECT_OPPORTUNITY": return "opportunity_selected";
		case "PEEK_SHEET": return "sheet_peek";
		case "EXPAND_SHEET": return "sheet_expanded";
		case "OPEN_DRAWER": return "drawer_open";
		case "CLOSE_DRAWER": return "exploring";
		case "SEARCH": return "searching";
		case "CLEAR_SELECTION":
		case "CLOSE_SHEET": return "exploring";
		default: return state;
	}
}
