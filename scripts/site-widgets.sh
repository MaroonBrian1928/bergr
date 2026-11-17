#!/usr/bin/env bash
# Re-draws the marketing site's widget pictures from the real widget code and drops them into the
# site repo.
#
#   scripts/site-widgets.sh [site-dir]      (default: ../bergr-site)
#
# scripts/widget-render/render.sh draws the widget extension's own views (BergrLiveActivity/) with
# ImageRenderer at @3x; this converts them to
#   <site-dir>/assets/shot-usage-widget-{light,dark}.jpg        460×460
#   <site-dir>/assets/shot-home-widgets-{light,dark}.jpg        800×1739
#   <site-dir>/assets/shot-lock-live-activity-{light,dark}.jpg  800×1739
# A widget design change shows up on the next run. The data: scripts/widget-render/SiteWidgetFixture.swift;
# the Home and Lock Screen backdrops: scripts/widget-render/Render.swift.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
site="${1:-$root/../bergr-site}"
[ -d "$site/assets" ] || { echo "no site at $site (pass its folder)" >&2; exit 1; }

work="$(mktemp -d /tmp/bergr-site-widgets.XXXXXX)"
trap 'rm -rf "$work"' EXIT
"$root/scripts/widget-render/render.sh" "$work"

convert() { # name, mode, width x height
  sips -s format jpeg -s formatOptions 78 -z "${3#*x}" "${3%x*}" "$work/$1-$2.png" \
    --out "$site/assets/shot-$1-$2.jpg" >/dev/null
}
for mode in light dark; do
  convert usage-widget "$mode" 460x460
  convert home-widgets "$mode" 800x1739
  convert lock-live-activity "$mode" 800x1739
done
echo "Done: shot-{usage-widget,home-widgets,lock-live-activity}-{light,dark}.jpg. Review: git -C \"$site\" diff --stat"
