#!/bin/sh
# End-to-end real-time recording test with Recomposer GS on the simulator.
#   1. boot Recomposer, set track 1 to Rec, start recording
#   2. send notes to NP21 MIDI IN at <interval ms>
#   3. stop, play the track back and capture NP21 MIDI OUT
#   4. compare playback note intervals with the input intervals
# usage: scripts/sim-rec-test.sh <simulator udid> [notes=32] [interval ms=250] [timebase=48]
set -eu
SIM=$1
N=${2:-32}
IV=${3:-250}
TB=${4:-48}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DATA="$(xcrun simctl get_app_container "$SIM" net.mikuta0407.np21ios data)/Documents/sdlnp21kai"

"$ROOT/scripts/sim-boot-recomposer.sh" "$SIM"
if [ "$TB" != 48 ]; then
	# main screen: the cursor starts on TR.; TIMEBASE is 4 down, 1 right
	keys="100:Down,100:Down,100:Down,100:Down,100:Right"
	for d in $(printf '%s' "$TB" | fold -w1); do
		keys="$keys,150:$d"
	done
	"$ROOT/scripts/sim-keys.sh" "$SIM" "$keys,200:Return"
	sleep 4
fi
# RECORD screen: the cursor starts on track 1's Mode cell; 3 = Rec
"$ROOT/scripts/sim-keys.sh" "$SIM" "100:F1,2500:3"
sleep 4
"$ROOT/scripts/sim-keys.sh" "$SIM" "100:F10"
sleep 3

# distinct note numbers so input and playback can be paired
script=""
i=0
while [ $i -lt "$N" ]; do
	n=$(printf '%02x' $((36 + i % 60)))
	script="$script,$((IV - 100)):90 $n 64,100:80 $n 00"
	i=$((i + 1))
done
"$ROOT/scripts/sim-midiin.sh" "$SIM" "${script#,}"
sleep $(( (N * IV) / 1000 + 3 ))

# stop recording, then play from the top
"$ROOT/scripts/sim-keys.sh" "$SIM" "100:Escape"
sleep 3
mark=$(wc -l < "$DATA/midimon.log")
"$ROOT/scripts/sim-keys.sh" "$SIM" "100:F2,2500:Return"
sleep $(( (N * IV) / 1000 + 8 ))
"$ROOT/scripts/sim-keys.sh" "$SIM" "100:Escape"
sleep 1

cp "$DATA/midimon.log" "$ROOT/build/rec-test.log"
"$ROOT/scripts/sim-rec-analyze.py" "$ROOT/build/rec-test.log" "$mark"
