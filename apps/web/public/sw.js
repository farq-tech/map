/*
 * Sary Albarq offline service worker — serves an area the user saved for
 * offline («حفظ المنطقة دون اتصال») when the network is gone.
 *
 * It is registered only after someone saves an area, and unregistered when
 * the last area is deleted, so ordinary online use never goes through it.
 * It writes nothing on its own: the page fills the cache when (and only
 * when) the user saves an area. Here we only read:
 *   - /api/* and /_api/* (and every non-GET): never touched — straight to the network.
 *   - Mapbox (api.mapbox.com): network first; the saved copy if the network
 *     fails or is too slow (a weak desert signal).
 *   - Page loads: network first; the saved app shell offline.
 *   - /assets/* (hashed, immutable): the saved copy if there is one.
 * Keep keyFor() in step with cacheKey() in src/lib/offline/tiles.ts.
 */
"use strict";

var CACHE = "sary-offline-v1";
var SLOW_MS = 4000;

function keyFor(url) {
	try {
		var u = new URL(url);
		u.searchParams.delete("access_token");
		u.searchParams.delete("sku");
		u.searchParams.sort();
		return u.toString();
	} catch (e) {
		return url;
	}
}

/** What to do with a request: "skip" (do not intercept), "mapbox", "page", "asset". */
function routeFor(method, url, mode, origin) {
	if (method !== "GET") return "skip";
	var u;
	try {
		u = new URL(url);
	} catch (e) {
		return "skip";
	}
	if (u.origin === origin) {
		if (/^\/(_?api)(\/|$)/.test(u.pathname)) return "skip";
		if (u.pathname === "/sw.js") return "skip";
		if (mode === "navigate") return "page";
		if (/^\/(assets|models|brand|platform_icons)\//.test(u.pathname) || /\.(svg|png|webp|glb)$/.test(u.pathname)) return "asset";
		return "skip";
	}
	if (u.hostname === "api.mapbox.com") {
		/* Session and telemetry calls are about this visit; never served from a copy. */
		if (/^\/(map-sessions|events)\//.test(u.pathname)) return "skip";
		return "mapbox";
	}
	if (u.hostname === "fonts.googleapis.com" || u.hostname === "fonts.gstatic.com") return "mapbox";
	return "skip";
}

function fromCache(url) {
	return caches.open(CACHE).then(function (c) {
		return c.match(keyFor(url), { ignoreVary: true, ignoreSearch: false });
	});
}

/* Network first; if it fails, or is still waiting after SLOW_MS and a saved copy exists, the copy. */
function networkThenCache(request) {
	return new Promise(function (resolve, reject) {
		var done = false;
		var finish = function (r) {
			if (!done) {
				done = true;
				resolve(r);
			}
		};
		var timer = setTimeout(function () {
			fromCache(request.url).then(function (hit) {
				if (hit) finish(hit);
			});
		}, SLOW_MS);
		fetch(request).then(
			function (r) {
				clearTimeout(timer);
				finish(r);
			},
			function (err) {
				clearTimeout(timer);
				fromCache(request.url).then(function (hit) {
					if (hit) finish(hit);
					else if (!done) {
						done = true;
						reject(err);
					}
				});
			},
		);
	});
}

function page(request) {
	return fetch(request).catch(function (err) {
		/* Single-page app: every route is the same shell. */
		return fromCache(self.location.origin + "/").then(function (hit) {
			if (hit) return hit;
			throw err;
		});
	});
}

function asset(request) {
	return fromCache(request.url).then(function (hit) {
		return hit || fetch(request);
	});
}

if (typeof self !== "undefined" && self.addEventListener && typeof caches !== "undefined") {
	self.addEventListener("install", function () {
		self.skipWaiting();
	});
	self.addEventListener("activate", function (e) {
		e.waitUntil(self.clients.claim());
	});
	self.addEventListener("fetch", function (e) {
		var req = e.request;
		var route = routeFor(req.method, req.url, req.mode, self.location.origin);
		if (route === "skip") return;
		if (route === "page") e.respondWith(page(req));
		else if (route === "asset") e.respondWith(asset(req));
		else e.respondWith(networkThenCache(req));
	});
}

/* For tests (node/vitest): the pure routing and key functions. */
if (typeof module !== "undefined") module.exports = { keyFor: keyFor, routeFor: routeFor, CACHE: CACHE };
