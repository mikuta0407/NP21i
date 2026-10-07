#!/bin/sh
# Print the emulator's text screen (with highlight markers) from the running
# app on the simulator (debug builds). See ios/src/debugscreen.m.
# usage: scripts/sim-screen.sh <simulator udid>
set -eu
DATA="$(xcrun simctl get_app_container "$1" net.mikuta0407.np21ios data)/Documents/sdlnp21kai"
rm -f "$DATA/screen.txt"
touch "$DATA/debugscreen.req"
i=0
while [ ! -f "$DATA/screen.txt" ] && [ $i -lt 30 ]; do
	sleep 0.2
	i=$((i + 1))
done
cat "$DATA/screen.txt"
