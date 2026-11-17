#!/usr/bin/env bash
# Re-takes the marketing site's app screenshots from the demo and drops them into the site repo.
#
#   scripts/site-shots.sh [site-dir]      (default: ../bergr-site)
#
# Runs bergrUITests/DemoShotsTests in light and dark on its own simulator with a 9:41 status bar,
# converts the frames the site uses to ~800 px JPEGs (q78) and writes them as
# <site-dir>/assets/shot-<name>-{light,dark}.jpg. The page's markup doesn't change: same file names.
# Then review with `git -C <site-dir> diff --stat` and the page, and commit there.
# Signing: source .envrc.local first (BERGR_TEAM / BERGR_BUNDLE_ID_PREFIX), like `just phone`.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
site="${1:-$root/../bergr-site}"
[ -d "$site/assets" ] || { echo "no site at $site (pass its folder)" >&2; exit 1; }

# Site asset name → demo frame (bergrUITests/DemoShotsTests.swift names them).
shots=(
  agents:01-agents
  chat-summaries:02-chat-summaries
  answer-card:03-answer-card
  risky-command:04-dangerous-command
  usage:06-usage
  codex-question:07a-codex-question
  question-card:07q-question-card
  suggestions:10b-codex-finished
  changes:09-changes
)

work="$(mktemp -d /tmp/bergr-site-shots.XXXXXX)"
derived="$work/dd"
sim_name="Bergr site shots"
cleanup() {
  [ -n "${udid:-}" ] && xcrun simctl delete "$udid" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

udid="$(xcrun simctl create "$sim_name" "iPhone 17 Pro")"
xcrun simctl boot "$udid"
xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 \
  --cellularBars 4 --wifiBars 3

signing=()
[ -n "${BERGR_TEAM:-}" ] && signing+=(DEVELOPMENT_TEAM="$BERGR_TEAM")
[ -n "${BERGR_BUNDLE_ID_PREFIX:-}" ] && signing+=(BERGR_BUNDLE_ID_PREFIX="$BERGR_BUNDLE_ID_PREFIX")

for mode in light dark; do
  out="$work/$mode"
  mkdir -p "$out"
  echo "› $mode"
  # A flaky tap now and then: one retry per appearance.
  for attempt in 1 2; do
    if TEST_RUNNER_BERGR_SHOTS="$out" TEST_RUNNER_BERGR_SHOT_APPEARANCE="$mode" xcodebuild test \
         -project "$root/bergr.xcodeproj" -scheme bergr -destination "id=$udid" -derivedDataPath "$derived" \
         -only-testing:bergrUITests/DemoShotsTests \
         -skip-testing:bergrUITests/DemoShotsTests/testLockScreenLiveActivity \
         ${signing[@]+"${signing[@]}"} -quiet >/dev/null 2>&1; then
      break
    fi
    [ "$attempt" = 2 ] && { echo "shot run failed twice ($mode)" >&2; exit 1; }
    echo "  retrying"
  done
done

for pair in "${shots[@]}"; do
  name="${pair%%:*}"; frame="${pair#*:}"
  for mode in light dark; do
    src="$work/$mode/$frame.png"
    [ -f "$src" ] || { echo "missing frame $frame ($mode)" >&2; exit 1; }
    sips -s format jpeg -s formatOptions 78 --resampleWidth 800 "$src" \
      --out "$site/assets/shot-$name-$mode.jpg" >/dev/null
  done
  echo "  shot-$name"
done

echo "Done. Review: git -C \"$site\" diff --stat"
