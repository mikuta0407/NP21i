#!/bin/sh
# Apply local patches (patches/<name>/*.patch, in order) to vendor/<name>.
# Run after `git submodule update --init`.
#
# A submodule that already matches its patched state is left alone; an
# unmodified one gets all patches. Anything else (e.g. after switching to a
# branch with other patches) is an error unless --reset is given, which
# discards the submodule's local changes and applies all patches again.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
RESET=0
if [ "${1:-}" = "--reset" ]; then
	RESET=1
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Tree of HEAD with all patches applied, built in a scratch index.
patched_tree() {
	GIT_INDEX_FILE="$TMP/index" git -C "$1" read-tree HEAD
	for patch in "$2"*.patch; do
		[ -e "$patch" ] || continue
		GIT_INDEX_FILE="$TMP/index" git -C "$1" apply --cached "$patch"
	done
	GIT_INDEX_FILE="$TMP/index" git -C "$1" write-tree
}

# Tree of the working directory (tracked files), also in a scratch index.
work_tree() {
	GIT_INDEX_FILE="$TMP/work" git -C "$1" read-tree HEAD
	GIT_INDEX_FILE="$TMP/work" git -C "$1" add -u
	GIT_INDEX_FILE="$TMP/work" git -C "$1" write-tree
}

for dir in "$ROOT"/patches/*/; do
	name=$(basename "$dir")
	target="$ROOT/vendor/$name"
	[ -d "$target" ] || continue
	if [ "$(work_tree "$target")" = "$(patched_tree "$target" "$dir")" ]; then
		echo "up to date: $name"
		continue
	fi
	if ! git -C "$target" diff --quiet; then
		if [ $RESET = 0 ]; then
			echo "error: vendor/$name has other local changes; run with --reset to discard them" >&2
			exit 1
		fi
		git -C "$target" checkout -q -- .
		echo "reset: $name"
	fi
	for patch in "$dir"*.patch; do
		[ -e "$patch" ] || continue
		git -C "$target" apply "$patch"
		echo "applied: $name/$(basename "$patch")"
	done
done
