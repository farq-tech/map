#!/usr/bin/env bash
# Capture Design Showcase screenshots on a simulator.
#   scripts/design-shots.sh <udid> <out-name> [showcase args...]
# Example:
#   scripts/design-shots.sh $UDID buttons-dark -SaryShowcaseSection buttons -SaryShowcaseScheme dark
# Build first:  xcodebuild -scheme SaryAlbarq -destination "id=$UDID" -derivedDataPath /tmp/sary-dd build
set -euo pipefail
UDID="$1"; NAME="$2"; shift 2
HERE="$(cd "$(dirname "$0")/.." && pwd)"
APP="${SARY_APP:-/tmp/claude-501/sary-dd/Build/Products/Debug-iphonesimulator/SaryAlbarq.app}"
OUT="$HERE/docs/design-shots"
mkdir -p "$OUT"
xcrun simctl install "$UDID" "$APP"
xcrun simctl terminate "$UDID" sa.sary.albarq >/dev/null 2>&1 || true
xcrun simctl launch "$UDID" sa.sary.albarq -SaryShowcase "$@" >/dev/null
sleep "${SARY_WAIT:-4}"
xcrun simctl io "$UDID" screenshot --type=png "$OUT/$NAME.png" >/dev/null 2>&1
# Commit-friendly size: JPEG, long edge 1600 px.
sips -s format jpeg -s formatOptions 82 -Z 1600 "$OUT/$NAME.png" --out "$OUT/$NAME.jpg" >/dev/null && rm "$OUT/$NAME.png"
echo "$OUT/$NAME.jpg"
