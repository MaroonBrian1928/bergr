# Build, install and run Hirte. Device and simulator come from .envrc / .envrc.local.

project := "hirte.xcodeproj"
scheme := "hirte"
# Signing team and bundle ID prefix: the project's (DEVELOPMENT_TEAM, HIRTE_BUNDLE_ID_PREFIX), or
# your own from HIRTE_TEAM and HIRTE_BUNDLE_ID_PREFIX (see .envrc).
team := env_var_or_default("HIRTE_TEAM", "")
bundle_prefix := env_var_or_default("HIRTE_BUNDLE_ID_PREFIX", "com.pavelzw")
signing := (if team != "" { " DEVELOPMENT_TEAM=" + team } else { "" }) + " HIRTE_BUNDLE_ID_PREFIX=" + bundle_prefix
# Debug builds are a separate app ("Hirte Dev"), so they install next to the TestFlight/App Store one.
bundle_id := bundle_prefix + ".hirte"
dev_bundle_id := bundle_id + ".dev"
derived := ".build/xcode"
# The App Store Connect API key for uploads, encrypted with sops (not committed; see .envrc).
asc_key_file := ".appstoreconnect.sops.yaml"
xcodebuild := "xcodebuild -project " + project + " -scheme " + scheme + " -derivedDataPath " + derived + " -allowProvisioningUpdates" + signing

default:
    @just --list

# Build, install and launch on a device: `just phone` (HIRTE_DEVICE, else the first connected
# iPhone), `just phone ipad` (HIRTE_DEVICE_IPAD), `just phone ipad Release`
phone device="" configuration="Debug": (_phone-build device configuration)
    #!/usr/bin/env bash
    set -euo pipefail
    device="$(just _device "{{device}}")"
    app="{{derived}}/Build/Products/{{configuration}}-iphoneos/{{scheme}}.app"
    xcrun devicectl device install app --device "$device" "$app"
    id="{{ if configuration == "Debug" { dev_bundle_id } else { bundle_id } }}"
    xcrun devicectl device process launch --device "$device" --terminate-existing "$id"

_phone-build device configuration:
    #!/usr/bin/env bash
    set -euo pipefail
    device="$(just _device "{{device}}")"
    # -allowProvisioningDeviceRegistration: a device seen for the first time joins the team's
    # development profile, instead of failing with "profile doesn't include the device".
    {{xcodebuild}} -allowProvisioningDeviceRegistration -configuration {{configuration}} -destination "id=$device" build | xcbeautify --quiet

# Build and run in the simulator (HIRTE_SIMULATOR, default "iPhone 17 Pro")
sim:
    #!/usr/bin/env bash
    set -euo pipefail
    sim="${HIRTE_SIMULATOR:-iPhone 17 Pro}"
    {{xcodebuild}} -configuration Debug -destination "platform=iOS Simulator,name=$sim" build | xcbeautify --quiet
    xcrun simctl boot "$sim" 2>/dev/null || true
    xcrun simctl bootstatus "$sim" -b >/dev/null
    open -a Simulator
    xcrun simctl install "$sim" "{{derived}}/Build/Products/Debug-iphonesimulator/{{scheme}}.app"
    xcrun simctl launch --terminate-running-process "$sim" {{dev_bundle_id}}

# Build for any iOS device without installing (checks that it compiles)
build:
    {{xcodebuild}} -configuration Debug -destination "generic/platform=iOS" build | xcbeautify --quiet

# The build number is CURRENT_PROJECT_VERSION in the project; a successful upload raises it by one
# (commit that change). Start again at 1 when MARKETING_VERSION changes.
# Archive for the App Store into .build/export; `just archive true` uploads it
archive upload="false":
    #!/usr/bin/env bash
    set -euo pipefail
    test -d HerdrKit/Frameworks/ghostty-vt.xcframework || just ghostty
    project=hirte.xcodeproj/project.xcproj
    builds="$(grep -o '"CURRENT_PROJECT_VERSION": "[0-9]*"' "$project" | sort -u)"
    if [ "$(echo "$builds" | wc -l)" -ne 1 ]; then echo "targets disagree on CURRENT_PROJECT_VERSION:" >&2; echo "$builds" >&2; exit 1; fi
    build="$(echo "$builds" | grep -o '[0-9]*"$' | tr -d '"')"
    version="$(grep -o '"MARKETING_VERSION": "[^"]*"' "$project" | head -1 | cut -d'"' -f4)"
    # The App Store Connect API key from the sops-encrypted key file, checked before the long
    # build; the .p8 is decrypted into a temporary file for this run only.
    if [ ! -f {{asc_key_file}} ]; then
        echo "{{asc_key_file}} is missing: an App Store Connect API key (role Admin), encrypted with sops (see .envrc)." >&2
        exit 1
    fi
    key="$(mktemp -t hirte-asc).p8"
    trap 'rm -f "$key"' EXIT
    secret() {
        local value
        value="$(sops decrypt --extract "[\"$1\"]" {{asc_key_file}})" && [ -n "$value" ] || {
            echo "Could not read $1 from {{asc_key_file}} (is SOPS_AGE_KEY_FILE set?)." >&2
            exit 1
        }
        printf '%s\n' "$value"
    }
    key_id="$(secret key_id)"
    issuer_id="$(secret issuer_id)"
    (umask 077; secret private_key > "$key")
    grep -q "BEGIN PRIVATE KEY" "$key" || { echo "private_key in {{asc_key_file}} is not a .p8 key." >&2; exit 1; }
    auth=(-authenticationKeyPath "$key" -authenticationKeyID "$key_id" -authenticationKeyIssuerID "$issuer_id")
    rm -rf .build/Hirte.xcarchive .build/export
    {{xcodebuild}} -configuration Release -destination "generic/platform=iOS" \
        -archivePath .build/Hirte.xcarchive ${auth[@]+"${auth[@]}"} archive | xcbeautify --quiet
    options=.build/ExportOptions.plist
    cp scripts/ExportOptions.plist "$options"
    if [ -n "{{team}}" ]; then plutil -replace teamID -string "{{team}}" "$options"; fi
    if [ "{{upload}}" = "true" ]; then plutil -insert destination -string upload "$options"; fi
    # Xcode's /usr/bin/rsync (openrsync) starts `rsync` from PATH as its peer; a newer rsync
    # from pixi or Homebrew rejects its flags ("Copy failed"), so put the system one first.
    PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH" xcodebuild -exportArchive -archivePath .build/Hirte.xcarchive -exportPath .build/export \
        -exportOptionsPlist "$options" -allowProvisioningUpdates ${auth[@]+"${auth[@]}"} | xcbeautify --quiet
    if [ "{{upload}}" = "true" ]; then
        next=$((build + 1))
        sed -i '' "s/\"CURRENT_PROJECT_VERSION\": \"$build\"/\"CURRENT_PROJECT_VERSION\": \"$next\"/" "$project"
        echo "$version ($build) uploaded; it shows up in App Store Connect / TestFlight after processing."
        echo "The next build is $next: commit $project."
    else
        echo "$version ($build) exported to .build/export (just archive true uploads it)"
    fi

# App Store screenshots of the demo, framed with captions, into .build/screenshots/<device>
# (iPhone 17 Pro by default, App Store Connect's required size; also "iPhone Duo", "iPhone 17 Pro Max")
screenshots appearance="dark" device="iPhone 17 Pro":
    scripts/screenshots.sh {{appearance}} "{{device}}"

# The README video of the demo, framed, into .build/video/<device> (hirte.mp4 and hirte.gif)
video appearance="dark" device="iPhone 17 Pro":
    scripts/video.sh {{appearance}} "{{device}}"

# The demo video on your iPhone (unfold the Duo and unlock it first), into .build/video/device
video-device:
    scripts/video-device.sh

# Regenerate hirte/Settings/themes.json (the terminal themes) from Ghostty's theme collection
themes:
    python3 -I scripts/themes.py

# Regenerate hirte/Licenses/licenses.json after changing Swift packages or the Ghostty pin
licenses:
    python3 -I scripts/licenses.py

# The submodule is pinned because the C API is unstable; we use herdr-core's pin by default
# (a tested combination), but nothing in the protocol requires the two to match.
# Build libghostty-vt (vendor/ghostty) into HerdrKit/Frameworks
ghostty:
    #!/usr/bin/env bash
    set -euo pipefail
    git submodule update --init --depth 1 vendor/ghostty
    cd vendor/ghostty
    # Each Ghostty commit needs one Zig version; this pin builds with 0.16.0.
    pixi exec -c conda-forge --spec 'zig==0.16.0' -- \
        zig build -Demit-lib-vt -Demit-xcframework -Doptimize=ReleaseFast --prefix ../../.build/ghostty-vt
    cd ../..
    rm -rf HerdrKit/Frameworks/ghostty-vt.xcframework
    mkdir -p HerdrKit/Frameworks
    cp -R .build/ghostty-vt/lib/ghostty-vt.xcframework HerdrKit/Frameworks/
    echo "HerdrKit/Frameworks/ghostty-vt.xcframework is ready"

# Render the app icons (light, dark, tinted) from assets/logo.svg
icon:
    #!/usr/bin/env bash
    set -euo pipefail
    out=hirte/Assets.xcassets/AppIcon.appiconset
    render() { sed -e "s/#d9dad8/$2/g" -e "s/#303438/$3/g" assets/logo.svg | rsvg-convert -w 1024 -h 1024 -b "$2" -o "$out/$1"; }
    render icon-light.png '#d9dad8' '#303438'
    render icon-dark.png '#1f2124' '#d9dad8'
    render icon-tinted.png '#000000' '#ffffff'
    # Debug builds ("Hirte Dev"): the same mark in amber, so the two apps are easy to tell apart.
    out=hirte/Assets.xcassets/AppIcon-Dev.appiconset
    mkdir -p "$out"
    cp hirte/Assets.xcassets/AppIcon.appiconset/Contents.json "$out/"
    render icon-light.png '#f2b33d' '#303438'
    render icon-dark.png '#1f2124' '#f2b33d'
    render icon-tinted.png '#000000' '#ffffff'
    # The App Store rejects icons with an alpha channel.
    for f in hirte/Assets.xcassets/AppIcon*.appiconset/icon-*.png; do sips -s format png -s hasAlpha no "$f" >/dev/null 2>&1 || true; done
    echo "icons written to hirte/Assets.xcassets/AppIcon.appiconset and AppIcon-Dev.appiconset"

# Run the HerdrKit package tests on this Mac (includes a live test against local herdr-core)
test:
    cd HerdrKit && swift test

# Stream the app's logs from the phone (the dev app; `just logs Release` for the TestFlight/App Store one)
logs configuration="Debug":
    xcrun devicectl device process launch --device "$(just _device)" --terminate-existing --console {{ if configuration == "Debug" { dev_bundle_id } else { bundle_id } }}

# List physical devices
devices:
    xcrun devicectl list devices | grep -E "Identifier|physical"

clean:
    rm -rf {{derived}} HerdrKit/.build .build/ghostty-vt

# The target device: by name, HIRTE_DEVICE_<NAME> (`ipad` → HIRTE_DEVICE_IPAD); without one,
# HIRTE_DEVICE, else the first connected physical iPhone
_device name="":
    #!/usr/bin/env bash
    set -euo pipefail
    name="{{name}}"
    if [ -n "$name" ]; then
        var="HIRTE_DEVICE_$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9\n' '_')"
        if [ -z "${!var:-}" ]; then
            echo "$var isn't set. Add it to .envrc.local (the identifier from: just devices)." >&2
            known="$(compgen -v | grep '^HIRTE_DEVICE_' | sed 's/^HIRTE_DEVICE_//' | tr '[:upper:]' '[:lower:]' | xargs)"
            if [ -n "$known" ]; then echo "Known devices: $known" >&2; fi
            exit 1
        fi
        echo "${!var}"
        exit
    fi
    if [ -n "${HIRTE_DEVICE:-}" ]; then echo "$HIRTE_DEVICE"; exit; fi
    id="$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && /physical/ && (/connected/ || /available/) { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) { print $i; exit } }')"
    if [ -z "$id" ]; then echo "No connected iPhone (unlock it, or plug it in). Plug it in, or set HIRTE_DEVICE in .envrc.local (see: just devices)." >&2; exit 1; fi
    echo "$id"
