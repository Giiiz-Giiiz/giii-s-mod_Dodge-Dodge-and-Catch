#!/bin/sh
# Everything that can be checked without the device:
#   unit tests (host Lua 5.4), glyph coverage, giii lint/build, simulator scenarios.
# GIIICON points at a GiiiCon checkout (default ../GiiiCon) with build/host/giii_sim built:
#   cmake -S . -B build/host -G Ninja && cmake --build build/host --target giii_sim
set -eu
cd "$(dirname "$0")/.."
GIIICON=${GIIICON:-../GiiiCon}
LUA=${LUA:-$(command -v lua5.4 || command -v lua)}

want=$(sed -n 's/.*"commit": "\([0-9a-f]*\)".*/\1/p' giiicon.lock)
have=$(git -C "$GIIICON" rev-parse HEAD 2>/dev/null || echo unknown)
[ "$want" = "$have" ] || echo "note: GiiiCon is at $have, giiicon.lock pins $want"

"$LUA" tests/run.lua
python3 scripts/check_glyphs.py --giiicon "$GIIICON"
(cd "$GIIICON" && uv run --quiet --project tools giii lint "$OLDPWD/app")
python3 tests/sim/run_sim.py --giiicon "$GIIICON" "$@"
