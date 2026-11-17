#!/usr/bin/env bash
# Draws the real widget and Live Activity views to PNGs (@3x, light and dark):
#   <out-dir>/home-widgets-{light,dark}.png        1206×2622 (iPhone 17 Pro Home Screen)
#   <out-dir>/lock-live-activity-{light,dark}.png  1206×2622 (Lock Screen)
#   <out-dir>/usage-widget-{light,dark}.png         690×690
#
#   scripts/widget-render/render.sh <out-dir>
#
# Compiles BergrLiveActivity/ (minus its @main bundle) with Shared/, SharedIOS/ and this folder
# (Render.swift: the backdrops; SiteWidgetFixture.swift: the data) into a small simulator app and
# runs it on a simulator of its own, deleted afterwards. Used by site-widgets.sh and screenshots.sh.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
out="${1:?usage: render.sh <out-dir>}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"

work="$(mktemp -d /tmp/bergr-widget-render.XXXXXX)"
bundle_id="local.bergr.widget-render"
cleanup() {
  [ -n "${udid:-}" ] && xcrun simctl delete "$udid" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

sources=()
while IFS= read -r f; do sources+=("$f"); done < <(
  find "$root/Shared" "$root/SharedIOS" "$root/BergrLiveActivity" "$root/scripts/widget-render" -name '*.swift' \
    ! -name BergrLiveActivityBundle.swift | sort)

sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
version="$(xcrun --sdk iphonesimulator --show-sdk-version)"
app="$work/WidgetRender.app"
mkdir -p "$app"
echo "› compiling the widget views"
xcrun --sdk iphonesimulator swiftc -parse-as-library -O -swift-version 5 \
  -target "arm64-apple-ios$version-simulator" -sdk "$sdk" \
  -module-name BergrLiveActivity "${sources[@]}" -o "$app/WidgetRender" 2>"$work/build.log" \
  || { cat "$work/build.log" >&2; echo "compiling the widget views failed" >&2; exit 1; }
cat >"$app/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>WidgetRender</string>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleName</key><string>WidgetRender</string>
  <key>MinimumOSVersion</key><string>$version</string>
</dict></plist>
PLIST
codesign --force --sign - "$app" >/dev/null 2>&1

udid="$(xcrun simctl create "Bergr widget render" "iPhone 17 Pro")"
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl install "$udid" "$app"
echo "› drawing"
# The simulator app writes straight into the host folder; --console-pty waits until it exits.
xcrun simctl launch --console-pty "$udid" "$bundle_id" "$out"
for name in home-widgets lock-live-activity usage-widget; do
  for mode in light dark; do
    [ -f "$out/$name-$mode.png" ] || { echo "the renderer made no $name-$mode.png" >&2; exit 1; }
  done
done
