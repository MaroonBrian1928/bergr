#!/usr/bin/env bash
# Modified for Bergr, 2026, from Hirte (Apache-2.0). See the git history for all changes.
# A video of the demo on a real iPhone (made for the unfolded iPhone Duo): runs the UI test
# DemoTourTests/testDeviceVideoTour on the device, where Bergr Dev records its own screen, then
# copies the recording over and compresses it. Works over Wi-Fi; the phone must be unlocked.
# Your machines and settings stay; the demo machine is added if it's missing.
# Output: .build/video/device/bergr.mp4 (1280 px wide, no sound)
set -euo pipefail
cd "$(dirname "$0")/.."

device="${BERGR_DEVICE:-$(just _device)}"
bundle="${BERGR_BUNDLE_ID_PREFIX:-com.pavelzw}.bergr.dev"
out=.build/video/device
name=tour
rm -rf "$out"
mkdir -p "$out"

xcodebuild=(xcodebuild -project bergr.xcodeproj -scheme bergr -derivedDataPath .build/xcode -allowProvisioningUpdates
    ${BERGR_TEAM:+DEVELOPMENT_TEAM=$BERGR_TEAM} BERGR_BUNDLE_ID_PREFIX="${BERGR_BUNDLE_ID_PREFIX:-com.pavelzw}"
    -destination "id=$device" -only-testing:bergrUITests/DemoTourTests/testDeviceVideoTour)
"${xcodebuild[@]}" build-for-testing | xcbeautify --quiet
TEST_RUNNER_BERGR_DEVICE_VIDEO="$name" ${BERGR_SHOT_FONT:+TEST_RUNNER_BERGR_SHOT_FONT=$BERGR_SHOT_FONT} \
    "${xcodebuild[@]}" test-without-building | xcbeautify --quiet

xcrun devicectl device copy from --device "$device" --domain-type appDataContainer --domain-identifier "$bundle" \
    --source "Documents/$name.mp4" --destination "$out/raw.mp4" >/dev/null
ffmpeg -v error -y -i "$out/raw.mp4" -vf "fps=30,scale=1280:-2:flags=lanczos" \
    -c:v libx264 -preset slow -crf 26 -pix_fmt yuv420p -movflags +faststart -an "$out/bergr.mp4"
length="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$out/bergr.mp4")"
echo "Device video (${length%.*}s): $out/bergr.mp4 ($(du -h "$out/bergr.mp4" | cut -f1)); raw: $out/raw.mp4"
