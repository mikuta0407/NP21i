#!/bin/sh
# Send MIDI to the running app's "NP21i MIDI IN" on the simulator (debug builds).
# usage: scripts/sim-midiin.sh <simulator udid> "<delay ms>:<hex bytes>,..."
#   e.g. scripts/sim-midiin.sh <udid> "0:90 3c 64,500:80 3c 00"
set -eu
DATA="$(xcrun simctl get_app_container "$1" net.mikuta0407.np21ios data)/Documents/sdlnp21kai"
printf '%s\n' "$2" > "$DATA/debugmidiin.txt.tmp"
mv "$DATA/debugmidiin.txt.tmp" "$DATA/debugmidiin.txt"
