#!/usr/bin/env bash
# Release the native Mac app: archive, Developer ID export, DMG, notarize, staple, Sparkle appcast,
# and (with --upload) a GitHub release. See docs/mac-release.md for the one-time setup.
#   scripts/mac-release.sh [--dry-run] [--upload]
# --dry-run prints the steps and checks the prerequisites; it builds and contacts nothing.
set -euo pipefail
cd "$(dirname "$0")/.."

dry=0 upload=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) dry=1 ;;
        --upload) upload=1 ;;
        *) echo "usage: $0 [--dry-run] [--upload]" >&2; exit 2 ;;
    esac
done

project=bergr.xcodeproj/project.xcproj
out=.build/mac
bundle_prefix="${BERGR_BUNDLE_ID_PREFIX:-com.redacted}"
team="${BERGR_TEAM:-DW336Y9ABR}"
version="$(grep -o '"MARKETING_VERSION": "[^"]*"' "$project" | sort -u | head -1 | cut -d'"' -f4)"
tag="mac-v$version"
dmg="$out/dist/Bergr-$version.dmg"
repo=MaroonBrian1928/bergr

missing=0
need() { # description, then a test command
    local what="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "  ok       $what"; else echo "  MISSING  $what"; missing=1; fi
}
run() {
    echo "+ $*"
    if [ "$dry" -eq 0 ]; then "$@"; fi
}

key="${BERGR_ASC_KEY_PATH:-}"; key="${key/#\~/$HOME}"
sparkle_bin="${BERGR_SPARKLE_BIN:-}"
if [ -z "$sparkle_bin" ]; then
    sparkle_bin="$(find .build "$HOME/Library/Developer/Xcode/DerivedData" -path '*artifacts/sparkle/Sparkle/bin' -type d 2>/dev/null | head -1 || true)"
fi
sparkle_key="${BERGR_SPARKLE_KEY_FILE:-}"; sparkle_key="${sparkle_key/#\~/$HOME}"
pubkey="$(plutil -extract SUPublicEDKey raw Config/Mac-Info.plist 2>/dev/null || true)"

echo "Bergr $version ($tag), team $team"
echo "Prerequisites:"
need "version in $project" test -n "$version"
need "ghostty-vt.xcframework (just ghostty)" test -d HerdrKit/Frameworks/ghostty-vt.xcframework
need "Developer ID Application certificate in the keychain" bash -c 'security find-identity -v -p codesigning | grep -q "Developer ID Application"'
need "BERGR_ASC_KEY_PATH points to a file" test -f "$key"
need "BERGR_ASC_KEY_ID and BERGR_ASC_KEY_ISSUER set" test -n "${BERGR_ASC_KEY_ID:-}" -a -n "${BERGR_ASC_KEY_ISSUER:-}"
need "Sparkle tools (generate_appcast; set BERGR_SPARKLE_BIN)" test -x "$sparkle_bin/generate_appcast"
need "Sparkle public key in Config/Mac-Info.plist (SUPublicEDKey)" test -n "$pubkey"
if [ -n "$sparkle_key" ]; then
    need "BERGR_SPARKLE_KEY_FILE exists" test -f "$sparkle_key"
else
    echo "  note     no BERGR_SPARKLE_KEY_FILE: generate_appcast reads the key from the login keychain"
fi
if [ "$upload" -eq 1 ]; then
    need "gh logged in" gh auth status
    need "tag $tag not released yet" bash -c "! gh release view '$tag' --repo '$repo'"
fi
if [ "$missing" -ne 0 ]; then
    if [ "$dry" -eq 1 ]; then
        echo "Some prerequisites are missing (dry run continues)."
    else
        echo "Fix the missing prerequisites first (docs/mac-release.md)." >&2
        exit 1
    fi
fi

auth=(-authenticationKeyPath "$key" -authenticationKeyID "${BERGR_ASC_KEY_ID:-<id>}" -authenticationKeyIssuerID "${BERGR_ASC_KEY_ISSUER:-<issuer>}")
signing=(DEVELOPMENT_TEAM="$team" BERGR_BUNDLE_ID_PREFIX="$bundle_prefix")

echo "Steps:"
run rm -rf "$out"
run mkdir -p "$out/dist" "$out/staging"
run xcodebuild -project bergr.xcodeproj -scheme bergrMac -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$out/derived" -archivePath "$out/Bergr.xcarchive" -allowProvisioningUpdates "${auth[@]}" "${signing[@]}" archive
run cp Config/MacExportOptions.plist "$out/ExportOptions.plist"
run plutil -replace teamID -string "$team" "$out/ExportOptions.plist"
# Xcode's openrsync wants the system rsync first in PATH (see `just archive`).
run env PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH" xcodebuild -exportArchive -archivePath "$out/Bergr.xcarchive" \
    -exportOptionsPlist "$out/ExportOptions.plist" -exportPath "$out/export" -allowProvisioningUpdates "${auth[@]}"
run codesign --verify --deep --strict --verbose=2 "$out/export/Bergr.app"
run cp -R "$out/export/Bergr.app" "$out/staging/Bergr.app"
run ln -s /Applications "$out/staging/Applications"
run hdiutil create -volname Bergr -srcfolder "$out/staging" -ov -format UDZO "$dmg"
run codesign --sign "Developer ID Application" --timestamp "$dmg"
run xcrun notarytool submit "$dmg" --key "$key" --key-id "${BERGR_ASC_KEY_ID:-<id>}" --issuer "${BERGR_ASC_KEY_ISSUER:-<issuer>}" --wait
run xcrun stapler staple "$dmg"
run spctl -a -t open --context context:primary-signature -v "$dmg"
appcast_args=(--download-url-prefix "https://github.com/$repo/releases/download/$tag/")
if [ -n "$sparkle_key" ]; then appcast_args+=(--ed-key-file "$sparkle_key"); fi
run "$sparkle_bin/generate_appcast" "${appcast_args[@]}" -o "$out/dist/appcast.xml" "$out/dist"

if [ "$dry" -eq 1 ]; then
    sha="<sha256 of the DMG>"
else
    sha="$(shasum -a 256 "$dmg" | cut -d' ' -f1)"
fi
echo "+ fill scripts/homebrew/bergr.rb -> $out/bergr.rb (version $version, sha256 $sha)"
if [ "$dry" -eq 0 ]; then
    sed -e "s/@VERSION@/$version/" -e "s/@SHA256@/$sha/" scripts/homebrew/bergr.rb > "$out/bergr.rb"
fi
if [ "$upload" -eq 1 ]; then
    run gh release create "$tag" "$dmg" "$out/dist/appcast.xml" --repo "$repo" --title "Bergr $version (Mac)" \
        --notes "${BERGR_RELEASE_NOTES:-Bergr $version for macOS.}"
else
    echo "Not uploaded: run \`just mac-release true\` to create the GitHub release $tag."
fi
echo "Cask: copy $out/bergr.rb to Casks/bergr.rb in MaroonBrian1928/homebrew-tap and push it."
