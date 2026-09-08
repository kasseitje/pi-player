#!/bin/bash
# Normalise a folder of source clips into uniform, audio-free 1080p H.264 files
# suitable for looping on a Pi 4. Run this on your workstation, not the Pi.
#
#   ./prepare-media.sh /path/to/source /path/to/usb-stick
#
# Mismatched resolutions or frame rates between playlist items cause a visible
# mode-change flash on the display when mpv advances; normalising avoids that.
set -euo pipefail

SRC="${1:?usage: prepare-media.sh SRCDIR DSTDIR}"
DST="${2:?usage: prepare-media.sh SRCDIR DSTDIR}"

WIDTH=1920
HEIGHT=1080
FPS=30
CRF=20
PRESET=medium

mkdir -p "$DST"

shopt -s nullglob nocaseglob
n=0
for f in "$SRC"/*.{mp4,mkv,mov,avi,m4v,webm}; do
    n=$((n+1))
    out=$(printf "%s/%03d_%s.mp4" "$DST" "$n" "$(basename "${f%.*}" | tr ' ' '_')")
    echo ">> $f -> $out"
    ffmpeg -hide_banner -loglevel warning -y -i "$f" \
        -vf "scale=${WIDTH}:${HEIGHT}:force_original_aspect_ratio=decrease,pad=${WIDTH}:${HEIGHT}:(ow-iw)/2:(oh-ih)/2,fps=${FPS}" \
        -c:v libx264 -profile:v high -level 4.1 -pix_fmt yuv420p \
        -preset "$PRESET" -crf "$CRF" \
        -g $((FPS*2)) -movflags +faststart \
        -an \
        "$out"
done

# Images are copied through untouched; mpv decodes them fine and re-encoding
# stills to video is only worth it if you need per-image durations.
for f in "$SRC"/*.{jpg,jpeg,png}; do
    n=$((n+1))
    out=$(printf "%s/%03d_%s.%s" "$DST" "$n" "$(basename "${f%.*}" | tr ' ' '_')" "${f##*.}")
    echo ">> $f -> $out (copy)"
    cp "$f" "$out"
done

echo
echo "Wrote $n items to $DST"
echo "Playback order follows filename sort. Rename the numeric prefixes to reorder,"
echo "or drop a playlist.m3u in $DST to control the order explicitly."
