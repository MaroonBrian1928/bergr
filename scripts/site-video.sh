#!/usr/bin/env bash
# Re-records the marketing site's demo video and drops it into the site repo.
#
#   scripts/site-video.sh [site-dir]      (default: ../bergr-site)
#
# Records the UI test DemoTourTests/testVideoTour with scripts/video.sh (dark, iPhone 17 Pro: cut to
# the app, 720 px wide with rounded corners on charcoal, 832×1676) on its own simulator, speeds it
# up to BERGR_VIDEO_SECONDS (default 28.5; the ~53 s tour plays at ~1.85×; BERGR_VIDEO_SPEED sets the
# factor instead) and writes
#   <site-dir>/assets/demo.mp4         h264 High, yuv420p, 30 fps, no audio, faststart (~1.6 MB)
#   <site-dir>/assets/demo-poster.jpg  its first frame
# Signing: source .envrc.local first (BERGR_TEAM / BERGR_BUNDLE_ID_PREFIX), like `just phone`.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
site="${1:-$root/../bergr-site}"
[ -d "$site/assets" ] || { echo "no site at $site (pass its folder)" >&2; exit 1; }
for tool in ffmpeg ffprobe magick xcbeautify; do
  command -v "$tool" >/dev/null || { echo "$tool is missing (brew install ${tool/ffprobe/ffmpeg})" >&2; exit 1; }
done
target="${BERGR_VIDEO_SECONDS:-28.5}"

work="$(mktemp -d /tmp/bergr-site-video.XXXXXX)"
export BERGR_SIM_NAME="Bergr site video"
# Its own build folder (deleted afterwards), unless BERGR_DERIVED names one to reuse.
export BERGR_DERIVED="${BERGR_DERIVED:-$work/dd}"
cleanup() {
  udid="$(xcrun simctl list devices | sed -nE "s/^ *$BERGR_SIM_NAME \(([0-9A-F-]+)\).*/\1/p" | head -1)"
  [ -n "$udid" ] && xcrun simctl delete "$udid" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

# A leftover simulator from an interrupted run would carry its state; start clean.
cleanup; mkdir -p "$work"

"$root/scripts/video.sh" dark "iPhone 17 Pro"
src="$root/.build/video/iphone-17-pro/bergr.mp4"
[ -f "$src" ] || { echo "video.sh made no $src" >&2; exit 1; }

length="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$src")"
speed="${BERGR_VIDEO_SPEED:-$(python3 -I -c 'import sys; print(f"{float(sys.argv[1]) / float(sys.argv[2]):.3f}")' "$length" "$target")}"
echo "› ${length%.*} s recorded, played at ${speed}×"
# A busy Mac makes the tour slow (the UI waits stretch); the result then looks hurried.
python3 -I -c 'import sys; sys.exit(float(sys.argv[1]) > 2.5)' "$speed" \
  || echo "warning: ${speed}× is much faster than usual (~1.85×); the Mac was probably busy. Re-run when it's idle." >&2
ffmpeg -v error -y -i "$src" -vf "setpts=PTS/$speed,fps=30,format=yuv420p" \
  -c:v libx264 -profile:v high -crf 26 -preset slow -movflags +faststart -an "$site/assets/demo.mp4"
ffmpeg -v error -y -i "$site/assets/demo.mp4" -frames:v 1 -q:v 3 "$site/assets/demo-poster.jpg"

read -r w h < <(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$site/assets/demo.mp4" | tr , ' ')
seconds="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$site/assets/demo.mp4")"
[ "${w}x${h}" = 832x1676 ] || { echo "demo.mp4 is ${w}x${h}, the site expects 832x1676" >&2; exit 1; }
echo "Done: demo.mp4 (${w}×${h}, ${seconds%.*} s, $(du -h "$site/assets/demo.mp4" | cut -f1)) and demo-poster.jpg. Review: git -C \"$site\" diff --stat"
