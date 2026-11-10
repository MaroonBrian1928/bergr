# Modified for Bergr, 2026, from Hirte (Apache-2.0). See the git history for all changes.
# Sourced by screenshots.sh and video.sh. Needs $device_type, $sim_name and $appearance; sets $device:
# a booted simulator in US English with Apple's marketing status bar and no Bergr Dev installed.

# A dedicated simulator on the newest iOS that supports the device (the iPhone Duo has its own
# runtime), so personal data never shows up.
device="$(xcrun simctl list devices -j | python3 -I -c '
import json, sys
name = sys.argv[1]
for runtime, ds in json.load(sys.stdin)["devices"].items():
    for d in ds:
        if d["name"] == name and d["isAvailable"]: print(d["udid"]); sys.exit()' "$sim_name")"
if [ -z "$device" ]; then
    type_id="$(xcrun simctl list devicetypes -j | python3 -I -c '
import json, sys
print(next(t["identifier"] for t in json.load(sys.stdin)["devicetypes"] if t["name"] == sys.argv[1]))' "$device_type")"
    runtime="$(xcrun simctl list runtimes -j | python3 -I -c '
import json, sys
type_id = sys.argv[1]
rs = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]
      and any(t["identifier"] == type_id for t in r.get("supportedDeviceTypes", []))]
print(max(rs, key=lambda r: [int(x) for x in r["version"].split(".")])["identifier"])' "$type_id")"
    device="$(xcrun simctl create "$sim_name" "$type_id" "$runtime")"
    echo "created simulator $sim_name ($device) on $runtime"
fi

xcrun simctl boot "$device" 2>/dev/null || true
xcrun simctl bootstatus "$device" -b >/dev/null
# US English, so the status bar reads 9:41 (not 09:41). Takes a reboot the first time.
if [ "$(xcrun simctl spawn "$device" defaults read -g AppleLocale 2>/dev/null)" != "en_US" ]; then
    xcrun simctl spawn "$device" defaults write -g AppleLocale en_US
    xcrun simctl spawn "$device" defaults write -g AppleLanguages -array en
    xcrun simctl shutdown "$device"
    xcrun simctl boot "$device"
    xcrun simctl bootstatus "$device" -b >/dev/null
fi
xcrun simctl ui "$device" appearance "$appearance"
# Apple's marketing status bar: 9:41, full signal and battery.
xcrun simctl status_bar "$device" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --operatorName "" --batteryState discharging --batteryLevel 100
# Start from a fresh install, so the first screen offers the demo.
xcrun simctl uninstall "$device" "${BERGR_BUNDLE_ID_PREFIX:-com.pavelzw}.bergr.dev" 2>/dev/null || true

