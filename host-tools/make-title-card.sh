#!/bin/bash
# Render a looping title card matching the pi-player media conventions
# (1080p30, H.264 High, yuv420p, no audio, 2s GOP).
#
#   ./make-title-card.sh out.mp4 [logo.png] ["Headline"] ["Subline"] ["EYEBROW"] ["Footer"] [seconds]
#
# Pass "" for the logo to render without one. A logo with an alpha channel
# (PNG/SVG-exported-to-PNG) composites cleanly on the dark background; a JPEG
# with a white background will show as a white box.
#
# Text is passed via textfile= rather than text=, so apostrophes, colons and
# percent signs need no escaping. Duration must stay a multiple of the 2.5s
# pulse period for a seamless loop.
set -euo pipefail

OUT="${1:-fallback.mp4}"
LOGO="${2:-}"
HEADLINE="${3:-Insert your USB stick}"
SUBLINE="${4:-FAT32 or exFAT — videos and images in the root folder}"
EYEBROW="${5:-NO MEDIA DETECTED}"
FOOTER="${6:-Playback starts automatically}"
DURATION="${7:-10}"

LOGO_HEIGHT=250      # rendered height in px; width scales to preserve aspect
LOGO_Y=150           # top edge

FB=/usr/share/fonts/truetype/google-fonts/Poppins-Bold.ttf
FM=/usr/share/fonts/truetype/google-fonts/Poppins-Medium.ttf
FR=/usr/share/fonts/truetype/google-fonts/Poppins-Regular.ttf
[ -f "$FB" ] || FB=/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf
[ -f "$FM" ] || FM=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf
[ -f "$FR" ] || FR=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
printf '%s' "$EYEBROW"  > "$TMPD/eyebrow.txt"
printf '%s' "$HEADLINE" > "$TMPD/headline.txt"
printf '%s' "$SUBLINE"  > "$TMPD/subline.txt"
printf '%s' "$FOOTER"   > "$TMPD/footer.txt"

TEXT_CHAIN="
    drawtext=fontfile=${FM}:textfile=${TMPD}/eyebrow.txt:expansion=none:
      fontcolor=0x5b6b7f:fontsize=30:x=(w-text_w)/2:y=452:
      alpha='0.7+0.3*sin(2*PI*t/2.5)',
    drawtext=fontfile=${FB}:textfile=${TMPD}/headline.txt:expansion=none:
      fontcolor=0xf2f6fb:fontsize=104:x=(w-text_w)/2:y=522,
    drawbox=x=(iw-220)/2:y=682:w=220:h=4:color=0x4da3ff@0.9:t=fill,
    drawtext=fontfile=${FR}:textfile=${TMPD}/subline.txt:expansion=none:
      fontcolor=0x8b9bb0:fontsize=36:x=(w-text_w)/2:y=752,
    drawtext=fontfile=${FR}:textfile=${TMPD}/footer.txt:expansion=none:
      fontcolor=0x5b6b7f:fontsize=30:x=(w-text_w)/2:y=812
"

BG="gradients=s=1920x1080:c0=0x141d29:c1=0x090d12:type=radial:x0=960:y0=520:d=${DURATION}:speed=0.004:rate=30"

if [ -n "$LOGO" ]; then
    [ -f "$LOGO" ] || { echo "logo not found: $LOGO" >&2; exit 1; }
    ffmpeg -hide_banner -loglevel error -y \
      -f lavfi -i "$BG" \
      -loop 1 -i "$LOGO" \
      -filter_complex "
        [1:v]scale=-1:${LOGO_HEIGHT}:flags=lanczos,format=rgba[logo];
        [0:v][logo]overlay=x=(W-w)/2:y=${LOGO_Y}:format=auto[bg];
        [bg]${TEXT_CHAIN}
      " \
      -t "$DURATION" -r 30 \
      -c:v libx264 -profile:v high -level 4.1 -pix_fmt yuv420p \
      -preset medium -crf 20 -g 60 -movflags +faststart -an \
      "$OUT"
else
    ffmpeg -hide_banner -loglevel error -y \
      -f lavfi -i "$BG" \
      -filter_complex "[0:v]${TEXT_CHAIN}" \
      -t "$DURATION" -r 30 \
      -c:v libx264 -profile:v high -level 4.1 -pix_fmt yuv420p \
      -preset medium -crf 20 -g 60 -movflags +faststart -an \
      "$OUT"
fi

echo "wrote $OUT"
