# Modified for Bergr, 2026, from Hirte (Apache-2.0). See the git history for all changes.
# Build, install and run Bergr. Device and simulator come from .envrc / .envrc.local.

project := "bergr.xcodeproj"
scheme := "bergr"
# Signing team and bundle ID prefix: the project's (DEVELOPMENT_TEAM, BERGR_BUNDLE_ID_PREFIX), or
# your own from BERGR_TEAM and BERGR_BUNDLE_ID_PREFIX (see .envrc).
team := env_var_or_default("BERGR_TEAM", "")
bundle_prefix := env_var_or_default("BERGR_BUNDLE_ID_PREFIX", "com.pavelzw")
signing := (if team != "" { " DEVELOPMENT_TEAM=" + team } else { "" }) + " BERGR_BUNDLE_ID_PREFIX=" + bundle_prefix
# Debug builds are a separate app ("Bergr Dev"), so they install next to the TestFlight/App Store one.
bundle_id := bundle_prefix + ".bergr"
dev_bundle_id := bundle_id + ".dev"
derived := ".build/xcode"
# The App Store Connect API key for uploads, encrypted with sops (not committed; see .envrc).
asc_key_file := ".appstoreconnect.sops.yaml"
xcodebuild := "xcodebuild -project " + project + " -scheme " + scheme + " -derivedDataPath " + derived + " -allowProvisioningUpdates" + signing

default:
    @just --list

# Build, install and launch on a device: `just phone` (BERGR_DEVICE, else the first connected
# iPhone), `just phone ipad` (BERGR_DEVICE_IPAD), `just phone ipad Release`
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
    # An App Store Connect API key (BERGR_ASC_KEY_PATH/_ID/_ISSUER, e.g. in .envrc.local) signs
    # without Xcode's login, which command-line builds don't always see.
    auth=()
    if [ -n "${BERGR_ASC_KEY_PATH:-}" ]; then
        auth=(-authenticationKeyPath "${BERGR_ASC_KEY_PATH/#\~/$HOME}" -authenticationKeyID "$BERGR_ASC_KEY_ID" -authenticationKeyIssuerID "$BERGR_ASC_KEY_ISSUER")
    fi
    {{xcodebuild}} -allowProvisioningDeviceRegistration ${auth[@]+"${auth[@]}"} -configuration {{configuration}} -destination "id=$device" build | xcbeautify --quiet

# Build, install and open on this Mac (Apple silicon runs it as the iPad app, "Designed for iPad")
mac configuration="Debug":
    #!/usr/bin/env bash
    set -euo pipefail
    auth=()
    if [ -n "${BERGR_ASC_KEY_PATH:-}" ]; then
        auth=(-authenticationKeyPath "${BERGR_ASC_KEY_PATH/#\~/$HOME}" -authenticationKeyID "$BERGR_ASC_KEY_ID" -authenticationKeyIssuerID "$BERGR_ASC_KEY_ISSUER")
    fi
    xcodebuild -project {{project}} -scheme {{scheme}} -derivedDataPath .build/xcode-mac -allowProvisioningUpdates -allowProvisioningDeviceRegistration{{signing}} ${auth[@]+"${auth[@]}"} \
        -configuration {{configuration}} -destination 'platform=macOS,variant=Designed for iPad,arch=arm64' build | xcbeautify --quiet
    name="{{ if configuration == "Debug" { "Bergr Dev" } else { "Bergr" } }}"
    dest="/Applications/$name.app"
    # iPhone and iPad apps run on the Mac from inside a wrapper, as the App Store installs them.
    osascript -e "tell application \"$name\" to quit" 2>/dev/null || true
    rm -rf "$dest"
    mkdir -p "$dest/Wrapper"
    cp -R ".build/xcode-mac/Build/Products/{{configuration}}-iphoneos/{{scheme}}.app" "$dest/Wrapper/{{scheme}}.app"
    ln -s "Wrapper/{{scheme}}.app" "$dest/WrappedBundle"
    open "$dest"

# Build and run in the simulator (BERGR_SIMULATOR, default "iPhone 17 Pro")
sim:
    #!/usr/bin/env bash
    set -euo pipefail
    sim="${BERGR_SIMULATOR:-iPhone 17 Pro}"
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
    project=bergr.xcodeproj/project.xcproj
    builds="$(grep -o '"CURRENT_PROJECT_VERSION": "[0-9]*"' "$project" | sort -u)"
    if [ "$(echo "$builds" | wc -l)" -ne 1 ]; then echo "targets disagree on CURRENT_PROJECT_VERSION:" >&2; echo "$builds" >&2; exit 1; fi
    build="$(echo "$builds" | grep -o '[0-9]*"$' | tr -d '"')"
    version="$(grep -o '"MARKETING_VERSION": "[^"]*"' "$project" | head -1 | cut -d'"' -f4)"
    # The App Store Connect API key, checked before the long build: BERGR_ASC_KEY_PATH/_ID/_ISSUER
    # (e.g. in .envrc.local) when set, else the sops-encrypted key file, decrypted into a temporary
    # file for this run only.
    if [ -n "${BERGR_ASC_KEY_PATH:-}" ]; then
        key="${BERGR_ASC_KEY_PATH/#\~/$HOME}"
        [ -f "$key" ] || { echo "BERGR_ASC_KEY_PATH points to a missing file." >&2; exit 1; }
        [ -n "${BERGR_ASC_KEY_ID:-}" ] && [ -n "${BERGR_ASC_KEY_ISSUER:-}" ] || { echo "Set BERGR_ASC_KEY_ID and BERGR_ASC_KEY_ISSUER too." >&2; exit 1; }
        auth=(-authenticationKeyPath "$key" -authenticationKeyID "$BERGR_ASC_KEY_ID" -authenticationKeyIssuerID "$BERGR_ASC_KEY_ISSUER")
    else
        if [ ! -f {{asc_key_file}} ]; then
            echo "No App Store Connect API key: set BERGR_ASC_KEY_PATH/_ID/_ISSUER, or add {{asc_key_file}} (sops, see .envrc)." >&2
            exit 1
        fi
        key="$(mktemp -t bergr-asc).p8"
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
    fi
    rm -rf .build/Bergr.xcarchive .build/export
    # BERGR_ARCHIVE_WITH_ACCOUNT=1 signs and uploads with the Apple account in Xcode's settings
    # instead (when the API key can't create the release profiles).
    if [ -n "${BERGR_ARCHIVE_WITH_ACCOUNT:-}" ]; then auth=(); fi
    # Hand signing: when an "Apple Distribution" identity is in the keychain and App Store profiles
    # named "Bergr AppStore <bundle ID>" are installed (made with the API key; xcodebuild's own
    # provisioning rejects the key), sign with those instead of letting Xcode fetch profiles.
    profiles="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
    manual=()
    if security find-identity -v -p codesigning | grep -q "Apple Distribution" &&
        grep -lqa "Bergr AppStore {{bundle_prefix}}.bergr<" "$profiles"/*.mobileprovision 2>/dev/null; then
        # Each profile goes only to its own target: a variable named after the bundle ID, empty
        # (no profile) for the packages' resource bundles.
        manual=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=Apple Distribution"
            'PROVISIONING_PROFILE_SPECIFIER=$(BERGR_PROFILE_$(PRODUCT_BUNDLE_IDENTIFIER:identifier))')
        for id in {{bundle_prefix}}.bergr {{bundle_prefix}}.bergr.NotificationService {{bundle_prefix}}.bergr.LiveActivity; do
            manual+=("BERGR_PROFILE_${id//[.-]/_}=Bergr AppStore $id")
        done
        echo "Signing by hand with the Bergr AppStore profiles."
    fi
    {{xcodebuild}} -configuration Release -destination "generic/platform=iOS" \
        -archivePath .build/Bergr.xcarchive ${auth[@]+"${auth[@]}"} ${manual[@]+"${manual[@]}"} archive | xcbeautify --quiet
    options=.build/ExportOptions.plist
    cp scripts/ExportOptions.plist "$options"
    if [ -n "{{team}}" ]; then plutil -replace teamID -string "{{team}}" "$options"; fi
    if [ ${#manual[@]} -gt 0 ]; then
        plutil -replace signingStyle -string manual "$options"
        plutil -replace signingCertificate -string "Apple Distribution" "$options"
        plutil -replace provisioningProfiles -dictionary "$options"
        for id in {{bundle_prefix}}.bergr {{bundle_prefix}}.bergr.NotificationService {{bundle_prefix}}.bergr.LiveActivity; do
            plutil -replace "provisioningProfiles.${id//./\\.}" -string "Bergr AppStore $id" "$options"
        done
    fi
    if [ "{{upload}}" = "true" ]; then plutil -insert destination -string upload "$options"; fi
    # Xcode's /usr/bin/rsync (openrsync) starts `rsync` from PATH as its peer; a newer rsync
    # from pixi or Homebrew rejects its flags ("Copy failed"), so put the system one first.
    PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH" xcodebuild -exportArchive -archivePath .build/Bergr.xcarchive -exportPath .build/export \
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

# The README video of the demo, framed, into .build/video/<device> (bergr.mp4 and bergr.gif)
video appearance="dark" device="iPhone 17 Pro":
    scripts/video.sh {{appearance}} "{{device}}"

# The demo video on your iPhone (unfold the Duo and unlock it first), into .build/video/device
video-device:
    scripts/video-device.sh

# Regenerate bergr/Settings/themes.json (the terminal themes) from Ghostty's theme collection
themes:
    python3 -I scripts/themes.py

# Regenerate bergr/Licenses/licenses.json after changing Swift packages or the Ghostty pin
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

# Export the app icons (light, dark, tinted) from the approved PNG artwork.
icon:
    swift scripts/icons.swift

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

# The target device: by name, BERGR_DEVICE_<NAME> (`ipad` → BERGR_DEVICE_IPAD); without one,
# BERGR_DEVICE, else the first connected physical iPhone
_device name="":
    #!/usr/bin/env bash
    set -euo pipefail
    name="{{name}}"
    if [ -n "$name" ]; then
        var="BERGR_DEVICE_$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9\n' '_')"
        if [ -z "${!var:-}" ]; then
            echo "$var isn't set. Add it to .envrc.local (the identifier from: just devices)." >&2
            known="$(compgen -v | grep '^BERGR_DEVICE_' | sed 's/^BERGR_DEVICE_//' | tr '[:upper:]' '[:lower:]' | xargs)"
            if [ -n "$known" ]; then echo "Known devices: $known" >&2; fi
            exit 1
        fi
        echo "${!var}"
        exit
    fi
    if [ -n "${BERGR_DEVICE:-}" ]; then echo "$BERGR_DEVICE"; exit; fi
    id="$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && /physical/ && (/connected/ || /available/) { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) { print $i; exit } }')"
    if [ -z "$id" ]; then echo "No connected iPhone (unlock it, or plug it in). Plug it in, or set BERGR_DEVICE in .envrc.local (see: just devices)." >&2; exit 1; fi
    echo "$id"
