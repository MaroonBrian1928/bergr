#!/usr/bin/env bash
# A video of the demo on a real iPhone (made for the unfolded iPhone Duo): runs the UI test
# DemoTourTests/testDeviceVideoTour on the device, where Hirte Dev records its own screen, then
# copies the recording over and compresses it. Works over Wi-Fi; the phone must be unlocked.
# Your machines and settings stay; the demo machine is added if it's missing.
# Output: .build/video/device/hirte.mp4 (1280 px wide, no sound)
set -euo pipefail
cd "$(dirname "$0")/.."

device="${HIRTE_DEVICE:-$(just _device)}"
bundle="${HIRTE_BUNDLE_ID_PREFIX:-com.pavelzw}.hirte.dev"
out=.build/video/device
name=tour
rm -rf "$out"
mkdir -p "$out"

xcodebuild=(xcodebuild -project hirte.xcodeproj -scheme hirte -derivedDataPath .build/xcode -allowProvisioningUpdates
    ${HIRTE_TEAM:+DEVELOPMENT_TEAM=$HIRTE_TEAM} HIRTE_BUNDLE_ID_PREFIX="${HIRTE_BUNDLE_ID_PREFIX:-com.pavelzw}"
    -destination "id=$device" -only-testing:hirteUITests/DemoTourTests/testDeviceVideoTour)
"${xcodebuild[@]}" build-for-testing | xcbeautify --quiet
TEST_RUNNER_HIRTE_DEVICE_VIDEO="$name" ${HIRTE_SHOT_FONT:+TEST_RUNNER_HIRTE_SHOT_FONT=$HIRTE_SHOT_FONT} \
    "${xcodebuild[@]}" test-without-building | xcbeautify --quiet

xcrun devicectl device copy from --device "$device" --domain-type appDataContainer --domain-identifier "$bundle" \
    --source "Documents/$name.mp4" --destination "$out/raw.mp4" >/dev/null
ffmpeg -v error -y -i "$out/raw.mp4" -vf "fps=30,scale=1280:-2:flags=lanczos" \
    -c:v libx264 -preset slow -crf 26 -pix_fmt yuv420p -movflags +faststart -an "$out/hirte.mp4"
length="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$out/hirte.mp4")"
echo "Device video (${length%.*}s): $out/hirte.mp4 ($(du -h "$out/hirte.mp4" | cut -f1)); raw: $out/raw.mp4"
