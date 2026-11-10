#!/usr/bin/env bash
# Modified for Bergr, 2026, from Hirte (Apache-2.0). See the git history for all changes.
# The README video: records the UI test DemoTourTests/testVideoTour on a clean simulator, cuts it to
# the app and frames it on Bergr's charcoal with rounded corners.
# Output: .build/video/<device>/bergr.mp4 (and bergr.gif, small, for places that don't play video)
#
#   scripts/video.sh [light|dark] [device type]     (default: dark, "iPhone 17 Pro")
set -euo pipefail
cd "$(dirname "$0")/.."

appearance="${1:-dark}"
device_type="${2:-iPhone 17 Pro}"
sim_name="Bergr Screenshots ($device_type)"
out=".build/video/$(echo "$device_type" | tr 'A-Z ' 'a-z-')"

# A clean, dedicated simulator (sets $device).
source scripts/simulator.sh

rm -rf "$out"
mkdir -p "$out/marks"
case "$device_type" in
    "iPhone Duo") font=14 ;;
    "iPhone 17 Pro" | "iPhone 17") font=15 ;;
    *) font=17 ;;
esac
xcodebuild=(xcodebuild -project bergr.xcodeproj -scheme bergr -derivedDataPath .build/xcode
    ${BERGR_TEAM:+DEVELOPMENT_TEAM=$BERGR_TEAM} BERGR_BUNDLE_ID_PREFIX="${BERGR_BUNDLE_ID_PREFIX:-com.pavelzw}"
    -destination "id=$device" -only-testing:bergrUITests/DemoTourTests/testVideoTour)
# Build first, so the recording doesn't wait for the compiler.
"${xcodebuild[@]}" build-for-testing | xcbeautify --quiet

# Record the whole run; the test notes when the app is ready (start) and done (end).
xcrun simctl io "$device" recordVideo --codec h264 --force "$out/raw.mov" 2>"$out/record.log" &
recorder=$!
until grep -q "Recording started" "$out/record.log" 2>/dev/null; do sleep 0.1; done
python3 -I -c 'import time; print(time.time())' >"$out/marks/t0"
mkdir -p "$out/shots"
TEST_RUNNER_BERGR_VIDEO="$PWD/$out/marks" TEST_RUNNER_BERGR_SHOTS="$PWD/$out/shots" TEST_RUNNER_BERGR_SHOT_FONT="$font" \
    "${xcodebuild[@]}" test-without-building | xcbeautify --quiet || { kill -INT $recorder; exit 1; }
kill -INT $recorder
wait $recorder || true
xcrun simctl status_bar "$device" clear

read -r from length < <(python3 -I -c '
import sys
t0, start, end = (float(open(p).read()) for p in sys.argv[1:])
print(f"{max(start - t0, 0):.2f} {end - start:.2f}")' "$out/marks/t0" "$out/marks/start" "$out/marks/end")

# Frame: the recording at 720 px wide with rounded corners, on charcoal with a margin.
read -r W H < <(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$out/raw.mov" | tr , ' ')
w=720
h=$(( (H * w / W) / 2 * 2 ))
pad=56
radius=48
if command -v magick >/dev/null; then
    magick -size "${w}x${h}" xc:black -fill white -draw "roundrectangle 0,0,$((w - 1)),$((h - 1)),$radius,$radius" "$out/mask.png"
else
    # Without ImageMagick: the same rounded rectangle, drawn by ffmpeg.
    ffmpeg -v error -y -f lavfi -i "color=black:s=${w}x${h}" -frames:v 1 -vf \
        "format=gray,geq=lum='if(lte(hypot(max(0\,max($radius-X\,X-(W-1-$radius)))\,max(0\,max($radius-Y\,Y-(H-1-$radius))))\,$radius)\,255\,0)'" \
        "$out/mask.png"
fi
ffmpeg -v error -y -ss "$from" -t "$length" -i "$out/raw.mov" -loop 1 -i "$out/mask.png" -filter_complex "
    [0:v]fps=30,scale=${w}:${h},format=rgba[video];
    [1:v]format=gray[mask];
    [video][mask]alphamerge=shortest=1[rounded];
    color=c=0x303438:s=$((w + 2 * pad))x$((h + 2 * pad)):r=30[bg];
    [bg][rounded]overlay=${pad}:${pad}:shortest=1,format=yuv420p[out]" \
    -map "[out]" -t "$length" -c:v libx264 -crf 22 -preset slow -movflags +faststart -an "$out/bergr.mp4"
ffmpeg -v error -y -i "$out/bergr.mp4" -filter_complex \
    "fps=12,scale=360:-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4" \
    "$out/bergr.gif"
rm "$out/mask.png"

echo "Video ($device_type, $appearance, ${length}s): $out/bergr.mp4 ($(du -h "$out/bergr.mp4" | cut -f1)), $out/bergr.gif ($(du -h "$out/bergr.gif" | cut -f1))"
