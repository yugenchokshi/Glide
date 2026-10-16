#!/usr/bin/env bash
# Full agent loop against real UI with a scripted (mock) model — no API key needed.
# Moves your real cursor in the bundled NB Fixture app.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
BIN=.build/debug
PORT=${PORT:-18734}
"$BIN/nb-mock-servers" llm "$PORT" & MOCK=$!
"$BIN/NBFixtureApp" & FIX=$!
trap 'kill $MOCK $FIX 2>/dev/null || true' EXIT
sleep 1.5
"$BIN/glidectl" run "Greet Ada in the NB Fixture app" --mock-url "http://127.0.0.1:$PORT/v1"
