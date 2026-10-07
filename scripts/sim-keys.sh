#!/bin/sh
# Send a debugkeys script to the running app on the simulator (debug builds).
# usage: scripts/sim-keys.sh <simulator udid> "<delay ms>:<key>[+<key>],..."
#        scripts/sim-keys.sh <simulator udid> -t "text to type"
#
# -t converts ASCII text to PC-98 (JIS layout) key positions, which is how the
# emulator maps SDL scancodes (106 table: e.g. ":" is the key right of ";", "\" is Yen = #137).
set -eu
SIM=$1
shift
DATA="$(xcrun simctl get_app_container "$SIM" net.mikuta0407.np21ios data)/Documents/sdlnp21kai"
if [ "$1" = "-t" ]; then
	script=$(printf '%s' "$2" | LC_ALL=C awk '
	BEGIN {
		# PC-98 JIS layout: character -> SDL scancode name at that key position
		k[" "] = "Space"; k["-"] = "-"; k["^"] = "="; k["\\"] = "#137"
		k["@"] = "["; k["["] = "]"; k[";"] = ";"; k[":"] = "'\''"; k["]"] = "\\"
		k[","] = ","; k["."] = "."; k["/"] = "/"; k["_"] = "#135"
		s["!"] = "1"; s["\""] = "2"; s["#"] = "3"; s["$"] = "4"; s["%"] = "5"
		s["&"] = "6"; s["'\''"] = "7"; s["("] = "8"; s[")"] = "9"; s["="] = "-"
		s["`"] = "["; s["{"] = "]"; s["+"] = ";"; s["*"] = "'\''"; s["}"] = "\\"
		s["<"] = ","; s[">"] = "."; s["?"] = "/"; s["|"] = "#137"
	}
	{
		n = split($0, c, "");
		out = "";
		for (i = 1; i <= n; i++) {
			ch = c[i];
			if (ch in k) key = k[ch];
			else if (ch in s) key = "Left Shift+" s[ch];
			else key = toupper(ch);
			out = out (out == "" ? "" : ",") "120:" key;
		}
		print out;
	}')
else
	script=$1
fi
printf '%s\n' "$script" > "$DATA/debugkeys.txt.tmp"
mv "$DATA/debugkeys.txt.tmp" "$DATA/debugkeys.txt"
