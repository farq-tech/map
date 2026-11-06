"""Pilot regions for «أماكن مقترحة للكشتة» (camp sites) and «مخطط دروب البر» (off-road routes).

Bounding boxes are (south, west, north, east) in degrees, WGS84.
The analysis grid is 2 arc-seconds (~56 m E-W x 62 m N-S at 25°N) for the camp-site model
and 3 arc-seconds (~85 x 93 m) for the route cost grid bundled in the app.
"""

REGIONS = {
    "thumamah": {
        "name": "الثمامة وشمال الرياض",
        "bbox": (25.0, 46.4, 25.4, 46.9),
    },
    "nafud": {
        "name": "النفود الكبير (جنوب حائل)",
        "bbox": (28.0, 41.0, 28.6, 41.8),
    },
    "dahna": {
        "name": "عروق الدهناء (طريق الشرقية)",
        # The Dahna sand belt where the Riyadh–Dammam highway crosses it (~47.6–47.9°E).
        "bbox": (24.85, 47.45, 25.25, 47.95),
    },
}

ANALYSIS_ARCSEC = 2   # camp-site model grid
ROUTE_ARCSEC = 3      # route cost grid (app bundle)


def grid_shape(bbox, arcsec):
    s, w, n, e = bbox
    rows = round((n - s) * 3600 / arcsec)
    cols = round((e - w) * 3600 / arcsec)
    return rows, cols
