#!/bin/sh
# Send a debugkeys script to the running app on the simulator (debug builds).
# usage: scripts/sim-keys.sh <simulator udid> "<delay ms>:<key>[+<key>],..."
#        scripts/sim-keys.sh <simulator udid> -t "text to type"   (letters/digits/space/./\/ only)
set -eu
SIM=$1
shift
DATA="$(xcrun simctl get_app_container "$SIM" net.mikuta0407.np21ios data)/Documents/sdlnp21kai"
if [ "$1" = "-t" ]; then
	script=$(printf '%s' "$2" | awk '{
		n = split($0, c, "");
		out = "";
		for (i = 1; i <= n; i++) {
			k = (c[i] == " ") ? "Space" : toupper(c[i]);
			out = out (out == "" ? "" : ",") "120:" k;
		}
		print out;
	}')
else
	script=$1
fi
printf '%s\n' "$script" > "$DATA/debugkeys.txt.tmp"
mv "$DATA/debugkeys.txt.tmp" "$DATA/debugkeys.txt"
