#!/bin/sh
# Copy ROMs / a disk image into the simulator app's data directory and
# generate np21kai.cfg from a Windows np21w ini (UTF-16 or UTF-8).
#
# usage: scripts/sim-setup-data.sh <simulator udid> <np21w dir> <ini file> <scsi hdd image>
#   e.g. scripts/sim-setup-data.sh 7366DAE6-... ~/software/win/np21w np21x64w.ini recomposer.hdd
#
# The app must have been installed (and launched once) on the simulator.
set -eu
SIM=$1
SRC=$2
INI=$3
HDD=$4
BUNDLE=net.mikuta0407.np21ios

DATA="$(xcrun simctl get_app_container "$SIM" "$BUNDLE" data)/Documents/sdlnp21kai"
mkdir -p "$DATA"

for f in BIOS.ROM FONT.ROM ITF.ROM SOUND.ROM; do
	[ -f "$SRC/$f" ] && cp "$SRC/$f" "$DATA/"
done
cp "$SRC/$HDD" "$DATA/"

if LC_ALL=C file "$SRC/$INI" | grep -q UTF-16; then
	CONV="iconv -f UTF-16LE -t UTF-8"
else
	CONV=cat
fi

# Take the [NekoProject21] section, drop host-specific paths / MIDI mappings,
# and point SCSI HDD0 at the copied image (relative to the data directory).
{
	echo "[NekoProject21kai]"
	$CONV "$SRC/$INI" | tr -d '\r' | LC_ALL=C sed -e '1s/^\xEF\xBB\xBF//' \
		| awk '/^\[/{ insec = ($0 == "[NekoProject21]"); next } insec' \
		| LC_ALL=C grep -v -E '^(HDfolder|FDfolder|bmap|fontfile|FDD.FILE|HDD.FILE|SCSIHDD.|IDE.FILE|CD.FILE|mpu98map|mpu98min|smpuma.|smpumi.)='
	echo "SCSIHDD0=$HDD"
} > "$DATA/np21kai.cfg"

echo "data dir: $DATA"
ls "$DATA"
