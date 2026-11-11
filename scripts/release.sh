#!/bin/bash
# Builds and publishes onwin releases on GitHub (needs gh, logged in: gh auth login).
#
#   scripts/release.sh engine [--no-upload]   engine release "engine-<id>-<built>" (only when the engine changed)
#   scripts/release.sh app    [--no-upload]   app release "v<version>", marked latest
#   scripts/release.sh all    [--no-upload]   both, engine first
#
# Engine release (not "latest"; one per engine build):
#   onwin-engine-<id>.tar.xz                 the engine folder <id>/ (bin, lib, share, onwin-engine.json, share/licenses)
#   onwin-engine-manifest.json               id, built, asset name, sha256, size
#   crossover-sources-<ver>.tar.gz           CodeWeavers' open CrossOver sources (Wine, DXVK fork, vkd3d…)
#   onwin-engine-<id>-sources-upstream.tar   official source archives of the libraries (engine/sources/upstream)
#   wine-mono-<ver>-src.tar.xz, wine-gecko-<ver>-src.tar.xz   sources of the bundled Wine Mono / Gecko
# The engine's own patches and build scripts are in this repository (engine/).
#
# App release (latest):
#   Onwin-<version>.dmg        Onwin.app with the engine inside (drag to Applications)
#   Onwin-<version>-app.zip    Onwin.app without the engine (used by install.sh)
#   onwin-release.json         what install.sh and the app's updater (Updater.swift) read: version, build,
#                              app/dmg/engine URLs, sha256, sizes
#   install.sh                 the installer with this repository filled in
#
# The app version is OnwinVersion.string (app/Sources/OnwinCore/WineRunner.swift); bump it before `app`.
# --no-upload builds everything into dist/ and prints what would be published.
# Works with macOS /bin/bash 3.2.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST="$ROOT/dist"
ENGINE_DIST="$ROOT/engine/dist"
SOURCES="$ROOT/engine/sources"

die() { echo "release: ошибка: $*" >&2; exit 1; }
note() { echo "==> $*"; }

MODE="${1:-}"
UPLOAD=1
[ "${2:-}" = "--no-upload" ] && UPLOAD=0
case "$MODE" in engine|app|all) ;; *) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;; esac

command -v gh >/dev/null 2>&1 || die "нужен gh (brew install gh) и вход: gh auth login"
if [ "$UPLOAD" = 1 ]; then
    gh auth status >/dev/null 2>&1 || die "gh не авторизован: gh auth login"
fi
REPO="${ONWIN_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)}"
[ -n "$REPO" ] || die "не удалось определить репозиторий GitHub (git remote origin или ONWIN_REPO=владелец/onwin)"
OWNER="${REPO%%/*}"; NAME="${REPO#*/}"
SITE_URL="https://$(echo "$OWNER" | tr '[:upper:]' '[:lower:]').github.io/$NAME"
DL="https://github.com/$REPO/releases/download"
SUPPORT_CHAT="https://t.me/+KGkGUTbpk0ZjNDEy"   # Telegram group «onwin — помощь» (same as site/config.js)

json_get() { /usr/bin/plutil -extract "$2" raw -o - "$1"; }   # json_get <file> <key path>
sha256() { /usr/bin/shasum -a 256 "$1" | cut -d' ' -f1; }
fsize() { stat -f %z "$1"; }

release_exists() { gh release view "$1" --repo "$REPO" >/dev/null 2>&1; }

ensure_pushed() {
    [ "$UPLOAD" = 1 ] || return 0
    git -C "$ROOT" fetch -q origin main || die "не удалось получить origin/main"
    git -C "$ROOT" merge-base --is-ancestor HEAD origin/main \
        || die "текущий коммит не опубликован в origin/main — сначала git push"
    [ -z "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ] || die "есть незакоммиченные изменения"
}

# --------------------------------------------------------------------------------------- engine
ENGINE_DIR=""
engine_info() {
    local dirs
    dirs=$(ls -d "$ENGINE_DIST"/*/ 2>/dev/null | sed 's:/$::')
    [ -n "$dirs" ] || die "нет собранного движка в $ENGINE_DIST (engine/build.sh)"
    [ "$(echo "$dirs" | wc -l | tr -d ' ')" = 1 ] || die "в $ENGINE_DIST несколько движков — оставьте один"
    ENGINE_DIR="$dirs"
    ENGINE_ID="$(json_get "$ENGINE_DIR/onwin-engine.json" id)"
    ENGINE_BUILT="$(json_get "$ENGINE_DIR/onwin-engine.json" built)"
    # 2026-11-10T22:21:20Z → 202611102221
    ENGINE_STAMP="$(echo "$ENGINE_BUILT" | tr -d -- '-:TZ' | cut -c1-12)"
    ENGINE_TAG="engine-$ENGINE_ID-$ENGINE_STAMP"
    ENGINE_ASSET="onwin-engine-$ENGINE_ID.tar.xz"
}

fetch_source() {  # fetch_source <url> <file>: official source archive, downloaded once into engine/sources/release
    local dir="$SOURCES/release"
    mkdir -p "$dir"
    if [ ! -s "$dir/$2" ]; then
        note "скачиваю исходники $2" >&2   # stdout of this function is the path
        /usr/bin/curl -fL --retry 3 -o "$dir/$2.part" "$1" || die "не удалось скачать $1"
        mv "$dir/$2.part" "$dir/$2"
    fi
    echo "$dir/$2"
}

release_engine() {
    engine_info
    if [ "$UPLOAD" = 1 ] && release_exists "$ENGINE_TAG"; then
        note "релиз движка $ENGINE_TAG уже опубликован — пропускаю"
        return 0
    fi
    ensure_pushed
    local out="$DIST/engine"
    mkdir -p "$out"

    note "лицензии → $ENGINE_ID/share/licenses"
    mkdir -p "$ENGINE_DIR/share/licenses"
    cp "$ROOT"/third_party/licenses/*.txt "$ENGINE_DIR/share/licenses/"

    # The archive is reused while it was made from this very engine build with the same licenses.
    local stamp
    stamp="$ENGINE_BUILT $(cat "$ROOT"/third_party/licenses/*.txt | /usr/bin/shasum -a 256 | cut -d' ' -f1)"
    if [ -s "$out/$ENGINE_ASSET" ] && [ "$(cat "$out/.stamp" 2>/dev/null)" = "$stamp" ]; then
        note "движок уже упакован: $out/$ENGINE_ASSET"
    else
        note "упаковываю движок (xz, несколько минут)"
        rm -f "$out/.stamp"
        COPYFILE_DISABLE=1 tar -C "$ENGINE_DIST" -cf - "$ENGINE_ID" | xz -T0 -9 > "$out/$ENGINE_ASSET.part"
        mv "$out/$ENGINE_ASSET.part" "$out/$ENGINE_ASSET"
        echo "$stamp" > "$out/.stamp"
    fi
    cat > "$out/onwin-engine-manifest.json" <<JSON
{
  "id": "$ENGINE_ID",
  "built": "$ENGINE_BUILT",
  "tag": "$ENGINE_TAG",
  "asset": "$ENGINE_ASSET",
  "sha256": "$(sha256 "$out/$ENGINE_ASSET")",
  "size": $(fsize "$out/$ENGINE_ASSET")
}
JSON

    note "собираю исходники для LGPL/GPL/MPL"
    local cx mono gecko assets
    cx=$(ls "$SOURCES"/crossover-sources-*.tar.gz 2>/dev/null | head -n 1)
    [ -n "$cx" ] || die "нет engine/sources/crossover-sources-*.tar.gz"
    COPYFILE_DISABLE=1 tar -C "$SOURCES" -cf "$out/onwin-engine-$ENGINE_ID-sources-upstream.tar" upstream
    mono=$(ls "$ENGINE_DIR/share/wine/mono" | grep -E '^wine-mono-[0-9.]+$' | head -n 1 | sed 's/^wine-mono-//')
    gecko=$(ls "$ENGINE_DIR/share/wine/gecko" | sed -nE 's/^wine-gecko-([0-9.]+)-.*/\1/p' | head -n 1)
    [ -n "$mono" ] && [ -n "$gecko" ] || die "не удалось определить версии Wine Mono / Gecko в движке"
    assets=("$out/$ENGINE_ASSET" "$out/onwin-engine-manifest.json" "$cx"
            "$out/onwin-engine-$ENGINE_ID-sources-upstream.tar"
            "$(fetch_source "https://dl.winehq.org/wine/wine-mono/$mono/wine-mono-$mono-src.tar.xz" "wine-mono-$mono-src.tar.xz")"
            "$(fetch_source "https://dl.winehq.org/wine/wine-gecko/$gecko/wine-gecko-$gecko-src.tar.xz" "wine-gecko-$gecko-src.tar.xz")")

    local notes="$out/notes.md"
    cat > "$notes" <<MD
Движок onwin **$ENGINE_ID**, собран $ENGINE_BUILT.

Ставится автоматически установщиком onwin ($SITE_URL/install.html) — вручную скачивать не нужно.

Состав и лицензии — [THIRD_PARTY_NOTICES.md](https://github.com/$REPO/blob/main/THIRD_PARTY_NOTICES.md).
Здесь же лежат исходники всех компонентов под LGPL/GPL/MPL, из которых собран этот движок; наши патчи и скрипты
сборки — в папке [engine](https://github.com/$REPO/tree/main/engine) репозитория.
MD
    if [ "$UPLOAD" = 0 ]; then
        note "без загрузки. Релиз $ENGINE_TAG:"; ls -lh "${assets[@]}"; return 0
    fi
    note "публикую $ENGINE_TAG (файлы большие — загрузка займёт время)"
    gh release create "$ENGINE_TAG" --repo "$REPO" --target "$(git -C "$ROOT" rev-parse HEAD)" \
        --title "Движок $ENGINE_ID ($(echo "$ENGINE_BUILT" | cut -c1-10))" --notes-file "$notes" --latest=false \
        "${assets[@]}"
}

# ------------------------------------------------------------------------------------------ app
release_app() {
    engine_info
    local version build tag out manifest
    version="$(sed -nE 's/.*static let string = "([^"]+)".*/\1/p' "$ROOT/app/Sources/OnwinCore/WineRunner.swift" | head -n 1)"
    [ -n "$version" ] || die "не найдена версия (OnwinVersion.string)"
    tag="v$version"
    # Versions below 1.0 are beta: marked in the title only. Not a GitHub "pre-release" — that would hide it
    # from releases/latest, which install.sh reads.
    local beta_suffix=""
    case "$version" in 0.*) beta_suffix=" (бета)" ;; esac
    if [ "$UPLOAD" = 1 ] && release_exists "$tag"; then
        die "релиз $tag уже есть — увеличьте OnwinVersion.string в app/Sources/OnwinCore/WineRunner.swift"
    fi
    ensure_pushed
    out="$DIST/app"
    rm -rf "$out"; mkdir -p "$out"

    # The engine release this app goes with: the one built from the local engine (the DMG embeds it).
    manifest="$out/onwin-engine-manifest.json"
    if [ "$UPLOAD" = 1 ]; then
        release_exists "$ENGINE_TAG" || die "нет релиза движка $ENGINE_TAG — сначала: scripts/release.sh engine"
        gh release download "$ENGINE_TAG" --repo "$REPO" --pattern onwin-engine-manifest.json --dir "$out" --clobber
    else
        [ -f "$DIST/engine/onwin-engine-manifest.json" ] || die "сначала: scripts/release.sh engine --no-upload"
        cp "$DIST/engine/onwin-engine-manifest.json" "$manifest"
    fi
    [ "$(json_get "$manifest" built)" = "$ENGINE_BUILT" ] || die "локальный движок не совпадает с опубликованным $ENGINE_TAG"

    build="$(date -u +%Y%m%d%H%M)"
    export ONWIN_NO_INSTALL=1 ONWIN_BUILD_NUMBER="$build"
    local built_app="$ROOT/build/app.noindex/Onwin.app"

    note "Onwin.app без движка"
    "$SCRIPT_DIR/build-app.sh"
    /usr/bin/ditto -c -k --keepParent "$built_app" "$out/Onwin-$version-app.zip"

    note "Onwin.app с движком → DMG"
    "$SCRIPT_DIR/build-app.sh" --with-engine "$ENGINE_DIR"
    local stage="$out/dmg"
    mkdir -p "$stage"
    /usr/bin/ditto "$built_app" "$stage/Onwin.app"
    ln -s /Applications "$stage/Программы"
    hdiutil create -quiet -volname "onwin $version" -srcfolder "$stage" -fs APFS -format ULMO \
        "$out/Onwin-$version.dmg"
    rm -rf "$stage"

    sed "s|__ONWIN_REPO__|$REPO|" "$ROOT/site/install.sh" > "$out/install.sh"
    bash -n "$out/install.sh"

    local app_zip="$out/Onwin-$version-app.zip" dmg="$out/Onwin-$version.dmg"
    cat > "$out/onwin-release.json" <<JSON
{
  "schema": 1,
  "version": "$version",
  "build": "$build",
  "minimumMacOS": "14.0",
  "site": "$SITE_URL/",
  "app": { "url": "$DL/$tag/Onwin-$version-app.zip", "sha256": "$(sha256 "$app_zip")", "size": $(fsize "$app_zip") },
  "dmg": { "url": "$DL/$tag/Onwin-$version.dmg", "sha256": "$(sha256 "$dmg")", "size": $(fsize "$dmg") },
  "engine": {
    "id": "$ENGINE_ID",
    "built": "$ENGINE_BUILT",
    "url": "$DL/$ENGINE_TAG/$(json_get "$manifest" asset)",
    "sha256": "$(json_get "$manifest" sha256)",
    "size": $(json_get "$manifest" size)
  }
}
JSON
    # The same parser install.sh uses (plutil -lint does not read JSON).
    [ "$(json_get "$out/onwin-release.json" engine.id)" = "$ENGINE_ID" ] || die "onwin-release.json невалиден"

    local notes="$out/notes.md"
    cat > "$notes" <<MD
$( [ -n "$beta_suffix" ] && printf '%s\n\n' "> **Бета-версия.** onwin ещё в разработке: что-то может работать нестабильно. Если что-то не так — напишите в группу поддержки: $SUPPORT_CHAT" )
## Установка

Откройте Терминал и выполните:

\`\`\`bash
curl -fsSL $SITE_URL/install.sh | bash
\`\`\`

Эта же команда обновляет onwin: она скачивает только изменившиеся части. Другие способы — на странице
[Установка]($SITE_URL/install.html).

**Onwin-$version.dmg** — приложение вместе с движком: перетащите в «Программы». Приложение не нотаризовано Apple,
поэтому при первом запуске откройте «Системные настройки → Конфиденциальность и безопасность → Всё равно открыть».

Нужен Mac с Apple Silicon и macOS 14 или новее. Движок: $ENGINE_ID ([$ENGINE_TAG](https://github.com/$REPO/releases/tag/$ENGINE_TAG)).
MD
    local assets=("$dmg" "$app_zip" "$out/onwin-release.json" "$out/install.sh")
    if [ "$UPLOAD" = 0 ]; then
        note "без загрузки. Релиз $tag:"; ls -lh "${assets[@]}"; return 0
    fi
    note "публикую $tag"
    gh release create "$tag" --repo "$REPO" --target "$(git -C "$ROOT" rev-parse HEAD)" \
        --title "onwin $version$beta_suffix" --notes-file "$notes" --latest "${assets[@]}"
}

case "$MODE" in
    engine) release_engine ;;
    app) release_app ;;
    all) release_engine; release_app ;;
esac
note "готово"
