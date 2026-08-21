/**
 * The marker that stands for you on the map.
 *
 * Two states, and the difference matters. Before anyone personalises anything
 * it is the pulsing dot this map has always drawn — a location, honestly and
 * without decoration. Once a photo is chosen it becomes the photo above a car,
 * because at that point the marker is not just "a position", it is "you".
 *
 * The car is only drawn when there is a photo. Putting a car under a stranger
 * who might be walking is a guess about how they are travelling, and this map
 * does not guess.
 */

import { normalizeHeading, vehicleColorHex, vehicleSvg } from "./farqAvatar";

export type UserMarkerState = {
	avatar: string | null;
	vehicleColor: string | null;
	/** Degrees clockwise from north, or null when the device did not report one. */
	heading: number | null;
	isRTL: boolean;
};

export const USER_MARKER_CLASS = "farq-user-marker";

function el(tag: string, className: string): HTMLElement {
	const node = document.createElement(tag);
	node.className = className;
	return node;
}

/** Build the element once; `updateUserMarker` keeps it current afterwards. */
export function buildUserMarker(state: UserMarkerState): HTMLElement {
	const root = el("div", USER_MARKER_CLASS);
	root.dataset.testid = "farq-map-user-marker";

	const vehicle = el("div", "farq-user-vehicle");
	vehicle.dataset.testid = "farq-map-user-vehicle";
	root.append(vehicle);

	const pulse = el("div", "farq-user-pulse");
	pulse.dataset.testid = "farq-map-user-pulse";
	pulse.append(
		el("span", "farq-user-pulse-ring"),
		el("span", "farq-user-pulse-ring farq-user-pulse-ring--delay"),
		el("span", "farq-user-pulse-core"),
	);
	root.append(pulse);

	const avatar = el("div", "farq-user-avatar");
	avatar.dataset.testid = "farq-map-user-avatar";
	root.append(avatar);

	const label = el("span", "farq-user-here");
	root.append(label);

	updateUserMarker(root, state);
	return root;
}

/**
 * Bring an existing marker up to date. Called on every position update, so it
 * touches only what changed — swapping the image element on every GPS fix would
 * make the photo flicker at walking pace.
 */
export function updateUserMarker(root: HTMLElement, state: UserMarkerState): void {
	const { avatar, vehicleColor, isRTL } = state;
	const heading = normalizeHeading(state.heading);
	const personalised = Boolean(avatar);

	root.classList.toggle("is-personalised", personalised);

	const vehicleNode = root.querySelector<HTMLElement>(".farq-user-vehicle");
	if (vehicleNode) {
		const hex = vehicleColorHex(vehicleColor);
		if (personalised) {
			if (vehicleNode.dataset.color !== hex) {
				vehicleNode.innerHTML = vehicleSvg(hex);
				vehicleNode.dataset.color = hex;
			}
			/* No heading means the device is not moving, or will not say. The car
			 * keeps its last known bearing rather than snapping to north, because
			 * north is a claim and "unchanged" is not. */
			if (heading !== null) {
				vehicleNode.style.transform = `rotate(${heading}deg)`;
				vehicleNode.dataset.heading = String(Math.round(heading));
			} else if (!vehicleNode.dataset.heading) {
				vehicleNode.style.transform = "";
				vehicleNode.removeAttribute("data-heading");
			}
			vehicleNode.hidden = false;
		} else {
			vehicleNode.hidden = true;
			vehicleNode.innerHTML = "";
			delete vehicleNode.dataset.color;
		}
	}

	const pulse = root.querySelector<HTMLElement>(".farq-user-pulse");
	if (pulse) pulse.hidden = personalised;

	const avatarNode = root.querySelector<HTMLElement>(".farq-user-avatar");
	if (avatarNode) {
		if (personalised) {
			let img = avatarNode.querySelector("img");
			if (!img) {
				img = document.createElement("img");
				img.alt = "";
				img.setAttribute("aria-hidden", "true");
				img.decoding = "async";
				avatarNode.append(img);
			}
			if (img.src !== avatar) img.src = avatar as string;
			avatarNode.hidden = false;
		} else {
			avatarNode.hidden = true;
			avatarNode.replaceChildren();
		}
	}

	const label = root.querySelector<HTMLElement>(".farq-user-here");
	if (label) label.textContent = isRTL ? "أنت هنا" : "You are here";
}
