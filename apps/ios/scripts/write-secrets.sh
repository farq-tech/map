#!/usr/bin/env bash
# Rebuild apps/ios/Secrets.xcconfig from the Mapbox account's default public token.
#
# Needs a Mapbox secret token with tokens:read in ~/.netrc — the same one SPM
# uses to download the SDK. Nothing here is ever written into the repository.
set -euo pipefail
sk=$(awk '/machine api.mapbox.com/{f=1} f&&/password/{print $2; exit}' ~/.netrc)
[ -n "$sk" ] || { echo "no Mapbox token in ~/.netrc" >&2; exit 1; }
user=$(python3 -c "import base64,json,sys;p='$sk'.split('.')[1];p+='='*(-len(p)%4);print(json.loads(base64.urlsafe_b64decode(p))['u'])")
pk=$(curl -fsS "https://api.mapbox.com/tokens/v2/$user?access_token=$sk" \
  | python3 -c "import sys,json;print(next(t['token'] for t in json.load(sys.stdin) if t.get('usage')=='pk'))")
cd "$(dirname "$0")/.."
printf 'MAPBOX_PUBLIC_TOKEN = %s\n' "$pk" > Secrets.xcconfig
echo "wrote $(pwd)/Secrets.xcconfig"
