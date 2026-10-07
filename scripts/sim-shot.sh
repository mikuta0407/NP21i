#!/bin/sh
# Save a screenshot of the simulator, scaled down, to a file.
# usage: scripts/sim-shot.sh <simulator udid> <output.png> [max size]
set -eu
xcrun simctl io "$1" screenshot "$2" >/dev/null 2>&1
sips -Z "${3:-1400}" "$2" >/dev/null
