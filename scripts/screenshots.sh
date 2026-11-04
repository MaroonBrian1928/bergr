#!/usr/bin/env bash
# App Store screenshots: runs the demo UI test on a clean simulator and frames each capture
# with a caption, at the device's own screenshot size (iPhone 17 Pro: 1206×2622, the slot App Store
# Connect requires; 17 Pro Max: 1320×2868; iPhone Duo outer display: 1398×2034).
# Output: .build/screenshots/<device>/{raw,appstore}/*.png
#
#   scripts/screenshots.sh [light|dark] [device type]     (default: dark, "iPhone 17 Pro")
set -euo pipefail
cd "$(dirname "$0")/.."

appearance="${1:-dark}"
device_type="${2:-iPhone 17 Pro}"
sim_name="Hirte Screenshots ($device_type)"
out=".build/screenshots/$(echo "$device_type" | tr 'A-Z ' 'a-z-')"
raw="$out/raw"
final="$out/appstore"

# Captions, in the order the shots should appear in the App Store.
shots=(1-terminals 2-agent 3-needs-you 4-shell)
titles=("All your agents" "Jump into any terminal" "Answer when it matters" "Powered by Ghostty")
subtitles=("Every machine, space and agent at a glance." "See what an agent is doing, live." "Blocked agents come first. Reply in a tap." "Built on libghostty, the engine of Ghostty.")

# A clean, dedicated simulator (sets $device).
source scripts/simulator.sh

rm -rf "$out"
mkdir -p "$raw" "$final"
# Terminal font: as large as fits ~44 columns (the Duo's outer display is narrower).
case "$device_type" in
    "iPhone Duo") font=14 ;;
    "iPhone 17 Pro" | "iPhone 17") font=15 ;;
    *) font=17 ;;
esac
TEST_RUNNER_HIRTE_SHOTS="$PWD/$raw" TEST_RUNNER_HIRTE_SHOT_FONT="$font" xcodebuild -project hirte.xcodeproj -scheme hirte -derivedDataPath .build/xcode \
    ${HIRTE_TEAM:+DEVELOPMENT_TEAM=$HIRTE_TEAM} HIRTE_BUNDLE_ID_PREFIX="${HIRTE_BUNDLE_ID_PREFIX:-com.pavelzw}" \
    -destination "id=$device" -only-testing:hirteUITests/DemoTourTests test | xcbeautify --quiet

# Frame: caption on Hirte's charcoal, the screenshot below with rounded corners. The output has
# the capture's size (what App Store Connect expects for that device); the layout was designed
# at 1320×2868 and scales with the width (f, in thousandths).
read W H < <(sips -g pixelWidth -g pixelHeight "$raw/${shots[0]}.png" | awk '/pixel/ {printf "%s ", $2} END {print ""}')
f=$((W * 1000 / 1320))
BG="#303438" FG="#d9dad8" ACCENT="#9da1a6"
bold=/Library/Fonts/SF-Pro-Display-Bold.otf
regular=/Library/Fonts/SF-Pro-Display-Regular.otf
[ -f "$bold" ] || bold=Helvetica-Bold
[ -f "$regular" ] || regular=Helvetica
top=$((470 * f / 1000))
shot_h=$((H - top - 95 * f / 1000))
shot_w=$((shot_h * W / H))
radius=$((72 * f / 1000))
for i in "${!shots[@]}"; do
    name="${shots[$i]}"
    src="$raw/$name.png"
    [ -f "$src" ] || { echo "missing $src" >&2; exit 1; }
    magick "$src" -resize "${shot_w}x${shot_h}!" \
        \( +clone -alpha extract -fill black -colorize 100 -fill white \
           -draw "roundrectangle 0,0,$((shot_w - 1)),$((shot_h - 1)),$radius,$radius" \) \
        -alpha off -compose CopyOpacity -composite "$out/$name-rounded.png"
    magick -size "${W}x${H}" "xc:$BG" \
        -font "$bold" -fill "$FG" -pointsize $((104 * f / 1000)) -gravity north -annotate +0+$((190 * f / 1000)) "${titles[$i]}" \
        -font "$regular" -fill "$ACCENT" -pointsize $((50 * f / 1000)) -gravity north -annotate +0+$((330 * f / 1000)) "${subtitles[$i]}" \
        "$out/$name-rounded.png" -gravity north -geometry +0+$top -composite \
        -alpha off "$final/$name.png"
    rm "$out/$name-rounded.png"
done

xcrun simctl status_bar "$device" clear
for f in "$final"/*.png; do
    size="$(sips -g pixelWidth -g pixelHeight "$f" | awk '/pixel/ {print $2}' | paste -sd x -)"
    [ "$size" = "${W}x${H}" ] || { echo "$f is $size, expected ${W}x${H}" >&2; exit 1; }
done
echo "App Store screenshots ($device_type, $appearance, ${W}×${H}): $final"
