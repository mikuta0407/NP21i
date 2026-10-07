#!/bin/sh
# Tests ios/src/diskfs.c on the host: builds tests/dfstool, makes FAT12
# (PC-98 2HD, 1024-byte sectors) and FAT32 images with newfs_msdos, writes,
# reads back, deletes, and checks them with fsck_msdos.
# usage: tests/diskfs-test.sh
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
T="$WORK/dfstool"
clang -Wall -Wextra -g -fsanitize=address,undefined -o "$T" "$ROOT/tests/dfstool.c" "$ROOT/ios/src/diskfs.c"

head -c 300000 /dev/urandom > "$WORK/big.bin"
printf 'hello\r\n' > "$WORK/small.txt"

mkfile -n 1261568 "$WORK/fd.img"
newfs_msdos -F 12 -S 1024 -c 1 -r 1 -n 2 -e 192 -s 1232 -u 8 -h 2 -m 0xfe "$WORK/fd.img" >/dev/null 2>&1
mkfile -n 300m "$WORK/f32.img"
newfs_msdos -F 32 -S 512 -s 614400 -u 63 -h 16 "$WORK/f32.img" >/dev/null 2>&1

for img in fd.img f32.img; do
	I="$WORK/$img"
	"$T" "$I" mkdir 0 A
	"$T" "$I" mkdir 0 A/B
	"$T" "$I" put 0 A/B "$WORK/big.bin" >/dev/null
	"$T" "$I" put 0 A "$WORK/small.txt" "Long File Name.text" >/dev/null
	i=1
	while [ $i -le 100 ]; do
		"$T" "$I" put 0 / "$WORK/small.txt" "r$i.txt" >/dev/null
		i=$((i + 1))
	done
	"$T" "$I" cat 0 A/B/BIG.BIN | cmp - "$WORK/big.bin"
	"$T" "$I" put 0 / "$WORK/big.bin" r1.txt >/dev/null		# replace
	"$T" "$I" cat 0 R1.TXT | cmp - "$WORK/big.bin"
	"$T" "$I" mv 0 A/LONGFI~1.TEX SHORT.TXT
	"$T" "$I" rm 0 A/B/BIG.BIN
	"$T" "$I" rm 0 A/B
	if fsck_msdos -n "$I" 2>&1 | grep -E "Warning|Fix" | grep -v "files, .* free" ; then
		echo "FAIL: $img"
		exit 1
	fi
	echo "ok: $img ($("$T" "$I" info))"
done
