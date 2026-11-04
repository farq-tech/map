#!/usr/bin/env bash
# Capture app screens (demo data, no server) on a simulator.
#   scripts/app-shots.sh <udid> <out-name> [launch args...]
# Example:
#   scripts/app-shots.sh $UDID home-dark -demo -SaryScreen home -SaryScheme dark
# Build first:  xcodebuild -scheme SaryAlbarq -destination "id=$UDID" -derivedDataPath /tmp/sary-dd build
set -euo pipefail
UDID="$1"; NAME="$2"; shift 2
HERE="$(cd "$(dirname "$0")/.." && pwd)"
APP="${SARY_APP:-/tmp/claude-501/sary-ui-dd/Build/Products/Debug-iphonesimulator/SaryAlbarq.app}"
OUT="${SARY_OUT:-$HERE/docs/app-shots}"
mkdir -p "$OUT"
[ -n "${SARY_SKIP_INSTALL:-}" ] || xcrun simctl install "$UDID" "$APP"
xcrun simctl terminate "$UDID" sa.sary.albarq >/dev/null 2>&1 || true
xcrun simctl launch "$UDID" sa.sary.albarq "$@" >/dev/null
sleep "${SARY_WAIT:-3}"
xcrun simctl io "$UDID" screenshot --type=png "$OUT/$NAME.png" >/dev/null 2>&1
sips -s format jpeg -s formatOptions 82 -Z 1600 "$OUT/$NAME.png" --out "$OUT/$NAME.jpg" >/dev/null && rm "$OUT/$NAME.png"
echo "$OUT/$NAME.jpg"
