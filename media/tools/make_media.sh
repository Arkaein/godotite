#!/usr/bin/env bash
# Redraws every generated image in media/ from icon.svg and the three screenshots.
#
#   media/tools/make_media.sh            (from anywhere)
#
# Needs python3 with Pillow, ImageMagick 6 (convert) and the DejaVu fonts. media/README.md lists
# what each image is for and how the screenshots are taken.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
media="$root/media"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Project icon, only when asked: icon.svg is committed and changes rarely.
if [[ "${1:-}" == "--icon" ]]; then
	python3 "$media/tools/make_icon.py" "$root/icon.svg"
fi

# Asset Library icon: square PNG, 256 px.
convert -background none -density 576 "$root/icon.svg" -resize 256x256 "$media/icon.png"

# Asset Store thumbnail: 16:9, the icon at 560 px centered on the icon's backdrop.
convert -background none -density 1152 "$root/icon.svg" -resize 560x560 +repage "$tmp/icon560.png"
convert -size 1280x720 xc:'#1f2a44' "$tmp/icon560.png" -gravity center -composite +repage \
	"$media/thumbnail.png"

# README hero and GitHub social preview, from the screenshots.
python3 "$media/tools/make_banners.py" "$media"

identify "$media"/*.png | awk '{print $1, $3}'
