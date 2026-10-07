#!/bin/sh
# (Re)launch the app on the simulator and start Recomposer GS (A:\RC30\RC30G).
# Extra environment for the app can be passed as SIMCTL_CHILD_* variables.
# usage: scripts/sim-boot-recomposer.sh <simulator udid>
set -eu
SIM=$1
xcrun simctl terminate "$SIM" net.mikuta0407.np21ios 2>/dev/null || true
SIMCTL_CHILD_NP2_DEBUG_MIDIMON=1 \
SIMCTL_CHILD_NP2_DEBUG_KEYS="25000:Left Shift+F9,3000:C,150:D,150:Space,150:R,150:C,150:3,150:0,150:Return,1000:R,150:C,150:3,150:0,150:G,150:Return" \
	xcrun simctl launch "$SIM" net.mikuta0407.np21ios >/dev/null
sleep 48
