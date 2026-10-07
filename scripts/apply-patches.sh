#!/bin/sh
# Apply local patches to the vendored submodules.
# Run after `git submodule update --init`. Already-applied patches are skipped.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)

for dir in "$ROOT"/patches/*/; do
	name=$(basename "$dir")
	target="$ROOT/vendor/$name"
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
