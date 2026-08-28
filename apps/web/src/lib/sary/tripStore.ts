/**
 * Personal trips stay on this device. No coordinates leave the tab
 * for analytics, and there is no multi-user trip API yet.
 */

import type { TripRecord } from "./trip";

const DB_NAME = "sary-albarq";
const STORE = "trips";

function openDb(): Promise<IDBDatabase> {
	return new Promise((resolve, reject) => {
		if (typeof indexedDB === "undefined") {
			reject(new Error("indexeddb_unavailable"));
			return;
		}
		const req = indexedDB.open(DB_NAME, 1);
		req.onupgradeneeded = () => {
			const db = req.result;
			if (!db.objectStoreNames.contains(STORE)) {
				db.createObjectStore(STORE, { keyPath: "id" });
			}
		};
		req.onsuccess = () => resolve(req.result);
		req.onerror = () => reject(req.error || new Error("indexeddb_open_failed"));
	});
}

export async function saveTrip(trip: TripRecord): Promise<void> {
	if (!trip?.id || !Array.isArray(trip.points)) {
		throw new Error("invalid_trip");
	}
	const db = await openDb();
	await new Promise<void>((resolve, reject) => {
		const tx = db.transaction(STORE, "readwrite");
		tx.oncomplete = () => resolve();
		tx.onerror = () => reject(tx.error || new Error("trip_save_failed"));
		tx.objectStore(STORE).put(trip);
	});
	db.close();
}

export async function loadTrip(id: string): Promise<TripRecord | null> {
	if (!id) return null;
	const db = await openDb();
	const row = await new Promise<TripRecord | undefined>((resolve, reject) => {
		const tx = db.transaction(STORE, "readonly");
		const req = tx.objectStore(STORE).get(id);
		req.onsuccess = () => resolve(req.result as TripRecord | undefined);
		req.onerror = () => reject(req.error || new Error("trip_load_failed"));
	});
	db.close();
	return row ?? null;
}

export async function listTrips(): Promise<TripRecord[]> {
	const db = await openDb();
	const rows = await new Promise<TripRecord[]>((resolve, reject) => {
		const tx = db.transaction(STORE, "readonly");
		const req = tx.objectStore(STORE).getAll();
		req.onsuccess = () => resolve((req.result as TripRecord[]) || []);
		req.onerror = () => reject(req.error || new Error("trip_list_failed"));
	});
	db.close();
	return rows.sort((a, b) => (b.startedAt || 0) - (a.startedAt || 0));
}
