#!/bin/zsh
# Run from a regular macOS Terminal. Uploads the version and build in the project.
set -e
set -o pipefail

cd -- "${0:A:h}/.."
if [[ ! -r .envrc.local ]]; then
    print -u2 "Missing .envrc.local. Set up Bergr's local signing configuration first."
    exit 1
fi
set -a
source ./.envrc.local >/dev/null
set +a
: "${BERGR_ASC_KEY_PATH:?Missing App Store Connect key path}"
: "${BERGR_ASC_KEY_ID:?Missing App Store Connect key ID}"
: "${BERGR_ASC_KEY_ISSUER:?Missing App Store Connect issuer}"
command -v node >/dev/null
command -v just >/dev/null

project=bergr.xcodeproj/project.xcproj
version=$(awk -F '"' '/"MARKETING_VERSION"/ { print $4 }' "$project" | sort -u)
build=$(awk -F '"' '/"CURRENT_PROJECT_VERSION"/ { print $4 }' "$project" | sort -u)
if [[ ! $version =~ '^[0-9]+\.[0-9]+\.[0-9]+$' || ! $build =~ '^[0-9]+$' ]]; then
    print -u2 'Expected one marketing version and one build number across all targets.'
    exit 1
fi
notes="appstore/testflight/$version.md"
if [[ ! -s $notes ]]; then
    print -u2 "Missing TestFlight notes at $notes."
    exit 1
fi

print "Uploading Bergr $version ($build) to TestFlight."
just archive true
if ! node scripts/testflight-notes.mjs "$version" "$build" "$notes"; then
    print -u2 'The build uploaded, but posting the notes failed. Retry only the notes command:'
    print -u2 "node scripts/testflight-notes.mjs $version $build $notes"
    exit 1
fi
