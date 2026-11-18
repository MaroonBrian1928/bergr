#!/usr/bin/env bash
# Modified for Bergr, 2026, from Hirte (Apache-2.0). See the git history for all changes.
# App Store screenshots: runs the demo's shot test (bergrUITests/DemoShotsTests) on a clean simulator,
# draws the Lock Screen and Home Screen frames from the real widget code (scripts/widget-render), and
# frames each with a caption at the device's own screenshot size (iPhone 17 Pro: 1206×2622, the slot
# App Store Connect requires; 17 Pro Max: 1320×2868; iPhone Duo outer display: 1398×2034;
# iPad Pro 13-inch: 2752×2064, landscape).
# Output: .build/screenshots/<device>-<appearance>/{raw,appstore}/*.png
#
#   scripts/screenshots.sh [dark|light] [device type]     (default: dark, "iPhone 17 Pro")
set -euo pipefail
cd "$(dirname "$0")/.."

appearance="${1:-dark}"
device_type="${2:-iPhone 17 Pro}"
# BERGR_SIM_NAME / BERGR_DERIVED: another simulator / derived data folder.
sim_name="${BERGR_SIM_NAME:-Bergr Screenshots ($device_type)}"
derived="${BERGR_DERIVED:-.build/xcode}"
out=".build/screenshots/$(echo "$device_type" | tr 'A-Z ' 'a-z-')-$appearance"
raw="$out/raw"
final="$out/appstore"

# The App Store set, in order (plans/screenshot-shotlist.md, frames 1 to 8): output name, raw frame
# (DemoShotsTests' name, or widget-render's), caption (six words at most), subcaption.
shots=(
  "1-agents|01-agents|Your whole herd, one list|Every machine, sorted by what needs you."
  "2-summaries|02-chat-summaries|Summaries written on your iPhone|Apple Intelligence, on device. Nothing leaves it."
  "3-answer|03-answer-card|Answer in one tap|Questions become buttons."
  "4-risky|04-dangerous-command|Know what you're approving|One sentence on what the command does."
  "5-lock-screen|lock-live-activity|Answer from the Lock Screen|No need to open the app."
  "6-usage|06-usage|See the limit coming|Session, weekly and context, with a forecast."
  "7-reply|07-codex-reply|Talk, scan or paste|A reply doesn't need a keyboard."
  "8-widgets|home-widgets|Always in view|Widgets, Live Activity, encrypted alerts."
)

# iPad: its own set from bergrUITests/DemoPadShotsTests, in landscape (list and chat side by side).
# The drawn Lock Screen and widget frames are iPhone geometry, so the iPad set leaves them out.
pad=false
if [[ "$device_type" == iPad* ]]; then
  pad=true
  shots=(
    "1-agents|p01-list-summaries|Your whole herd, one list|Every machine beside the chat, summed up on device."
    "2-answer|p02-answer-card|Answer in one tap|Questions become buttons."
    "3-risky|p03-dangerous-command|Know what you're approving|One sentence on what the command does."
    "4-side-by-side|p04-side-by-side|Two agents side by side|Watch one run while you answer another."
    "5-usage|p05-usage|See the limit coming|Session, weekly and context, with a forecast."
    "6-reply|p06-codex-reply|Talk, scan or paste|A reply doesn't need a keyboard."
  )
fi

# A clean, dedicated simulator (sets $device).
source scripts/simulator.sh

rm -rf "$out"
mkdir -p "$raw" "$final"
signing=(BERGR_BUNDLE_ID_PREFIX="${BERGR_BUNDLE_ID_PREFIX:-com.pavelzw}")
[ -n "${BERGR_TEAM:-}" ] && signing+=(DEVELOPMENT_TEAM="$BERGR_TEAM")
if $pad; then
  tests=(-only-testing:bergrUITests/DemoPadShotsTests)
else
  tests=(-only-testing:bergrUITests/DemoShotsTests -skip-testing:bergrUITests/DemoShotsTests/testLockScreenLiveActivity)
fi
# A flaky tap now and then: one retry.
for attempt in 1 2; do
  if TEST_RUNNER_BERGR_SHOTS="$PWD/$raw" TEST_RUNNER_BERGR_SHOT_APPEARANCE="$appearance" xcodebuild test \
       -project bergr.xcodeproj -scheme bergr -derivedDataPath "$derived" "${signing[@]}" -destination "id=$device" \
       "${tests[@]}" | xcbeautify --quiet; then
    break
  fi
  [ "$attempt" = 2 ] && { echo "the shot test failed twice" >&2; exit 1; }
  echo "retrying the shot test"
done
xcrun simctl status_bar "$device" clear

# Lock Screen and Home Screen: the simulator can't show the Live Activity or widgets from the demo,
# so they're drawn from the widget code (iPhone 17 Pro geometry; other devices get it scaled).
if ! $pad; then
  widgets="$out/widgets"
  scripts/widget-render/render.sh "$widgets"
  for name in lock-live-activity home-widgets; do cp "$widgets/$name-$appearance.png" "$raw/$name.png"; done
  rm -rf "$widgets"
fi

# Frame: caption on Bergr's charcoal, the screenshot below with rounded corners. The output has
# the capture's size (what App Store Connect expects for that device); the layout was designed
# at 1320×2868 and scales with the width (f, in thousandths).
first="$raw/$(echo "${shots[0]}" | cut -d'|' -f2).png"
# A landscape screenshot is stored portrait with an orientation tag (viewers turn it, ImageMagick
# doesn't): apply the tag first, so the frames get the picture upright.
for entry in "${shots[@]}"; do
  src="$raw/$(echo "$entry" | cut -d'|' -f2).png"
  [ -f "$src" ] && magick "$src" -auto-orient "$src"
done
read -r W H < <(magick identify -format '%w %h' "$first")
# Landscape iPad: the layout is scaled from the height instead (the width would make it huge).
if [ "$W" -gt "$H" ]; then f=$((H * 1000 / 2000)); else f=$((W * 1000 / 1320)); fi
BG="#303438" FG="#d9dad8" ACCENT="#9da1a6"
bold=/Library/Fonts/SF-Pro-Display-Bold.otf
regular=/Library/Fonts/SF-Pro-Display-Regular.otf
[ -f "$bold" ] || bold=Helvetica-Bold
[ -f "$regular" ] || regular=Helvetica
top=$((470 * f / 1000))
shot_h=$((H - top - 95 * f / 1000))
shot_w=$((shot_h * W / H))
radius=$((72 * f / 1000))
$pad && radius=$((36 * f / 1000))
for entry in "${shots[@]}"; do
  IFS='|' read -r name frame title subtitle <<<"$entry"
  src="$raw/$frame.png"
  [ -f "$src" ] || { echo "missing $src" >&2; exit 1; }
  magick "$src" -resize "${shot_w}x${shot_h}!" \
    \( +clone -alpha extract -fill black -colorize 100 -fill white \
       -draw "roundrectangle 0,0,$((shot_w - 1)),$((shot_h - 1)),$radius,$radius" \) \
    -alpha off -compose CopyOpacity -composite "$out/$name-rounded.png"
  # Title and subtitle shrink to fit 90 % of the width (a long caption would run off the edge).
  magick -background none -font "$bold" -fill "$FG" -pointsize $((104 * f / 1000)) label:"$title" \
    -resize "$((W * 9 / 10))x>" "$out/$name-title.png"
  magick -background none -font "$regular" -fill "$ACCENT" -pointsize $((50 * f / 1000)) label:"$subtitle" \
    -resize "$((W * 9 / 10))x>" "$out/$name-subtitle.png"
  magick -size "${W}x${H}" "xc:$BG" \
    "$out/$name-title.png" -gravity north -geometry +0+$((190 * f / 1000)) -composite \
    "$out/$name-subtitle.png" -gravity north -geometry +0+$((330 * f / 1000)) -composite \
    "$out/$name-rounded.png" -gravity north -geometry +0+$top -composite \
    -alpha off "$final/$name.png"
  rm "$out/$name-rounded.png" "$out/$name-title.png" "$out/$name-subtitle.png"
done

for f in "$final"/*.png; do
  size="$(sips -g pixelWidth -g pixelHeight "$f" | awk '/pixel/ {print $2}' | paste -sd x -)"
  [ "$size" = "${W}x${H}" ] || { echo "$f is $size, expected ${W}x${H}" >&2; exit 1; }
done
echo "App Store screenshots ($device_type, $appearance, ${W}×${H}): $final"
