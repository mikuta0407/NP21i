#!/bin/sh
# Makes the app icon (ios/Assets.xcassets/AppIcon.appiconset/AppIcon.png)
# from NP2's cat (vendor/NP2kai/misc/np2.svg) on a blue background.
# Needs rsvg-convert (brew install librsvg). Run it again when the design
# changes; the PNG is committed, so a build does not need it.
set -eu

top=$(cd "$(dirname "$0")/.." && pwd)
src="$top/vendor/NP2kai/misc/np2.svg"
out="$top/ios/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

python3 - "$src" "$tmp/icon.svg" <<'EOF'
import re, sys
svg = open(sys.argv[1], encoding="utf-8").read()
root = re.search(r"<svg\b[^>]*>", svg)
ns = " ".join(re.findall(r'xmlns(?::\w+)?="[^"]*"', root.group(0)))
body = svg[root.end():svg.rindex("</svg>")]
# The cat fills 1024 * 0.76, a little below the middle (its feet are wider
# than its ears, so it looks centred that way).
size, x, y = 780, 122, 130
open(sys.argv[2], "w", encoding="utf-8").write(f'''<svg {ns} width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="np21bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#4f86e8"/>
      <stop offset="1" stop-color="#1d3f94"/>
    </linearGradient>
  </defs>
  <rect width="1024" height="1024" fill="url(#np21bg)"/>
  <svg x="{x}" y="{y}" width="{size}" height="{size}" viewBox="0 0 67.733331 67.733335">{body}</svg>
</svg>
''')
EOF

rsvg-convert -w 1024 -h 1024 "$tmp/icon.svg" -o "$tmp/icon.png"
# The App Store refuses an icon with an alpha channel: drop it through JPEG.
sips -s format jpeg -s formatOptions 100 "$tmp/icon.png" --out "$tmp/icon.jpg" >/dev/null
mkdir -p "$(dirname "$out")"
sips -s format png "$tmp/icon.jpg" --out "$out" >/dev/null
echo "$out"
