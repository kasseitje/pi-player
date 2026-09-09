#!/bin/bash
# Normalise a folder of source clips and stills into uniform, audio-free
# 1080p H.264 files suitable for looping on a Pi.
#
#   ./prepare-media.sh SRCDIR DSTDIR
#
# Stills become fixed-duration video clips. That is deliberate: decoding stills
# through mpv's V4L2/GL path on a Pi produces green or black frames for
# progressive, CMYK, 16-bit and alpha images, and there is no per-format hwdec
# switch to work around it. Encoding them as video removes the failure mode
# entirely, gives every playlist entry a real container duration, and stops the
# resolution-mismatch flash when mpv advances between items.
#
# Overridable via the environment:
#   IMAGE_DURATION=5  WIDTH=1920  HEIGHT=1080  FPS=30  CRF=20  PRESET=medium
#   BG=black          PLAYLIST=1  KEEP_NAMES=0
set -uo pipefail

SRC="${1:?usage: prepare-media.sh SRCDIR DSTDIR}"
DST="${2:?usage: prepare-media.sh SRCDIR DSTDIR}"

IMAGE_DURATION="${IMAGE_DURATION:-5}"
WIDTH="${WIDTH:-1920}"
HEIGHT="${HEIGHT:-1080}"
FPS="${FPS:-30}"
CRF="${CRF:-20}"
PRESET="${PRESET:-medium}"
BG="${BG:-black}"
PLAYLIST="${PLAYLIST:-1}"      # also write playlist.m3u
KEEP_NAMES="${KEEP_NAMES:-0}"  # 1 = keep original names, no NNN_ prefix

[ -d "$SRC" ] || { echo "no such source directory: $SRC" >&2; exit 1; }
command -v ffmpeg  >/dev/null || { echo "ffmpeg not found" >&2; exit 1; }
command -v ffprobe >/dev/null || { echo "ffprobe not found" >&2; exit 1; }
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

# Fit inside the canvas without cropping, centred, letterboxed with BG.
# Scaling then overlaying onto a solid canvas (rather than pad) composites
# alpha instead of discarding it, which matters for RGBA PNGs.
img_filter="[0:v]scale=${WIDTH}:${HEIGHT}:force_original_aspect_ratio=decrease:flags=lanczos,format=rgba[fg];\
[1:v][fg]overlay=(W-w)/2:(H-h)/2:format=auto,format=yuv420p,setsar=1[v]"

vid_filter="scale=${WIDTH}:${HEIGHT}:force_original_aspect_ratio=decrease:flags=lanczos,\
pad=${WIDTH}:${HEIGHT}:(ow-iw)/2:(oh-ih)/2:color=${BG},fps=${FPS},format=yuv420p,setsar=1"

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
        -vf "$vid_filter" -map 0:v:0 "${enc_opts[@]}" "$out" 2>/dev/null
}

echo "source : $SRC"
echo "target : $DST"
echo "format : ${WIDTH}x${HEIGHT}@${FPS}  stills=${IMAGE_DURATION}s  crf=${CRF}  preset=${PRESET}"
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
