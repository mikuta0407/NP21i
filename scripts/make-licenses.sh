#!/bin/sh
# Collect the license texts of the code built into the app (UTF-8) for the
# in-app license screen. Run by the build (CMakeLists.txt, POST_BUILD).
# usage: scripts/make-licenses.sh <output file>
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NP2="$ROOT/vendor/NP2kai"
L="$NP2/LICENSES"
OUT=$1

section() {
	printf '\n==============================================================\n%s\n==============================================================\n\n' "$1"
}
# NP2 license files are Shift_JIS
sjis() {
	iconv -f CP932 -t UTF-8 "$1" | tr -d '\r'
}

{
	printf '%s\n' "NP21i は Neko Project II / Neko Project 21/W / NP2kai を元にしています。"
	printf '%s\n' "以下は、このアプリに含まれるソフトウェアのライセンスです。"

	printf '%s\n' "ディスクに組み込む HOSTDRV.COM も Neko Project II（np2tool）のものです。"

	section "NP21i (mikuta0407)"
	cat "$ROOT/LICENSE"
	section "Neko Project II / Neko Project 21/W (NP2 developer team)"
	sjis "$L/LICENSE.TXT"
	section "NP2kai (AZO)"
	tr -d '\r' < "$NP2/LICENSE"
	for f in I386C I386C-FPU I386C-SIMD GD54XX GA1280A LGY98 LIO; do
		section "$f"
		sjis "$L/LICENSE-$f.TXT"
	done
	section "MAME (BSD-3-Clause portions)"
	sjis "$L/mamebsd/LICENSE-MAME-BSD.TXT"
	section "Berkeley SoftFloat Release 3e"
	tr -d '\r' < "$L/softfloat3/COPYING.txt"
	section "Simple DirectMedia Layer (SDL)"
	tr -d '\r' < "$ROOT/vendor/SDL/LICENSE.txt"
} > "$OUT"
