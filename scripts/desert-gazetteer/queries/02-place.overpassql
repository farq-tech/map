[out:json][timeout:300];
area["ISO3166-1"="SA"][admin_level=2]->.sa;
nwr["place"~"^(locality|region|area|plain)$"]["name"~"^(ال)?(روضة|روضه|روضات|رياض|فيضة|فيضه|فياض|فيضات|نفود|نفد|عرق|عروق|رملة|رمله|رملات|دهناء|طعس|نقا)( |$)|الدهناء|الربع الخالي|الثمامة|الثمامه"](area.sa);
out geom qt;
