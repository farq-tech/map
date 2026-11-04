#!/usr/bin/env bash
# End-to-end check of the app's network layer (REST + WebSocket) against the live API,
# compiled for macOS from the app's own sources. Creates a throwaway identity and
# outing, starts it, turns sharing on explicitly, sends one fix and one note over
# the socket, then ends it.
set -euo pipefail
cd "$(dirname "$0")/../Sources"
dir="$(mktemp -d)"
cp ../scripts/live-smoke-main.swift "$dir/main.swift"
xcrun swiftc -swift-version 5 -o "$dir/live-smoke" Core/*.swift Net/LiveChannel.swift Net/OutingsAPI.swift "$dir/main.swift"
"$dir/live-smoke"
