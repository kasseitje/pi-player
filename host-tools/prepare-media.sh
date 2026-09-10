#!/bin/bash
# Normalise a folder of source clips and stills into uniform, audio-free
# H.264 files suitable for looping on a Pi.
#
#   ./prepare-media.sh [OPTIONS] SRCDIR DSTDIR
#
# Stills become fixed-duration video clips. That is deliberate: decoding stills
# through mpv's V4L2/GL path on a Pi produces green or black frames for
# progressive, CMYK, 16-bit and alpha images, and there is no per-format hwdec
# switch to work around it. Encoding them as video removes the failure mode
# entirely, gives every playlist entry a real container duration, and stops the
# resolution-mismatch flash when mpv advances between items.
#
# --resolution picks the canvas. 1080p is the default and is what a Pi 4 should
# get. A Pi 3 cannot sustain 1080p through the v4l2m2m copy-back path: measured
# over an 8.5 h soak, every long clip stayed on screen for ~1.78x its real
# duration (~14 fps against a 25 fps container) with CMA touching 0 MB. 720p
# halves both the memory bandwidth and the CMA cost per frame - use it on a Pi 3.
set -uo pipefail

PROG="$(basename "$0")"

usage() {
    cat <<EOF
usage: ${PROG} [OPTIONS] SRCDIR DSTDIR

Normalise clips and stills into uniform, audio-free H.264 for a Pi player.

Options:
  -r, --resolution SPEC   720p, 1080p, or WIDTHxHEIGHT   (default: 1080p)
                          720p is required for a Pi 3; 1080p suits a Pi 4.
  -d, --duration SEC      seconds per still              (default: 5)
  -f, --fit MODE          contain | cover | blur         (default: contain)
      --fps N             output frame rate              (default: 30)
  -c, --crf N             x264 quality, lower is better  (default: 20)
      --preset NAME       x264 preset                    (default: medium)
      --bg COLOUR         letterbox colour for 'contain' (default: black)
      --blur-sigma N      blur strength for --fit blur   (default: 8)
      --keep-names        keep original names, no NNN_ prefix
      --no-playlist       do not write playlist.m3u
  -h, --help              this message

FIT controls what happens to content whose aspect ratio is not the canvas:
  contain  fit inside, bars in --bg             (default; nothing is lost)
  cover    fill the canvas, crop the overflow   (edges ARE lost - brutal on
           portrait photos, which lose most of their height)
  blur     fill the canvas with a blurred, zoomed copy of the image itself and
           lay the whole uncropped image on top (no bars, nothing lost)

Examples:
  ${PROG} ~/raw-media /media/MY-USB-STICK
  ${PROG} --resolution 720p --fit blur ~/raw-media /media/STICK
  ${PROG} -d 8 -c 22 ~/raw-media /media/STICK
EOF
}

# util-linux getopt. The plain POSIX one cannot do long options and would
# silently mangle the command line rather than reject it.
getopt --test >/dev/null
if [ "$?" -ne 4 ]; then
    echo "${PROG}: GNU enhanced getopt required (util-linux)" >&2
    exit 1
fi

# These used to be the entire interface. Warn rather than ignore silently -
# a config that quietly stops applying is exactly the failure this project
# keeps getting bitten by.
for legacy in IMAGE_DURATION WIDTH HEIGHT FPS CRF PRESET BG PLAYLIST \
              KEEP_NAMES FIT BLUR_SIGMA; do
    if [ -n "${!legacy:-}" ]; then
        echo "${PROG}: warning: \$${legacy} is set but no longer read; use the" \
             "matching option (see --help)" >&2
    fi
done

PARSED=$(getopt \
    --options 'r:d:f:c:h' \
    --longoptions 'resolution:,duration:,fit:,fps:,crf:,preset:,bg:,blur-sigma:,keep-names,no-playlist,help' \
    --name "$PROG" -- "$@") || { usage >&2; exit 2; }
eval set -- "$PARSED"

RESOLUTION=1080p
IMAGE_DURATION=5
FIT=contain
FPS=30
CRF=20
PRESET=medium
BG=black
BLUR_SIGMA=8
PLAYLIST=1
KEEP_NAMES=0

while true; do
    case "$1" in
        -r|--resolution) RESOLUTION="$2";     shift 2 ;;
        -d|--duration)   IMAGE_DURATION="$2"; shift 2 ;;
        -f|--fit)        FIT="$2";            shift 2 ;;
        --fps)           FPS="$2";            shift 2 ;;
        -c|--crf)        CRF="$2";            shift 2 ;;
        --preset)        PRESET="$2";         shift 2 ;;
        --bg)            BG="$2";             shift 2 ;;
        --blur-sigma)    BLUR_SIGMA="$2";     shift 2 ;;
        --keep-names)    KEEP_NAMES=1;        shift ;;
        --no-playlist)   PLAYLIST=0;          shift ;;
        -h|--help)       usage; exit 0 ;;
        --)              shift; break ;;
        *)               echo "${PROG}: internal parse error at '$1'" >&2; exit 2 ;;
    esac
done

if [ "$#" -ne 2 ]; then
    echo "${PROG}: expected SRCDIR and DSTDIR, got $# argument(s)" >&2
    usage >&2
    exit 2
fi
SRC="$1"
DST="$2"

case "$RESOLUTION" in
    720p)  WIDTH=1280; HEIGHT=720  ;;
    1080p) WIDTH=1920; HEIGHT=1080 ;;
    *x*)   WIDTH="${RESOLUTION%%x*}"; HEIGHT="${RESOLUTION##*x}" ;;
    *) echo "${PROG}: --resolution must be 720p, 1080p or WIDTHxHEIGHT (got: $RESOLUTION)" >&2
       exit 1 ;;
esac

num() { printf '%s' "$1" | grep -qE '^[0-9]+$'; }
for pair in "WIDTH $WIDTH" "HEIGHT $HEIGHT" "--fps $FPS" "--crf $CRF" \
            "--duration $IMAGE_DURATION" "--blur-sigma $BLUR_SIGMA"; do
    set -- $pair
    num "$2" || { echo "${PROG}: $1 must be a whole number (got: $2)" >&2; exit 1; }
done
# yuv420p subsamples by two in both directions, so odd dimensions fail the
# encode with an unhelpful error deep inside the filter graph.
if [ $((WIDTH % 2)) -ne 0 ] || [ $((HEIGHT % 2)) -ne 0 ]; then
    echo "${PROG}: resolution must be even in both axes (got: ${WIDTH}x${HEIGHT})" >&2
    exit 1
fi

case "$FIT" in
    contain|cover|blur) ;;
    *) echo "${PROG}: --fit must be contain, cover or blur (got: $FIT)" >&2; exit 1 ;;
esac

[ -d "$SRC" ] || { echo "${PROG}: no such source directory: $SRC" >&2; exit 1; }
command -v ffmpeg  >/dev/null || { echo "${PROG}: ffmpeg not found" >&2; exit 1; }
command -v ffprobe >/dev/null || { echo "${PROG}: ffprobe not found" >&2; exit 1; }
HAVE_IM=0
command -v convert >/dev/null && HAVE_IM=1

mkdir -p "$DST"

GOP=$((FPS * 2))
OK=0; FAILED=0; TOTAL=0
FAILED_LIST=()

# Shared H.264 settings, constrained to what a Pi decodes in hardware.
enc_opts=(
    -c:v libx264 -profile:v high -level 4.1 -pix_fmt yuv420p
    -preset "$PRESET" -crf "$CRF"
    -r "$FPS" -g "$GOP" -keyint_min "$GOP" -sc_threshold 0
    -movflags +faststart -an
)

# The blurred backdrop is produced at 1/8 scale and then scaled back up: a
# gblur wide enough to look right at 1080p costs far more than the two extra
# scale passes, and the upscale hides any coarseness in the small blur.
BW=$(( WIDTH / 8 ))
BH=$(( HEIGHT / 8 ))

# Images composite onto the solid canvas of input 1 (rather than using pad)
# because that composites alpha instead of discarding it, which matters for
# RGBA PNGs. FIT=blur inserts an opaque blurred backdrop between the two.
case "$FIT" in
contain)
    img_filter="[0:v]scale=${WIDTH}:${HEIGHT}:force_original_aspect_ratio=decrease:flags=lanczos,format=rgba[fg];\
[1:v][fg]overlay=(W-w)/2:(H-h)/2:format=auto,format=yuv420p,setsar=1[v]"

    vid_filter="[0:v]scale=${WIDTH}:${HEIGHT}:force_original_aspect_ratio=decrease:flags=lanczos,\
pad=${WIDTH}:${HEIGHT}:(ow-iw)/2:(oh-ih)/2:color=${BG},fps=${FPS},format=yuv420p,setsar=1[v]"
    ;;
cover)
    img_filter="[0:v]scale=${WIDTH}:${HEIGHT}:force_original_aspect_ratio=increase:flags=lanczos,\
crop=${WIDTH}:${HEIGHT},format=rgba[fg];\
[1:v][fg]overlay=(W-w)/2:(H-h)/2:format=auto,format=yuv420p,setsar=1[v]"

    vid_filter="[0:v]scale=${WIDTH}:${HEIGHT}:force_original_aspect_ratio=increase:flags=lanczos,\
crop=${WIDTH}:${HEIGHT},fps=${FPS},format=yuv420p,setsar=1[v]"
    ;;
blur)
    img_filter="[0:v]split=2[bs][fs];\
[bs]scale=${BW}:${BH}:force_original_aspect_ratio=increase:flags=bilinear,crop=${BW}:${BH},\
gblur=sigma=${BLUR_SIGMA},scale=${WIDTH}:${HEIGHT}:flags=bicubic,format=rgba[bgi];\
[1:v][bgi]overlay=0:0:format=auto[bg];\
[fs]scale=${WIDTH}:${HEIGHT}:force_original_aspect_ratio=decrease:flags=lanczos,format=rgba[fg];\
[bg][fg]overlay=(W-w)/2:(H-h)/2:format=auto,format=yuv420p,setsar=1[v]"

    vid_filter="[0:v]fps=${FPS},split=2[bs][fs];\
[bs]scale=${BW}:${BH}:force_original_aspect_ratio=increase:flags=bilinear,crop=${BW}:${BH},\
gblur=sigma=${BLUR_SIGMA},scale=${WIDTH}:${HEIGHT}:flags=bicubic[bg];\
[fs]scale=${WIDTH}:${HEIGHT}:force_original_aspect_ratio=decrease:flags=lanczos[fg];\
[bg][fg]overlay=(W-w)/2:(H-h)/2,format=yuv420p,setsar=1[v]"
    ;;
esac

slug() {
    basename "${1%.*}" | tr ' ' '_' | tr -cd '[:alnum:]._-'
}

# Confirm the encode produced decodable video, not a zero-frame file.
verify() {
    local f="$1" want="$2" dur frames
    [ -f "$f" ] || return 1
    dur=$(ffprobe -v error -show_entries format=duration -of default=nk=1:nw=1 "$f" 2>/dev/null)
    frames=$(ffprobe -v error -select_streams v:0 -count_packets \
             -show_entries stream=nb_read_packets -of default=nk=1:nw=1 "$f" 2>/dev/null)
    [ -n "$dur" ] && [ -n "$frames" ] && [ "$frames" -gt 0 ] || return 1
    awk -v d="$dur" -v w="$want" 'BEGIN{exit !(d > w*0.5)}'
}

# GIF uses ffmpeg's gif demuxer, which has no -loop option (that belongs to
# image2). Passing -loop 1 to a .gif aborts with "Option loop not found", so
# every GIF would silently fall through to the ImageMagick path and lose its
# animation. -ignore_loop 0 is the gif demuxer's equivalent and repeats the
# animation for as long as -t asks for.
loop_opts_for() {
    case "$(printf '%s' "${1##*.}" | tr '[:upper:]' '[:lower:]')" in
        gif) printf '%s' "-ignore_loop 0" ;;
        *)   printf '%s' "-loop 1" ;;
    esac
}

encode_image() {
    local in="$1" out="$2"
    # shellcheck disable=SC2046  # deliberate word splitting of the option pair
    ffmpeg -hide_banner -loglevel error -y \
        $(loop_opts_for "$in") -i "$in" \
        -f lavfi -i "color=c=${BG}:s=${WIDTH}x${HEIGHT}:r=${FPS}" \
        -filter_complex "$img_filter" -map "[v]" \
        -t "$IMAGE_DURATION" "${enc_opts[@]}" "$out" 2>/dev/null
}

encode_video() {
    local in="$1" out="$2"
    ffmpeg -hide_banner -loglevel error -y -i "$in" \
        -filter_complex "$vid_filter" -map "[v]" "${enc_opts[@]}" "$out" 2>/dev/null
}

echo "source : $SRC"
echo "target : $DST"
echo "format : ${WIDTH}x${HEIGHT}@${FPS}  stills=${IMAGE_DURATION}s  crf=${CRF}  preset=${PRESET}  fit=${FIT}"
echo

shopt -s nullglob nocaseglob
n=0
for f in "$SRC"/*; do
    [ -f "$f" ] || continue
    ext="${f##*.}"
    ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"

    case "$ext" in
        jpg|jpeg|png|bmp|gif|tif|tiff|webp) kind=image ;;
        mp4|mkv|mov|avi|m4v|webm|mpg|mpeg)  kind=video ;;
        *) continue ;;
    esac

    n=$((n+1))
    if [ "$KEEP_NAMES" = "1" ]; then
        out="${DST}/$(slug "$f").mp4"
    else
        out="$(printf '%s/%03d_%s.mp4' "$DST" "$n" "$(slug "$f")")"
    fi

    src_info=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=codec_name,pix_fmt,width,height \
        -of csv=p=0 "$f" 2>/dev/null)
    printf '[%03d] %-36s %-26s ' "$n" "$(basename "$f")" "${src_info:-unreadable}"

    if [ "$kind" = image ]; then
        want="$IMAGE_DURATION"
        if encode_image "$f" "$out" && verify "$out" "$want"; then
            :
        elif [ "$HAVE_IM" = 1 ]; then
            # ImageMagick decodes formats ffmpeg mishandles - notably CMYK
            # JPEGs and unusual PNG bit depths. Transcode to sRGB, then retry.
            tmp="$(mktemp --suffix=.png)"
            if convert "${f}[0]" -alpha off -colorspace sRGB -strip "$tmp" 2>/dev/null \
               && encode_image "$tmp" "$out" && verify "$out" "$want"; then
                rm -f "$tmp"
                dur=$(ffprobe -v error -show_entries format=duration -of default=nk=1:nw=1 "$out")
                TOTAL=$(awk -v a="$TOTAL" -v b="$dur" 'BEGIN{print a+b}')
                OK=$((OK+1))
                printf 'OK  %ss  (via imagemagick)\n' "$(awk -v d="$dur" 'BEGIN{printf "%.1f", d}')"
                continue
            fi
            rm -f "$tmp" "$out"
            echo "FAILED"
            FAILED=$((FAILED+1)); FAILED_LIST+=("$f")
            continue
        else
            rm -f "$out"
            echo "FAILED"
            FAILED=$((FAILED+1)); FAILED_LIST+=("$f")
            continue
        fi
    else
        want=$(ffprobe -v error -show_entries format=duration -of default=nk=1:nw=1 "$f" 2>/dev/null)
        [ -n "$want" ] || want=1
        if ! encode_video "$f" "$out" || ! verify "$out" "$want"; then
            rm -f "$out"
            echo "FAILED"
            FAILED=$((FAILED+1)); FAILED_LIST+=("$f")
            continue
        fi
    fi

    dur=$(ffprobe -v error -show_entries format=duration -of default=nk=1:nw=1 "$out")
    TOTAL=$(awk -v a="$TOTAL" -v b="$dur" 'BEGIN{print a+b}')
    OK=$((OK+1))
    printf 'OK  %ss\n' "$(awk -v d="$dur" 'BEGIN{printf "%.1f", d}')"
done

if [ "$PLAYLIST" = "1" ] && [ "$OK" -gt 0 ]; then
    ( cd "$DST" && ls -1 *.mp4 2>/dev/null | sort > playlist.m3u )
    echo
    echo "wrote ${DST}/playlist.m3u ($(wc -l < "${DST}/playlist.m3u" | tr -d ' ') entries, relative paths)"
fi

echo
printf 'done: %d converted, %d failed, total loop %s\n' \
    "$OK" "$FAILED" "$(awk -v t="$TOTAL" 'BEGIN{printf "%dm%02ds", t/60, t%60}')"

if [ "$FAILED" -gt 0 ]; then
    echo
    echo "failed files:"
    printf '  %s\n' "${FAILED_LIST[@]}"
    [ "$HAVE_IM" = 0 ] && echo "  (install imagemagick for a fallback decode path)"
    exit 1
fi
