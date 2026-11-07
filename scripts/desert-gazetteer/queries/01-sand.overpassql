[out:json][timeout:300];
area["ISO3166-1"="SA"][admin_level=2]->.sa;
nwr["natural"~"^(sand|desert|dune)$"]["name"](area.sa);
out geom qt;
