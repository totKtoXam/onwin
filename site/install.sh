#!/bin/bash
# onwin installer: installs or updates onwin with one command.
#
#   curl -fsSL https://<owner>.github.io/onwin/install.sh | bash                          install / update
#   curl -fsSL https://<owner>.github.io/onwin/install.sh | bash -s -- --uninstall        remove onwin, keep spaces
#   curl -fsSL https://<owner>.github.io/onwin/install.sh | bash -s -- --uninstall --purge   remove everything
#
# What it does (see AGENTS.md, "Релизы и установщик"):
#   1. reads onwin-release.json of the latest GitHub release (versions, URLs, SHA-256 of every part);
#   2. installs the Wine engine into ~/Library/Application Support/onwin/Engines/<id> — only when the
#      installed engine is missing or older;
#   3. installs Onwin.app (without a bundled engine) into /Applications, or ~/Applications when
#      /Applications is not writable — only when the installed build differs.
# Files downloaded with curl get no quarantine attribute, so Gatekeeper does not block the app,
# which is not notarized. Every download is checked against its SHA-256. Never uses sudo except for
# installing Rosetta 2, and only after asking.

set -euo pipefail

REPO="${ONWIN_REPO:-__ONWIN_REPO__}"   # owner/name; filled in when the site or a release is published
MANIFEST_NAME="onwin-release.json"
# For testing: ONWIN_MANIFEST_URL=<url of an onwin-release.json>, ONWIN_APP_DIR=<folder for Onwin.app>.
MANIFEST_URL="${ONWIN_MANIFEST_URL:-https://github.com/$REPO/releases/latest/download/$MANIFEST_NAME}"
SUPPORT="$HOME/Library/Application Support/onwin"
ENGINES="$SUPPORT/Engines"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
say() { printf '==> %s\n' "$*"; }
warn() { printf 'onwin: %s\n' "$*" >&2; }
die() { printf 'onwin: ошибка: %s\n' "$*" >&2; exit 1; }

# Questions go to the terminal even though the script itself arrives through a pipe.
ask_yes() {
    local answer=""
    [ -r /dev/tty ] || return 1
    printf '%s [Y/n] ' "$1" > /dev/tty
    read -r answer < /dev/tty || return 1
    case "$answer" in ""|y|Y|yes|д|Д|да|Да) return 0 ;; *) return 1 ;; esac
}

UNINSTALL=0
PURGE=0
for arg in "$@"; do
    case "$arg" in
        --uninstall) UNINSTALL=1 ;;
        --purge) PURGE=1 ;;
        -h|--help) sed -n '2,8p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "неизвестный параметр: $arg" ;;
    esac
done

[ "$(uname -s)" = "Darwin" ] || die "onwin работает только на macOS"

app_candidates() {
    if [ -n "${ONWIN_APP_DIR:-}" ]; then printf '%s\n' "$ONWIN_APP_DIR/Onwin.app"; return; fi
    printf '%s\n' "/Applications/Onwin.app" "$HOME/Applications/Onwin.app"
}

app_running() { /usr/bin/pgrep -x Onwin >/dev/null 2>&1; }

# ---------------------------------------------------------------------------------- uninstall
if [ "$UNINSTALL" = 1 ]; then
    if app_running; then die "сначала закройте onwin"; fi
    if /usr/bin/pgrep -f "onwin/Engines/.*/wineserver" >/dev/null 2>&1; then
        die "в onwin ещё работают Windows-программы — закройте их"
    fi
    while IFS= read -r app; do
        if [ -d "$app" ]; then say "удаляю $app"; rm -rf "$app"; fi
    done < <(app_candidates)
    if [ -d "$ENGINES" ]; then say "удаляю движки Wine"; rm -rf "$ENGINES"; fi
    if [ -d "$HOME/Applications/onwin" ]; then say "удаляю ярлыки программ"; rm -rf "$HOME/Applications/onwin"; fi
    for link in /usr/local/bin/onwinctl "$HOME/.local/bin/onwinctl"; do
        if [ -L "$link" ]; then rm -f "$link"; fi
    done
    if [ "$PURGE" = 1 ]; then
        if ask_yes "Удалить ВСЕ пространства onwin со всеми установленными программами и сохранениями? Это необратимо."; then
            rm -rf "$SUPPORT" "$HOME/Library/Caches/onwin" "$HOME/Library/Logs/onwin"
            say "все данные onwin удалены"
        else
            say "пространства оставлены: $SUPPORT"
        fi
    else
        say "пространства с программами оставлены: $SUPPORT/Spaces"
    fi
    bold "onwin удалён."
    exit 0
fi

# ------------------------------------------------------------------------------- requirements
[ "$(uname -m)" = "arm64" ] || die "нужен Mac с процессором Apple (M1 и новее)"
macos_major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$macos_major" -ge 14 ] 2>/dev/null || die "нужна macOS 14 Sonoma или новее (у вас $(sw_vers -productVersion))"
case "$REPO" in
    */*) ;;
    *) die "не задан репозиторий onwin (ONWIN_REPO=владелец/onwin)" ;;
esac

if ! /usr/bin/arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
    warn "Rosetta 2 не установлена — без неё Windows-программы не запустятся."
    if ask_yes "Установить Rosetta 2 сейчас? (macOS спросит пароль администратора и покажет лицензию Apple)"; then
        sudo /usr/sbin/softwareupdate --install-rosetta < /dev/tty || warn "Rosetta 2 не установилась — установите её позже из onwin"
    else
        warn "пропускаю: onwin предложит установить Rosetta 2 при запуске"
    fi
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/onwin-install.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

download() {  # download <url> <file>
    /usr/bin/curl -fL --retry 3 --progress-bar -o "$2" "$1" || die "не удалось скачать $1"
}
json() {  # json <key path> — value from the release manifest
    /usr/bin/plutil -extract "$1" raw -o - "$WORK/$MANIFEST_NAME" 2>/dev/null
}
check_sha() {  # check_sha <file> <sha256>
    local actual
    actual="$(/usr/bin/shasum -a 256 "$1" | cut -d' ' -f1)"
    [ "$actual" = "$2" ] || die "контрольная сумма $(basename "$1") не совпала — файл повреждён, попробуйте ещё раз"
}

say "читаю последний выпуск onwin ($REPO)"
/usr/bin/curl -fsSL --retry 3 -o "$WORK/$MANIFEST_NAME" "$MANIFEST_URL" \
    || die "не удалось получить описание выпуска — проверьте подключение к интернету"
VERSION="$(json version)" || die "описание выпуска повреждено"
BUILD="$(json build)"
bold "onwin $VERSION"

# ------------------------------------------------------------------------------------- engine
ENGINE_ID="$(json engine.id)"
ENGINE_BUILT="$(json engine.built)"
ENGINE_DIR="$ENGINES/$ENGINE_ID"
installed_built=""
if [ -f "$ENGINE_DIR/onwin-engine.json" ]; then
    installed_built="$(/usr/bin/plutil -extract built raw -o - "$ENGINE_DIR/onwin-engine.json" 2>/dev/null || true)"
fi
if [ -x "$ENGINE_DIR/bin/wine" ] && [ "$installed_built" = "$ENGINE_BUILT" ]; then
    say "движок Wine $ENGINE_ID уже последний"
else
    if /usr/bin/pgrep -f "Engines/$ENGINE_ID/bin/wineserver" >/dev/null 2>&1; then
        die "движок нужно обновить, но в onwin работают Windows-программы — закройте их и запустите установку снова"
    fi
    size_mb=$(( $(json engine.size) / 1048576 ))
    say "скачиваю движок Wine $ENGINE_ID (~${size_mb} МБ)"
    download "$(json engine.url)" "$WORK/engine.tar.xz"
    check_sha "$WORK/engine.tar.xz" "$(json engine.sha256)"
    say "распаковываю движок"
    mkdir -p "$ENGINES"
    staging="$ENGINES/.install-$ENGINE_ID"
    rm -rf "$staging"; mkdir -p "$staging"
    /usr/bin/tar -xf "$WORK/engine.tar.xz" -C "$staging"
    [ -x "$staging/$ENGINE_ID/bin/wine" ] || { rm -rf "$staging"; die "в архиве движка нет bin/wine"; }
    rm -rf "$ENGINE_DIR.old"
    if [ -d "$ENGINE_DIR" ]; then mv "$ENGINE_DIR" "$ENGINE_DIR.old"; fi
    mv "$staging/$ENGINE_ID" "$ENGINE_DIR"
    rm -rf "$staging" "$ENGINE_DIR.old"
    /usr/bin/xattr -dr com.apple.quarantine "$ENGINE_DIR" 2>/dev/null || true
    say "движок установлен: $ENGINE_DIR"
fi

# ---------------------------------------------------------------------------------------- app
TARGET=""
while IFS= read -r app; do
    if [ -d "$app" ]; then TARGET="$app"; break; fi
done < <(app_candidates)
if [ -z "$TARGET" ]; then
    if [ -n "${ONWIN_APP_DIR:-}" ]; then TARGET="$ONWIN_APP_DIR/Onwin.app"
    elif [ -w /Applications ]; then TARGET="/Applications/Onwin.app"; else TARGET="$HOME/Applications/Onwin.app"; fi
fi
installed_build=""
if [ -f "$TARGET/Contents/Info.plist" ]; then
    installed_build="$(/usr/bin/defaults read "$TARGET/Contents/Info.plist" CFBundleVersion 2>/dev/null || true)"
fi
FRESH=0
[ -d "$TARGET" ] || FRESH=1
if [ "$installed_build" = "$BUILD" ]; then
    say "приложение onwin $VERSION уже установлено: $TARGET"
else
    if app_running; then
        if ask_yes "onwin сейчас открыт. Закрыть его для обновления?"; then
            /usr/bin/osascript -e 'tell application id "app.onwin.Onwin" to quit' >/dev/null 2>&1 || true
            for _ in 1 2 3 4 5 6 7 8 9 10; do app_running || break; sleep 1; done
        fi
        app_running && die "закройте onwin и запустите установку снова"
    fi
    size_mb=$(( $(json app.size) / 1048576 + 1 ))
    say "скачиваю onwin $VERSION (~${size_mb} МБ)"
    download "$(json app.url)" "$WORK/app.zip"
    check_sha "$WORK/app.zip" "$(json app.sha256)"
    mkdir -p "$WORK/app"
    /usr/bin/ditto -x -k "$WORK/app.zip" "$WORK/app"
    [ -d "$WORK/app/Onwin.app" ] || die "в архиве нет Onwin.app"
    mkdir -p "$(dirname "$TARGET")"
    rm -rf "$TARGET.new"
    /usr/bin/ditto "$WORK/app/Onwin.app" "$TARGET.new"
    rm -rf "$TARGET"
    mv "$TARGET.new" "$TARGET"
    /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -f "$TARGET" >/dev/null 2>&1 || true
    say "приложение установлено: $TARGET"
fi

bold "Готово! onwin $VERSION установлен."
echo "Обновить позже — запустите эту же команду ещё раз."
if [ "$FRESH" = 1 ]; then
    /usr/bin/open "$TARGET" || true
fi
