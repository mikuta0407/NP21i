#!/bin/sh
# Apply local patches to the vendored submodules.
# Run after `git submodule update --init`. Already-applied patches are skipped.
#
# --reset: discard the submodules' local changes first and apply all patches
#          again. Use it after switching branches, when the set of patches
#          differs (later patches depend on earlier ones).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
RESET=0
[ "${1:-}" = "--reset" ] && RESET=1

for dir in "$ROOT"/patches/*/; do
	name=$(basename "$dir")
	target="$ROOT/vendor/$name"
	[ -d "$target" ] || continue
	if [ $RESET = 1 ]; then
		git -C "$target" checkout -q -- .
		echo "reset: $name"
	fi
	for patch in "$dir"*.patch; do
		[ -e "$patch" ] || continue
		if git -C "$target" apply --reverse --check "$patch" 2>/dev/null; then
			echo "skip (already applied): $name/$(basename "$patch")"
		else
			git -C "$target" apply "$patch"
			echo "applied: $name/$(basename "$patch")"
		fi
	done
done
