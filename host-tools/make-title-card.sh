#!/bin/bash
# Render a looping title card matching the pi-player media conventions
# (H.264 High L4.1, yuv420p, SAR 1:1, no audio, 30fps, 2s GOP).
#
#   ./make-title-card.sh [-r SPEC] out.mp4 [logo.png] ["Headline"] ["Subline"] \
#                        ["EYEBROW"] ["Footer"] [seconds]
#
#   -r, --resolution SPEC   720p, 1080p, or WIDTHxHEIGHT   (default: 720p)
#   -h, --help              this message
#
# --resolution has to match the board, exactly as it does in prepare-media.sh:
# the V4L2 decoder sizes its CMA buffer pool per frame (3.0MB for 1920x1088
# NV12 against 1.4MB for 1280x736), and the fallback card is what loops for
# hours whenever no stick is present. 720p is the default because that is what
# a Pi 3 can sustain through the v4l2m2m copy-back path.
#
# Pass "" for the logo to render without one. A logo with an alpha channel
# (PNG/SVG-exported-to-PNG) composites cleanly on the dark background; a JPEG
# with a white background will show as a white box.
#
# Text is passed via textfile= rather than text=, so apostrophes, colons and
# percent signs need no escaping. Duration must stay a multiple of the 2.5s
# pulse period for a seamless loop.
set -euo pipefail

PROG="${0##*/}"

usage() {
    cat <<EOF
usage: ${PROG} [-r SPEC] out.mp4 [logo.png] ["Headline"] ["Subline"] ["EYEBROW"] ["Footer"] [seconds]

  -r, --resolution SPEC   720p, 1080p, or WIDTHxHEIGHT   (default: 720p)
  -h, --help              this message

Pass "" for the logo to render without one. Keep the duration a multiple of
2.5s - the eyebrow pulses on that period and any other length shows the seam.
EOF
}

RESOLUTION=720p
while [ $# -gt 0 ]; do
    case "$1" in
        -r|--resolution)
            [ $# -ge 2 ] || { echo "${PROG}: --resolution needs a value" >&2; exit 2; }
            RESOLUTION="$2"; shift 2 ;;
        --resolution=*) RESOLUTION="${1#*=}"; shift ;;
        -h|--help)      usage; exit 0 ;;
        --)             shift; break ;;
        -*)             echo "${PROG}: unknown option: $1" >&2; usage >&2; exit 2 ;;
        *)              break ;;
    esac
done

OUT="${1:-fallback.mp4}"
LOGO="${2:-}"
HEADLINE="${3:-Insert your USB stick}"
SUBLINE="${4:-FAT32 or exFAT — videos and images in the root folder}"
EYEBROW="${5:-NO MEDIA DETECTED}"
FOOTER="${6:-Playback starts automatically}"
DURATION="${7:-10}"

# Same spellings prepare-media.sh accepts, so the card and the media it sits
# alongside are asked for the same way.
case "$RESOLUTION" in
    720p)  W=1280; H=720  ;;
    1080p) W=1920; H=1080 ;;
    *x*)   W="${RESOLUTION%%x*}"; H="${RESOLUTION##*x}" ;;
    *) echo "${PROG}: --resolution must be 720p, 1080p or WIDTHxHEIGHT (got: $RESOLUTION)" >&2
       exit 2 ;;
esac
case "${W}${H}" in
    ''|*[!0-9]*) echo "${PROG}: resolution must be numeric (got: $RESOLUTION)" >&2; exit 2 ;;
esac
if [ $((W % 2)) -ne 0 ] || [ $((H % 2)) -ne 0 ]; then
    echo "${PROG}: resolution must be even in both axes (got: ${W}x${H})" >&2
    exit 2
fi

# The layout below is authored on a 1080p canvas; px() scales a design constant
# to the target height, rounding half up. Every constant scales by the same
# factor, so relative fit is preserved exactly - no line can start overflowing
# at 720p that already fitted at 1080p.
px() { echo $(( ($1 * H + 540) / 1080 )); }

LOGO_HEIGHT=$(px 250)     # rendered height in px; width scales to preserve aspect
LOGO_Y=$(px 150)          # top edge

EYEBROW_SIZE=$(px 30);  EYEBROW_Y=$(px 452)
HEAD_SIZE=$(px 104);    HEAD_Y=$(px 522)
RULE_W=$(px 220);       RULE_H=$(px 4);   RULE_Y=$(px 682)
SUB_SIZE=$(px 36);      SUB_Y=$(px 752)
FOOT_SIZE=$(px 30);     FOOT_Y=$(px 812)
[ "$RULE_H" -ge 1 ] || RULE_H=1

# Poppins is packaged here as .woff in the gfonts layout, and FreeType reads
# WOFF directly, so drawtext loads these as-is. Do NOT point these back at
# /usr/share/fonts/truetype/google-fonts/Poppins-*.ttf: that directory does not
# exist on this workstation, the [ -f ] guards below then fall through to
# DejaVu, and the card silently re-renders in the wrong typeface.
# The latin subset carries no Medium weight, so Regular stands in for it - a
# difference invisible at the eyebrow's size and colour.
GFONTS=/usr/share/fonts/truetype/gfonts/poppins
FB="${GFONTS}/poppins-v15-latin-700.woff"       # bold:    headline
FM="${GFONTS}/poppins-v15-latin-regular.woff"   # medium:  eyebrow
FR="${GFONTS}/poppins-v15-latin-regular.woff"   # regular: subline, footer
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
      fontcolor=0x5b6b7f:fontsize=${EYEBROW_SIZE}:x=(w-text_w)/2:y=${EYEBROW_Y}:
      alpha='0.7+0.3*sin(2*PI*t/2.5)',
    drawtext=fontfile=${FB}:textfile=${TMPD}/headline.txt:expansion=none:
      fontcolor=0xf2f6fb:fontsize=${HEAD_SIZE}:x=(w-text_w)/2:y=${HEAD_Y},
    drawbox=x=(iw-${RULE_W})/2:y=${RULE_Y}:w=${RULE_W}:h=${RULE_H}:color=0x4da3ff@0.9:t=fill,
    drawtext=fontfile=${FR}:textfile=${TMPD}/subline.txt:expansion=none:
      fontcolor=0x8b9bb0:fontsize=${SUB_SIZE}:x=(w-text_w)/2:y=${SUB_Y},
    drawtext=fontfile=${FR}:textfile=${TMPD}/footer.txt:expansion=none:
      fontcolor=0x5b6b7f:fontsize=${FOOT_SIZE}:x=(w-text_w)/2:y=${FOOT_Y}
"

BG="gradients=s=${W}x${H}:c0=0x141d29:c1=0x090d12:type=radial:x0=$((W / 2)):y0=$(px 520):d=${DURATION}:speed=0.004:rate=30"

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

echo "wrote $OUT (${W}x${H}, ${DURATION}s)"
