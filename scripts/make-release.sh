#!/bin/sh
# Build a signed archive for App Store Connect (the App Store, or an
# alternative marketplace such as AltStore PAL after notarization), export
# it as an IPA, and optionally upload it.
#
# usage: scripts/make-release.sh --team <team id> [--version x.y] [--upload] [output dir]
#   default output: dist/release/NP21iOS-<version>-<build>/
#
# Needs a paid Apple Developer Program team (a Personal Team cannot export
# for App Store Connect). Signing is automatic: Xcode makes or downloads the
# certificate and profiles, so be signed in to the team in Xcode → Settings →
# Accounts, or give an App Store Connect API key in the environment:
#   ASC_KEY_PATH (the .p8 file), ASC_KEY_ID, ASC_ISSUER_ID
#
# The build number is the commit count, so every commit uploads as a new
# build. The version (CFBundleShortVersionString) comes from CMakeLists.txt
# unless --version is given. A dirty working tree is refused.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEAM=${NP21_TEAM:-}
VERSION=
UPLOAD=no
while [ $# -gt 0 ]; do
	case "$1" in
		--team) TEAM=$2; shift 2 ;;
		--version) VERSION=$2; shift 2 ;;
		--upload) UPLOAD=yes; shift ;;
		-*) echo "unknown option: $1" >&2; exit 1 ;;
		*) break ;;
	esac
done
if [ -z "$TEAM" ]; then
	echo "give the team id with --team (or NP21_TEAM)" >&2
	exit 1
fi
if [ -n "$(git -C "$ROOT" status --porcelain --ignore-submodules=dirty)" ]; then
	echo "commit the changes first: a release is built from a commit" >&2
	exit 1
fi

BUILDNUM=$(git -C "$ROOT" rev-list --count HEAD)
BUILD="$ROOT/build/release"
if [ -f "$BUILD/CMakeCache.txt" ] \
	&& ! grep -qx "CMAKE_HOME_DIRECTORY:INTERNAL=$ROOT" "$BUILD/CMakeCache.txt"; then
	echo "build directory from another checkout, making it again"
	rm -rf "$BUILD"
fi

AUTH=
if [ -n "${ASC_KEY_PATH:-}" ]; then
	AUTH="-authenticationKeyPath $ASC_KEY_PATH -authenticationKeyID $ASC_KEY_ID -authenticationKeyIssuerID $ASC_ISSUER_ID"
fi

"$ROOT/scripts/apply-patches.sh"
cmake -S "$ROOT" -B "$BUILD" -G Xcode -DCMAKE_SYSTEM_NAME=iOS -DNP21_SDL=3 >/dev/null
if [ -z "$VERSION" ]; then
	VERSION=$(sed -n 's/^set(NP21_VERSION "\(.*\)")$/\1/p' "$ROOT/CMakeLists.txt")
fi

OUT=${1:-"$ROOT/dist/release/NP21iOS-$VERSION-$BUILDNUM"}
ARCHIVE="$OUT/NP21iOS.xcarchive"
rm -rf "$ARCHIVE"
mkdir -p "$OUT"

# shellcheck disable=SC2086
xcodebuild -project "$BUILD/NP21iOS.xcodeproj" -scheme NP21iOS -configuration Release \
	-sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$BUILD/dd" \
	-archivePath "$ARCHIVE" -allowProvisioningUpdates $AUTH \
	CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM" \
	MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILDNUM" \
	-quiet archive

DEST=export
if [ "$UPLOAD" = yes ]; then
	DEST=upload
fi
cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>$DEST</string>
	<key>teamID</key>
	<string>$TEAM</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
EOF

# shellcheck disable=SC2086
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT" \
	-exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates $AUTH -quiet

if [ "$UPLOAD" = yes ]; then
	echo "uploaded $VERSION ($BUILDNUM) to App Store Connect"
else
	echo "$OUT/NP21iOS.ipa"
fi
