"""Gate 0: resolution + true-detail test. Compares z18 real detail vs z17 upsampled and z16 upsampled."""
import json, sys, cv2, numpy as np
sys.path.insert(0, __import__("os").path.dirname(__file__))
import tiles
LAT, LON = 25.50, 47.10   # densest OSM-track cell in Thumamah region
def hf(img):  # high-frequency energy: var of Laplacian on gray
    g = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY).astype(np.float32)
    return float(cv2.Laplacian(g, cv2.CV_32F).var())
out = {}
m18, meta18 = tiles.mosaic(LAT, LON, 18, 3, 3)
m17, meta17 = tiles.mosaic(LAT, LON, 17, 2, 2)
m16, meta16 = tiles.mosaic(LAT, LON, 16, 2, 2)
# crop z17 to the same ground area as the central z18 patch and upsample x2
fx, fy = tiles.ll2tile(LAT, LON, 18)
c = 512 * 1  # compare central 1024x1024 z18 region
cy, cx = int((fy - meta18["y0"]) * 512), int((fx - meta18["x0"]) * 512)
p18 = m18[cy-512:cy+512, cx-512:cx+512]
def same_area(meta, z):
    fx, fy = tiles.ll2tile(LAT, LON, z)
    cy, cx = int((fy - meta["y0"]) * 512), int((fx - meta["x0"]) * 512)
    s = 2 ** (18 - z); h = 512 // s
    return cv2.resize(m_by_z[z][cy-h:cy+h, cx-h:cx+h], (1024, 1024), interpolation=cv2.INTER_CUBIC)
m_by_z = {17: m17, 16: m16}
meta_by_z = {17: meta17, 16: meta16}
res = {}
for z, meta in ((18, meta18), (17, meta17), (16, meta16)):
    res[f"z{z}"] = dict(m_per_px_at2x=round(meta["mpp"], 3), m_per_px_256=round(meta["mpp"]*2, 3))
res["laplacian_var_same_ground_area"] = {
    "z18_native": hf(p18), "z17_upsampled_to_z18": hf(same_area(meta17, 17)), "z16_upsampled_to_z18": hf(same_area(meta16, 16))}
cv2.imwrite(__import__("os").path.join(__import__("os").path.dirname(__file__), "..", "out", "gate0_z18_vs_z17.jpg"),
            np.hstack([p18, same_area(meta17, 17)]), [cv2.IMWRITE_JPEG_QUALITY, 85])
res["tiles_fetched_this_run"] = tiles.N_FETCHED
print(json.dumps(res, indent=1))
