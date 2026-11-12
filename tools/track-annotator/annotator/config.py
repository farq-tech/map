"""Paths, constants and secret loading.

The Mapbox PUBLIC token is read from the environment or from a git-ignored
``.env.local`` and is never printed, logged, or written to any output file.
"""
from __future__ import annotations

import os
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = Path(os.environ.get("ANNOTATOR_DATA", ROOT / "data")).expanduser()
SAMPLES_DIR = DATA_DIR / "samples"
CACHE_DIR = DATA_DIR / "cache" / "tiles"
BUDGET_FILE = DATA_DIR / "cache" / "budget.json"
BATCH_DIR = DATA_DIR / "batches"
EXPORT_DIR = Path(os.environ.get("ANNOTATOR_EXPORTS", ROOT / "exports")).expanduser()
CONFIG_DIR = ROOT / "config"
STATIC_DIR = ROOT / "static"

# Read-only extra tile caches (same file naming: {z}_{x}_{y}@2x.jpg). The earlier
# sat-tracks-sample rounds already hold z17@2x tiles around the study areas.
_default_fallback = "~/code/map-wt/sat-tracks-sample/tiles"
TILE_FALLBACK_DIRS = [
    Path(p).expanduser()
    for p in os.environ.get("TILE_FALLBACK_DIRS", _default_fallback).split(os.pathsep)
    if p
]

# Imagery. z17 @2x is the finest REAL resolution Mapbox serves here; z18 is only upscaled.
NATIVE_ZOOM = 17
TILE_PX = 512  # @2x
DAILY_TILE_BUDGET = int(os.environ.get("MAPBOX_DAILY_BUDGET", "600"))

# Taxonomy
TRACK_TYPES = {
    "sandy": "رملي",
    "dirt": "ترابي",
    "rocky": "صخري",
    "mixed": "مختلط",
    "winding": "متعرج",
    "faint": "أثر مركبات خافت",
}
TYPE_INDEX = {k: i + 1 for i, k in enumerate(TRACK_TYPES)}  # class mask value per type
CLARITY = {1: "واضح", 2: "متوسط", 3: "خافت", 4: "شبه خفي"}
TERRAIN = {
    "flat_sand": "سهل رملي مسطح",
    "dunes": "كثبان/نفود",
    "gravel_plain": "سهل حصوي",
    "rocky_hills": "تلال/هضاب صخرية",
    "wadi": "وادٍ/مجرى",
    "sabkha": "سبخة",
    "mixed": "مختلط",
}
# "ليس درب": hard negatives (things that look like a track but must NOT be learned as one)
NEGATIVE_CATEGORIES = {
    "fence": "سياج/سور",
    "pipeline": "أنبوب/خط خدمات",
    "wadi": "مجرى وادٍ",
    "pivot_circle": "دائرة ري محوري",
    "boundary": "حد/عقم أرض",
    "power_line": "خط كهرباء",
    "plain_road": "طريق عادي لا أريده",
    "other": "أخرى",
}
NEG_INDEX = {k: i + 1 for i, k in enumerate(NEGATIVE_CATEGORIES)}
NEGATIVE_WIDTH_M = 4.0
MASK_WIDTH_M_DEFAULT = 3.0
LICENSE_NOTE = {
    "status": "owner-declared",
    "holder": "owner",
    "note": "The owner declared he holds the imagery licences (Mapbox commercial satellite).",
}


def _read_env_file(path: Path, key: str) -> str | None:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return None
    m = re.search(rf"^\s*(?:export\s+)?{re.escape(key)}\s*=\s*['\"]?([^'\"\s#]+)", text, re.M)
    return m.group(1) if m else None


def mapbox_token() -> str:
    """Return the Mapbox public token (pk.*). Raises RuntimeError if absent. Never log it."""
    tok = os.environ.get("MAPBOX_ACCESS_TOKEN")
    if not tok:
        for base in [ROOT, *ROOT.parents][:5]:
            for name in (".env.local", ".env"):
                tok = _read_env_file(base / name, "MAPBOX_ACCESS_TOKEN")
                if tok:
                    break
            if tok:
                break
    if not tok:
        raise RuntimeError("MAPBOX_ACCESS_TOKEN غير موجود (ضعه في .env.local أو متغير البيئة)")
    if not tok.startswith("pk."):
        raise RuntimeError("المفتاح ليس مفتاح Mapbox عامًا (pk.*) — يُرفض لأسباب أمنية")
    return tok


def has_token() -> bool:
    try:
        mapbox_token()
        return True
    except RuntimeError:
        return False


def ensure_dirs() -> None:
    for d in (SAMPLES_DIR, CACHE_DIR, BATCH_DIR, EXPORT_DIR):
        d.mkdir(parents=True, exist_ok=True)
