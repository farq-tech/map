"""Static guards for the phone layout (real touch behaviour must be verified on a device)."""
import re
from pathlib import Path

S = Path(__file__).resolve().parent.parent / "static"
HTML = (S / "index.html").read_text()
CSS = (S / "style.css").read_text()
JS = (S / "app.js").read_text()


def test_viewport_meta_blocks_zoom_and_uses_safe_area():
    m = re.search(r'<meta name="viewport" content="([^"]+)"', HTML).group(1)
    assert "viewport-fit=cover" in m and "user-scalable=no" in m and "maximum-scale=1" in m


def test_no_rubber_band_no_double_tap_zoom_and_safe_areas():
    assert "overscroll-behavior:none" in CSS and "touch-action:manipulation" in CSS and "touch-action:none" in CSS
    assert "env(safe-area-inset-bottom)" in CSS and "env(safe-area-inset-top)" in CSS
    assert "gesturestart" in JS


def test_touch_targets_and_input_font_size():
    assert re.search(r"@media \(max-width:900px\)", CSS)
    assert "min-height:44px" in CSS
    assert re.search(r"select,textarea,input\[type=file\]\{font-size:16px", CSS)  # avoids iOS focus-zoom
    assert "iconSize: [44, 44]" in JS  # vertex handle hit area


def test_landscape_layout_and_crosshair_mode_present():
    assert "orientation:landscape" in CSS
    assert 'id="crosshair"' in HTML and 'id="btn-add"' in HTML and 'id="btn-delvtx"' in HTML
    assert "function addPoint" in JS and "S.aim" in JS
    assert "if (!isMobile()) finishDraft" in JS  # double-tap must not end drawing on phones


def test_rtl_kept_and_hidden_attr_wins():
    assert '<html lang="ar" dir="rtl">' in HTML and "[hidden]{display:none!important}" in CSS
