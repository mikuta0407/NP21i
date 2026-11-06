#!/bin/sh
# Build the app for the device (Release, unsigned) and package it as an IPA,
# e.g. to install with LiveContainer.
#
# usage: scripts/make-ipa.sh [--sdl 2|3] [output dir]
#   default: SDL3, dist/NP21iOS-<rev>[-dirty]-sdl<n>.ipa
#
# The build directory (build/ipa-sdl<n>) belongs to this script: it is made
# again when it was configured for another checkout (e.g. the repository moved).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SDL=3
if [ "${1:-}" = "--sdl" ]; then
	SDL=$2
	shift 2
fi
OUT=${1:-"$ROOT/dist"}
case "$SDL" in
	2|3) ;;
	*) echo "--sdl must be 2 or 3" >&2; exit 1 ;;
esac

BUILD="$ROOT/build/ipa-sdl$SDL"
if [ -f "$BUILD/CMakeCache.txt" ] \
	&& ! grep -qx "CMAKE_HOME_DIRECTORY:INTERNAL=$ROOT" "$BUILD/CMakeCache.txt"; then
	echo "build directory from another checkout, making it again"
	rm -rf "$BUILD"
fi

"$ROOT/scripts/apply-patches.sh"
cmake -S "$ROOT" -B "$BUILD" -G Xcode -DCMAKE_SYSTEM_NAME=iOS -DNP21_SDL="$SDL" >/dev/null
xcodebuild -project "$BUILD/NP21iOS.xcodeproj" -scheme NP21iOS -configuration Release \
	-sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$BUILD/dd" \
	CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
	-quiet build

REV=$(git -C "$ROOT" rev-parse --short HEAD)
if [ -n "$(git -C "$ROOT" status --porcelain --ignore-submodules=dirty)" ]; then
	REV="$REV-dirty"
fi
IPA="$OUT/NP21iOS-$REV-sdl$SDL.ipa"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/Payload"
cp -R "$BUILD/Release-iphoneos/NP21iOS.app" "$TMP/Payload/"
mkdir -p "$OUT"
(cd "$TMP" && zip -qry app.ipa Payload)
mv "$TMP/app.ipa" "$IPA"
echo "$IPA"
