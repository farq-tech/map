'use strict';

/**
 * The district files are shipped data, and shipped data needs the same gate as
 * shipped code. Every assertion here is a defect we could otherwise deploy in
 * silence: a hole in a polygon shows a حي that swallows its neighbour, a
 * duplicate slug makes one حي unreachable through the router, and a coordinate
 * outside the country renders a shape nobody can find.
 *
 * These are the boundary rules an organization that maintains national admin
 * data enforces on its own imports: no overlap within a level, containment in
 * the parent, closed rings, unique ids, and a name in both languages.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const DIR = path.join(__dirname, '..', 'data', 'districts');

/** The land border of the country, generously. Anything outside is a defect. */
const KSA_BOUNDS = { minLng: 34.0, maxLng: 56.5, minLat: 15.5, maxLat: 33.0 };

const cityFiles = fs
	.readdirSync(DIR)
	.filter((f) => f.endsWith('.geojson'))
	.sort();

function ringsOf(geometry) {
	if (!geometry) return [];
	if (geometry.type === 'Polygon') return geometry.coordinates;
	if (geometry.type === 'MultiPolygon') return geometry.coordinates.flat();
	return [];
}

function bboxOf(feature) {
	let minLng = Infinity, minLat = Infinity, maxLng = -Infinity, maxLat = -Infinity;
	for (const ring of ringsOf(feature.geometry)) {
		for (const [lng, lat] of ring) {
			if (lng < minLng) minLng = lng;
			if (lat < minLat) minLat = lat;
			if (lng > maxLng) maxLng = lng;
			if (lat > maxLat) maxLat = lat;
		}
	}
	return { minLng, minLat, maxLng, maxLat };
}

test('district files exist and are the cities we claim to serve', () => {
	assert.ok(cityFiles.length >= 6, `expected the six shipped cities, found ${cityFiles.length}`);
});

for (const file of cityFiles) {
	const city = path.basename(file, '.geojson');
	const collection = JSON.parse(fs.readFileSync(path.join(DIR, file), 'utf8'));

	test(`${city} — district integrity`, async (t) => {
		await t.test('is a FeatureCollection with features in it', () => {
			assert.equal(collection.type, 'FeatureCollection');
			assert.ok(Array.isArray(collection.features) && collection.features.length > 0);
		});

		await t.test('every district has a unique slug id', () => {
			const seen = new Map();
			for (const f of collection.features) {
				const id = f.properties && f.properties.district_id;
				assert.ok(id, `${city}: a feature has no district_id`);
				assert.match(String(id), /^[a-z0-9-]+$/,
					`${city}: district_id ${JSON.stringify(id)} is not a slug — numeric ids lose precision through the router`);
				assert.ok(!seen.has(id),
					`${city}: duplicate district_id ${id} — one of the two is unreachable`);
				seen.set(id, f);
			}
		});

		await t.test('every district is named in both languages', () => {
			for (const f of collection.features) {
				const p = f.properties || {};
				assert.ok(String(p.name_ar || '').trim(),
					`${city}: ${p.district_id} has no Arabic name`);
				assert.ok(String(p.name_en || '').trim(),
					`${city}: ${p.district_id} has no English name`);
			}
		});

		await t.test('same-named districts are far apart, not duplicates of each other', () => {
			/* Two أحياء can legitimately share a name in different parts of a city —
			 * الشهداء appears twice in Riyadh, 16 km apart, with two official source
			 * codes. That is data, not a defect. Two shapes with one name sitting on
			 * top of each other would be a defect, so that is what this checks.
			 * The product-side consequence — a picker that shows one name twice with
			 * nothing to choose by — is handled by the ambiguity check below. */
			const { matchKey } = require('./arabic-text');
			const byName = new Map();
			for (const f of collection.features) {
				const key = matchKey(f.properties.name_ar);
				if (!key) continue;
				if (!byName.has(key)) byName.set(key, []);
				byName.get(key).push(f);
			}
			for (const [key, group] of byName) {
				if (group.length < 2) continue;
				for (let i = 0; i < group.length; i += 1) {
					for (let j = i + 1; j < group.length; j += 1) {
						const a = bboxOf(group[i]);
						const b = bboxOf(group[j]);
						const overlaps = a.minLng < b.maxLng && b.minLng < a.maxLng &&
							a.minLat < b.maxLat && b.minLat < a.maxLat;
						assert.ok(!overlaps,
							`${city}: ${group[i].properties.district_id} and ${group[j].properties.district_id} both normalize to ${JSON.stringify(key)} and their shapes overlap`);
					}
				}
			}
		});

		await t.test('every ambiguous name carries something to tell the two apart', () => {
			/* If two أحياء share a name, a person choosing from a list must be given a
			 * second fact — otherwise the picker offers the same word twice and the
			 * choice is a coin flip. */
			const { matchKey } = require('./arabic-text');
			const byName = new Map();
			for (const f of collection.features) {
				const key = matchKey(f.properties.name_ar);
				if (!key) continue;
				if (!byName.has(key)) byName.set(key, []);
				byName.get(key).push(f.properties);
			}
			for (const [key, group] of byName) {
				if (group.length < 2) continue;
				const hints = new Set(group.map((p) => String(p.name_en || '').trim().toLowerCase()));
				assert.equal(hints.size, group.length,
					`${city}: ${group.length} districts normalize to ${JSON.stringify(key)} but only ${hints.size} distinct English names to tell them apart`);
			}
		});

		await t.test('every ring is closed and has enough points to be a shape', () => {
			for (const f of collection.features) {
				const rings = ringsOf(f.geometry);
				assert.ok(rings.length > 0, `${city}: ${f.properties.district_id} has no rings`);
				for (const ring of rings) {
					assert.ok(ring.length >= 4,
						`${city}: ${f.properties.district_id} has a ring of ${ring.length} points`);
					const [firstLng, firstLat] = ring[0];
					const [lastLng, lastLat] = ring[ring.length - 1];
					assert.ok(firstLng === lastLng && firstLat === lastLat,
						`${city}: ${f.properties.district_id} has an unclosed ring`);
				}
			}
		});

		await t.test('every coordinate is two finite numbers inside the country', () => {
			/* A Z coordinate here once broke ring destructuring downstream, which is
			 * why the conversion pipeline pins -dim XY. */
			for (const f of collection.features) {
				for (const ring of ringsOf(f.geometry)) {
					for (const point of ring) {
						assert.equal(point.length, 2,
							`${city}: ${f.properties.district_id} has a ${point.length}-dimensional coordinate`);
						const [lng, lat] = point;
						assert.ok(Number.isFinite(lng) && Number.isFinite(lat),
							`${city}: ${f.properties.district_id} has a non-finite coordinate`);
						assert.ok(lng >= KSA_BOUNDS.minLng && lng <= KSA_BOUNDS.maxLng &&
							lat >= KSA_BOUNDS.minLat && lat <= KSA_BOUNDS.maxLat,
							`${city}: ${f.properties.district_id} has a coordinate outside the country: ${lng},${lat}`);
					}
				}
			}
		});

		await t.test('districts of one city sit within one city-sized area', () => {
			/* Catches a district from another city merged into the wrong file — the
			 * shape renders, the map flies somewhere unexpected, and nothing errors. */
			const boxes = collection.features.map(bboxOf);
			const span = {
				minLng: Math.min(...boxes.map((b) => b.minLng)),
				maxLng: Math.max(...boxes.map((b) => b.maxLng)),
				minLat: Math.min(...boxes.map((b) => b.minLat)),
				maxLat: Math.max(...boxes.map((b) => b.maxLat)),
			};
			const widthKm = (span.maxLng - span.minLng) * 111 * Math.cos((span.minLat * Math.PI) / 180);
			const heightKm = (span.maxLat - span.minLat) * 111;
			assert.ok(widthKm < 250 && heightKm < 250,
				`${city}: districts span ${Math.round(widthKm)}×${Math.round(heightKm)} km — too wide for one city`);
		});

		await t.test('bounding boxes do not stack implausibly, which would mean duplicated shapes', () => {
			/* Full polygon overlap is expensive; identical bounding boxes are the
			 * cheap signal for the same shape shipped twice under two ids. */
			const seen = new Map();
			for (const f of collection.features) {
				const b = bboxOf(f);
				const key = [b.minLng, b.minLat, b.maxLng, b.maxLat].map((n) => n.toFixed(5)).join(',');
				if (seen.has(key)) {
					assert.fail(`${city}: ${seen.get(key)} and ${f.properties.district_id} have an identical bounding box`);
				}
				seen.set(key, f.properties.district_id);
			}
		});
	});
}

test('every ambiguous name is given something to choose by', async (t) => {
	const { loadDistricts } = require('./city-districts');
	const { matchKey } = require('./arabic-text');

	for (const file of cityFiles) {
		const city = path.basename(file, '.geojson');
		await t.test(`${city}`, () => {
			const loaded = loadDistricts(city, { __fixture: true });
			assert.ok(loaded, `${city} failed to load`);
			const byName = new Map();
			for (const d of loaded.prepared) {
				const key = matchKey(d.name_ar);
				if (!key) continue;
				if (!byName.has(key)) byName.set(key, []);
				byName.get(key).push(d);
			}
			for (const [key, group] of byName) {
				if (group.length < 2) continue;
				const hints = group.map((d) => d.name_hint_ar);
				for (const d of group) {
					assert.ok(d.name_hint_ar,
						`${city}: ${d.id} shares the name ${JSON.stringify(key)} and carries no hint`);
				}
				assert.equal(new Set(hints).size, hints.length,
					`${city}: ${JSON.stringify(key)} appears ${group.length} times but its hints repeat: ${hints.join(' / ')}`);
			}
			/* A unique name must NOT carry a hint — the list stays clean where it can. */
			for (const [key, group] of byName) {
				if (group.length !== 1) continue;
				assert.equal(group[0].name_hint_ar, undefined,
					`${city}: ${group[0].id} has a unique name and should not be qualified`);
			}
		});
	}
});
