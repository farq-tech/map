#!/usr/bin/env bash
# The CarPlay entitlements file must be the base file plus com.apple.developer.carplay-maps, nothing else.
set -euo pipefail
cd "$(dirname "$0")/../Sources/App"
keys() { plutil -convert json -o - "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); d.pop("com.apple.developer.carplay-maps",None); print(json.dumps(d,sort_keys=True))'; }
if [ "$(keys SaryAlbarq.entitlements)" != "$(keys SaryAlbarq-CarPlay.entitlements)" ]; then
  echo "SaryAlbarq-CarPlay.entitlements is out of sync with SaryAlbarq.entitlements" >&2; exit 1
fi
plutil -convert json -o - SaryAlbarq-CarPlay.entitlements | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("com.apple.developer.carplay-maps") is True else 1)'
echo "entitlements in sync"
