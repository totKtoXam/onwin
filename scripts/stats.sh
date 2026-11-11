#!/usr/bin/env bash
# onwin statistics in the Terminal: downloads now and per day, and the estimate of daily users.
#
#   scripts/stats.sh [days]        (default 14)
#
# The history comes from downloads.csv on the branch «stats» (written daily by .github/workflows/stats.yml),
# the current numbers straight from GitHub (scripts/stats-collect.sh).
#
# «Пользователи в день» ≈ reads of onwin-release.json minus app downloads: onwin reads the file at most
# once a day when automatic update checks are allowed, and every install or update reads it once more
# together with the app download. People who turned the checks off are not counted.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="${ONWIN_REPO:-totKtoXam/onwin}"
days="${1:-14}"

if [ -n "${STATS_HISTORY_FILE:-}" ]; then history="$(cat "$STATS_HISTORY_FILE")"; else
history="$(gh api "repos/$repo/contents/downloads.csv?ref=stats" -H "Accept: application/vnd.github.raw" 2>/dev/null || true)"; fi
now="$("$here/stats-collect.sh" "$repo")"

IFS=, read -r _ dmg offline zip engine manifest <<<"$now"
echo "onwin — скачивания за всё время (данные GitHub, $repo)"
printf '  DMG                %6d\n' "$dmg"
printf '  DMG офлайн         %6d\n' "$offline"
printf '  Терминал/обновления%6d   (приложение без движка)\n' "$zip"
printf '  Движок Wine        %6d\n' "$engine"
printf '  Итого onwin        %6d   (DMG + DMG офлайн + Терминал/обновления)\n' "$((dmg + offline + zip))"

if [ -z "$history" ] || [ "$(printf '%s\n' "$history" | wc -l)" -lt 2 ]; then
    echo
    echo "Истории по дням пока нет: её пишет ежедневная задача GitHub Actions (ветка stats)."
    exit 0
fi

echo
echo "По дням (последние $days):"
{ printf '%s\n' "$history" | tail -n +2; [ "${now%%,*}" != "$(printf '%s\n' "$history" | tail -1 | cut -d, -f1)" ] && echo "$now" || true; } |
awk -F, -v days="$days" '
    { d[NR] = $1; dm[NR] = $2 + $3; z[NR] = $4; m[NR] = $6; n = NR }
    END {
        print "  день            скачано   обновлений*   польз./день"   # literal: awk pads bytes, not letters
        start = n - days + 1; if (start < 2) start = 2
        for (i = start; i <= n; i++) {
            down = (dm[i] - dm[i-1]) + (z[i] - z[i-1])
            users = (m[i] - m[i-1]) - (z[i] - z[i-1]); if (users < 0) users = 0
            printf "  %-10s  %9d  %12d  %12d\n", d[i], down, z[i] - z[i-1], users
            total += users; cnt++
        }
        if (cnt) printf "\n  В среднем пользователей в день: %d (оценка, только у кого включена автопроверка)\n", total / cnt
        print "  * установки и обновления из Терминала и из самого onwin"
    }'
