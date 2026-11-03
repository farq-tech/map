#!/usr/bin/env bash
# End-to-end check of the app's network layer (REST + WebSocket) against the live API,
# compiled for macOS from the app's own sources. Creates a throwaway identity and
# outing, starts it, sends one fix and one note over the socket, then ends it.
set -euo pipefail
cd "$(dirname "$0")/../Sources"
out="$(mktemp -d)/live-smoke"
xcrun swiftc -swift-version 5 -o "$out" Core/*.swift Net/LiveChannel.swift Net/OutingsAPI.swift ../scripts/live-smoke-main.swift
"$out"
