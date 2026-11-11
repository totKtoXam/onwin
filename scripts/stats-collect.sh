#!/usr/bin/env bash
# Prints one CSV line with the download counters of all onwin releases on GitHub, summed over every
# release: these counters are kept by GitHub itself, onwin sends nothing extra.
#
#   scripts/stats-collect.sh [owner/name]      → 2026-11-12,3,0,7,4,15
#
# Columns (cumulative since the first release):
#   date         UTC day of the measurement
#   dmg          Onwin-<v>.dmg downloads (the main DMG; light since 0.1.2)
#   dmg_offline  Onwin-<v>-offline.dmg downloads (DMG with the engine inside)
#   app_zip      Onwin-<v>-app.zip: installs and updates from the Terminal command and from onwin itself
#   engine       onwin-engine-<id>.tar.xz: engine downloads (installer, first launch of the light DMG)
#   manifest     onwin-release.json: read by every Terminal install and by onwin's update check (at most
#                once a day, only where the user allowed automatic checks) → daily users estimate
#
# Needs gh (logged in, or GH_TOKEN in GitHub Actions) and jq.
set -euo pipefail

repo="${1:-${GITHUB_REPOSITORY:-totKtoXam/onwin}}"
header="date,dmg,dmg_offline,app_zip,engine,manifest"
[ "${STATS_HEADER:-0}" = 1 ] && echo "$header"

gh api --paginate "repos/$repo/releases?per_page=100" --jq '.[].assets[] | [.name, .download_count] | @tsv' |
awk -F'\t' -v day="$(date -u +%F)" '
    $1 ~ /-offline\.dmg$/              { offline += $2; next }
    $1 ~ /^Onwin-.*\.dmg$/             { dmg += $2; next }
    $1 ~ /^Onwin-.*-app\.zip$/         { zip += $2; next }
    $1 ~ /^onwin-engine-.*\.tar\.xz$/  { engine += $2; next }
    $1 == "onwin-release.json"         { manifest += $2; next }
    END { printf "%s,%d,%d,%d,%d,%d\n", day, dmg, offline, zip, engine, manifest }'
