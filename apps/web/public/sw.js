/*
 * سَرى البارق — the one service worker. Two jobs, one registration at "/":
 *
 * 1. Push (outings): shows the notification for a note, a voice clip, an SOS
 *    or «أنا بخير», and opens the outing when it is tapped. Positions are
 *    never pushed.
 * 2. Offline areas («حفظ المنطقة دون اتصال»): serves an area the user saved
 *    when the network is gone. It writes nothing on its own: the page fills
 *    the cache when (and only when) the user saves an area. Here we only read,
 *    and only while at least one area is saved — otherwise every request goes
 *    straight to the network, untouched, exactly as with no worker at all:
 *      - /api/* and /_api/* (and every non-GET): never touched.
 *      - Mapbox (api.mapbox.com): network first; the saved copy if the network
 *        fails or is too slow (a weak desert signal).
 *      - Page loads: network first; the saved app shell offline.
 *      - /assets/* (hashed, immutable): the saved copy if there is one.
 *
 * The page keeps it registered while push is subscribed OR an area is saved
 * (see src/lib/sw/worker.ts); deleting the last area clears the offline cache
 * but never unregisters a worker that push still needs.
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

/**
 * The combined rule: a request goes through the offline logic only when it is
 * a route we serve AND an offline area exists. hasArea === null means "not
 * known yet" (the worker just started): look it up before deciding.
 */
function offlineDecision(route, hasArea) {
	if (route === "skip") return "skip";
	if (hasArea === false) return "skip";
	if (hasArea === null || hasArea === undefined) return "check";
	return route;
}

/** Push payload → showNotification arguments. Pure, for tests. */
function notificationFor(data) {
	data = data || {};
	var sos = data.type === "sos";
	var url = typeof data.url === "string" && data.url.charAt(0) === "/" ? data.url : "/outings";
	return {
		title: data.title || "سَرى البارق",
		options: {
			body: data.body || "",
			tag: data.tag || (sos ? "sary-sos" : "sary-note"),
			renotify: true,
			requireInteraction: sos,
			lang: "ar",
			dir: "rtl",
			icon: "/icons/icon-192.png",
			badge: "/icons/icon-192.png",
			vibrate: sos ? [300, 120, 300, 120, 600] : [140, 70, 140],
			data: { url: url, type: data.type || null, outing_id: data.outing_id || null },
		},
	};
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

function serve(route, req) {
	if (route === "page") return page(req);
	if (route === "asset") return asset(req);
	return networkThenCache(req);
}

if (typeof self !== "undefined" && self && self.addEventListener) {
	/* Whether an offline area exists. null until known; the page tells us when it changes. */
	var hasArea = null;
	var refreshHasArea = function () {
		if (typeof caches === "undefined") {
			hasArea = false;
			return Promise.resolve(false);
		}
		return caches.has(CACHE).then(
			function (v) {
				hasArea = v;
				return v;
			},
			function () {
				hasArea = false;
				return false;
			},
		);
	};

	self.addEventListener("install", function () {
		self.skipWaiting();
	});
	self.addEventListener("activate", function (e) {
		e.waitUntil(Promise.all([self.clients.claim(), refreshHasArea()]));
	});
	self.addEventListener("message", function (e) {
		var d = e.data || {};
		if (d.type === "sary-offline") {
			if (typeof d.on === "boolean") hasArea = d.on;
			else refreshHasArea();
		}
	});

	self.addEventListener("fetch", function (e) {
		var req = e.request;
		var route = routeFor(req.method, req.url, req.mode, self.location.origin);
		var decision = offlineDecision(route, hasArea);
		if (decision === "skip") return;
		if (decision === "check") {
			e.respondWith(
				refreshHasArea().then(function (has) {
					return has ? serve(route, req) : fetch(req);
				}),
			);
			return;
		}
		e.respondWith(serve(decision, req));
	});

	self.addEventListener("push", function (event) {
		var data = {};
		try {
			data = event.data ? event.data.json() : {};
		} catch (err) {
			data = { body: event.data ? event.data.text() : "" };
		}
		var n = notificationFor(data);
		/* iOS requires every push to show a notification, so there is always one. */
		event.waitUntil(self.registration.showNotification(n.title, n.options));
	});

	self.addEventListener("notificationclick", function (event) {
		event.notification.close();
		var url = new URL((event.notification.data && event.notification.data.url) || "/outings", self.location.origin);
		event.waitUntil(
			self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(function (wins) {
				/* Prefer a window already on that outing, then any window of the app. */
				var exact = wins.find(function (w) {
					return new URL(w.url).pathname === url.pathname;
				});
				if (exact) return exact.focus();
				var any = wins.find(function (w) {
					return new URL(w.url).origin === url.origin;
				});
				if (any && any.navigate) {
					return any
						.focus()
						.then(function () {
							return any.navigate(url.href);
						})
						.catch(function () {
							/* an uncontrolled window cannot be navigated from here: open a new one */
							return self.clients.openWindow(url.href);
						});
				}
				return self.clients.openWindow(url.href);
			}),
		);
	});
}

/* For tests (node/vitest): the pure functions. */
if (typeof module !== "undefined") module.exports = { keyFor: keyFor, routeFor: routeFor, offlineDecision: offlineDecision, notificationFor: notificationFor, CACHE: CACHE };
