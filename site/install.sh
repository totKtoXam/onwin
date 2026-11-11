#!/bin/bash
# onwin installer: installs or updates onwin with one command.
#
#   curl -fsSL https://<owner>.github.io/onwin/install.sh | bash                          install / update
#   curl -fsSL https://<owner>.github.io/onwin/install.sh | bash -s -- --uninstall        remove onwin, keep spaces
#   curl -fsSL https://<owner>.github.io/onwin/install.sh | bash -s -- --uninstall --purge   remove everything
#   curl -fsSL https://<owner>.github.io/onwin/install.sh | bash -s -- --version 0.1.0     install that version
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
#
# Output: short lines that fit a narrow terminal, one progress line updated in place (no curl bar,
# which wraps into rows of "#" in narrow windows); colours only on a terminal and without NO_COLOR.
# For testing: ONWIN_MANIFEST_URL=<url of an onwin-release.json>, ONWIN_APP_DIR=<folder for Onwin.app>.

set -euo pipefail

REPO="${ONWIN_REPO:-__ONWIN_REPO__}"   # owner/name; filled in when the site or a release is published
MANIFEST_NAME="onwin-release.json"
SUPPORT="$HOME/Library/Application Support/onwin"
ENGINES="$SUPPORT/Engines"

# ---------------------------------------------------------------------------------------- output
TTY=0; [ -t 1 ] && TTY=1
if [ "$TTY" = 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_OK=$'\033[36m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
    C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_B=""; C_0=""
fi
clear_line() { if [ "$TTY" = 1 ]; then printf '\r\033[K'; fi; }
title() { printf '\n  %s%s%s\n\n' "$C_B" "$*" "$C_0"; }
ok()    { printf '  %s✓%s %s\n' "$C_OK" "$C_0" "$*"; }
step()  { printf '  %s•%s %s\n' "$C_DIM" "$C_0" "$*"; }
note()  { printf '    %s%s%s\n' "$C_DIM" "$*" "$C_0"; }
warn()  { printf '  %s!%s %s\n' "$C_WARN" "$C_0" "$*" >&2; }
die()   { clear_line; printf '\n  %s✗ %s%s\n\n' "$C_ERR" "$*" "$C_0" >&2; exit 1; }

# Questions go to the terminal even though the script itself arrives through a pipe.
ask_yes() {
    local answer=""
    { : < /dev/tty; } 2>/dev/null || return 1   # no terminal to ask (e.g. a script): treat as «no»
    printf '  %s?%s %s %s[Y/n]%s ' "$C_WARN" "$C_0" "$1" "$C_DIM" "$C_0" > /dev/tty
    read -r answer < /dev/tty || return 1
    case "$answer" in ""|y|Y|yes|д|Д|да|Да) return 0 ;; *) return 1 ;; esac
}

UNINSTALL=0
PURGE=0
WANT_VERSION=""
while [ $# -gt 0 ]; do
    arg="$1"; shift
    case "$arg" in
        --uninstall) UNINSTALL=1 ;;
        --purge) PURGE=1 ;;
        --version)
            [ $# -gt 0 ] || die "После --version укажите версию, например 0.1.0"
            WANT_VERSION="${1#v}"; shift ;;
        --version=*) WANT_VERSION="${arg#--version=}"; WANT_VERSION="${WANT_VERSION#v}" ;;
        -h|--help) sed -n '2,8p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Неизвестный параметр: $arg" ;;
    esac
done

[ "$(uname -s)" = "Darwin" ] || die "onwin работает только на macOS."

app_candidates() {
    if [ -n "${ONWIN_APP_DIR:-}" ]; then printf '%s\n' "$ONWIN_APP_DIR/Onwin.app"; return; fi
    printf '%s\n' "/Applications/Onwin.app" "$HOME/Applications/Onwin.app"
}

app_running() { /usr/bin/pgrep -x Onwin >/dev/null 2>&1; }
# The copy at <path>/Onwin.app is running (only that one has to be closed before it is replaced).
app_running_at() { /usr/bin/pgrep -f "^$1/Contents/MacOS/Onwin( |\$)" >/dev/null 2>&1; }

# ------------------------------------------------------------------------------------- uninstall
if [ "$UNINSTALL" = 1 ]; then
    title "Удаление onwin"
    if app_running; then die "Сначала закройте onwin."; fi
    if /usr/bin/pgrep -f "onwin/Engines/.*/wineserver" >/dev/null 2>&1; then
        die "В onwin ещё работают Windows-программы — закройте их."
    fi
    while IFS= read -r app; do
        if [ -d "$app" ]; then rm -rf "$app"; ok "Приложение удалено"; fi
    done < <(app_candidates)
    if [ -d "$ENGINES" ]; then rm -rf "$ENGINES"; ok "Движок Wine удалён"; fi
    if [ -d "$HOME/Applications/onwin" ]; then rm -rf "$HOME/Applications/onwin"; ok "Ярлыки программ удалены"; fi
    for link in /usr/local/bin/onwinctl "$HOME/.local/bin/onwinctl"; do
        if [ -L "$link" ]; then rm -f "$link"; fi
    done
    if [ "$PURGE" = 1 ]; then
        if ask_yes "Удалить ВСЕ пространства с программами и сохранениями? Это необратимо."; then
            rm -rf "$SUPPORT" "$HOME/Library/Caches/onwin" "$HOME/Library/Logs/onwin"
            ok "Пространства и все данные удалены"
        else
            ok "Пространства оставлены"
        fi
    else
        ok "Пространства с программами и сохранениями оставлены"
        note "Удалить и их: добавьте к команде --purge"
    fi
    printf '\n  %sonwin удалён.%s\n\n' "$C_B" "$C_0"
    exit 0
fi

# ---------------------------------------------------------------------------------- requirements
[ "$(uname -m)" = "arm64" ] || die "Нужен Mac с процессором Apple (M1 и новее)."
macos_major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$macos_major" -ge 14 ] 2>/dev/null || die "Нужна macOS 14 Sonoma или новее (у вас $(sw_vers -productVersion))."
case "$REPO" in
    */*) ;;
    *) die "Не задан репозиторий onwin (ONWIN_REPO=владелец/onwin)." ;;
esac

WORK="$(mktemp -d "${TMPDIR:-/tmp}/onwin-install.XXXXXX")"
DL_PID=""
cleanup() {
    if [ -n "$DL_PID" ]; then kill "$DL_PID" 2>/dev/null || true; fi
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'clear_line; printf "\n  Установка прервана.\n\n" >&2; exit 130' INT TERM

json() {  # json <key path> — value from the release manifest
    /usr/bin/plutil -extract "$1" raw -o - "$WORK/$MANIFEST_NAME" 2>/dev/null
}
mb() { echo $(( ($1 + 524288) / 1048576 )); }
# Megabytes with one decimal for small downloads («3,4»), whole numbers for big ones.
mbx() {
    if [ "$2" -lt 52428800 ]; then local t=$(( $1 * 10 / 1048576 )); echo "$(( t / 10 )),$(( t % 10 ))"; else mb "$1"; fi
}
check_sha() {  # check_sha <file> <sha256>
    local actual
    actual="$(/usr/bin/shasum -a 256 "$1" | cut -d' ' -f1)"
    [ "$actual" = "$2" ] || die "Файл скачался с ошибкой. Запустите команду ещё раз."
}

# download <url> <file> <label> <size in bytes>: a single progress line updated in place.
download() {
    local url="$1" file="$2" label="$3" size="${4:-0}" have pct cols line
    if [ "$TTY" != 1 ]; then
        step "Скачиваю: $label ($(mbx "$size" "$size") МБ)"
        /usr/bin/curl -fsSL --retry 3 -o "$file" "$url" || die "Не удалось скачать: $label. Проверьте интернет."
        return
    fi
    /usr/bin/curl -fsSL --retry 3 -o "$file" "$url" &
    DL_PID=$!
    cols=$(/usr/bin/tput cols 2>/dev/null || echo 80)
    while kill -0 "$DL_PID" 2>/dev/null; do
        have=$(/usr/bin/stat -f %z "$file" 2>/dev/null || echo 0)
        pct=0
        if [ "$size" -gt 0 ]; then pct=$(( have * 100 / size )); fi
        if [ "$pct" -gt 100 ]; then pct=100; fi
        if [ "$cols" -ge 46 ]; then
            line="↓ $label · $(mbx "$have" "$size") из $(mbx "$size" "$size") МБ · $pct%"
        else
            line="↓ $pct% · $(mbx "$have" "$size")/$(mbx "$size" "$size") МБ"
        fi
        printf '\r\033[K  %s%s%s' "$C_OK" "$line" "$C_0"
        sleep 0.4
    done
    clear_line
    if ! wait "$DL_PID"; then
        DL_PID=""
        die "Не удалось скачать: $label. Проверьте интернет и запустите команду ещё раз."
    fi
    DL_PID=""
}

# ---------------------------------------------------------------------------------------- release
if [ -n "${ONWIN_MANIFEST_URL:-}" ]; then
    MANIFEST_URL="$ONWIN_MANIFEST_URL"
elif [ -n "$WANT_VERSION" ]; then
    case "$WANT_VERSION" in *[!0-9.]*|"") die "Неверная версия: $WANT_VERSION (пример: 0.1.0)" ;; esac
    MANIFEST_URL="https://github.com/$REPO/releases/download/v$WANT_VERSION/$MANIFEST_NAME"
else
    MANIFEST_URL="https://github.com/$REPO/releases/latest/download/$MANIFEST_NAME"
fi
/usr/bin/curl -fsSL --retry 3 -o "$WORK/$MANIFEST_NAME" "$MANIFEST_URL" \
    || die "Не удалось связаться с GitHub. Проверьте интернет${WANT_VERSION:+ и номер версии $WANT_VERSION}."
VERSION="$(json version)" || die "Описание выпуска повреждено. Попробуйте позже."
BUILD="$(json build)"
case "$VERSION" in 0.*) LABEL="onwin $VERSION (бета)" ;; *) LABEL="onwin $VERSION" ;; esac

title "Установка $LABEL"
ok "Mac подходит: $(/usr/sbin/sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'Apple Silicon'), macOS $(sw_vers -productVersion)"

if /usr/bin/arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
    ok "Rosetta 2 на месте"
else
    warn "Нет Rosetta 2 — без неё Windows-программы не запустятся"
    if ask_yes "Установить Rosetta 2? (macOS спросит пароль и покажет лицензию Apple)"; then
        if sudo /usr/sbin/softwareupdate --install-rosetta < /dev/tty; then ok "Rosetta 2 установлена"
        else warn "Rosetta 2 не установилась — onwin предложит её при запуске"; fi
    else
        note "onwin предложит установить Rosetta 2 при запуске"
    fi
fi

# ----------------------------------------------------------------------------------------- engine
ENGINE_ID="$(json engine.id)"
ENGINE_BUILT="$(json engine.built)"
ENGINE_DIR="$ENGINES/$ENGINE_ID"
installed_built=""
if [ -f "$ENGINE_DIR/onwin-engine.json" ]; then
    installed_built="$(/usr/bin/plutil -extract built raw -o - "$ENGINE_DIR/onwin-engine.json" 2>/dev/null || true)"
fi
if [ -x "$ENGINE_DIR/bin/wine" ] && [ "$installed_built" = "$ENGINE_BUILT" ]; then
    ok "Движок Wine уже последней версии"
else
    if /usr/bin/pgrep -f "Engines/$ENGINE_ID/bin/wineserver" >/dev/null 2>&1; then
        die "Закройте Windows-программы в onwin и запустите команду ещё раз (нужно обновить движок)."
    fi
    download "$(json engine.url)" "$WORK/engine.tar.xz" "Движок Wine" "$(json engine.size)"
    check_sha "$WORK/engine.tar.xz" "$(json engine.sha256)"
    ok "Движок Wine скачан ($(mb "$(json engine.size)") МБ)"
    if [ "$TTY" = 1 ]; then printf '  %s…%s Распаковываю движок' "$C_DIM" "$C_0"; fi
    mkdir -p "$ENGINES"
    staging="$ENGINES/.install-$ENGINE_ID"
    rm -rf "$staging"; mkdir -p "$staging"
    /usr/bin/tar -xf "$WORK/engine.tar.xz" -C "$staging"
    [ -x "$staging/$ENGINE_ID/bin/wine" ] || { rm -rf "$staging"; die "Архив движка повреждён. Запустите команду ещё раз."; }
    # The engine archive has no Wine Mono / Gecko (onwin downloads them when a program needs them): keep the
    # ones the installed engine already has. Same engine id = same Wine = the versions Wine expects.
    for group in mono gecko; do
        for addon in "$ENGINE_DIR/share/wine/$group"/wine-*; do
            [ -d "$addon" ] || continue
            [ -e "$staging/$ENGINE_ID/share/wine/$group/$(basename "$addon")" ] && continue
            mkdir -p "$staging/$ENGINE_ID/share/wine/$group"
            mv "$addon" "$staging/$ENGINE_ID/share/wine/$group/"
        done
    done
    rm -rf "$ENGINE_DIR.old"
    if [ -d "$ENGINE_DIR" ]; then mv "$ENGINE_DIR" "$ENGINE_DIR.old"; fi
    mv "$staging/$ENGINE_ID" "$ENGINE_DIR"
    rm -rf "$staging" "$ENGINE_DIR.old"
    /usr/bin/xattr -dr com.apple.quarantine "$ENGINE_DIR" 2>/dev/null || true
    clear_line
    ok "Движок Wine установлен"
fi

# -------------------------------------------------------------------------------------------- app
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
    ok "Приложение уже последней версии"
else
    if [ -d "$TARGET" ] && app_running_at "$TARGET"; then
        if ask_yes "onwin сейчас открыт. Закрыть его для обновления?"; then
            /usr/bin/osascript -e 'tell application id "app.onwin.Onwin" to quit' >/dev/null 2>&1 || true
            for _ in 1 2 3 4 5 6 7 8 9 10; do app_running_at "$TARGET" || break; sleep 1; done
        fi
        if app_running_at "$TARGET"; then die "Закройте onwin и запустите команду ещё раз."; fi
    fi
    download "$(json app.url)" "$WORK/app.zip" "Приложение" "$(json app.size)"
    check_sha "$WORK/app.zip" "$(json app.sha256)"
    mkdir -p "$WORK/app"
    /usr/bin/ditto -x -k "$WORK/app.zip" "$WORK/app"
    [ -d "$WORK/app/Onwin.app" ] || die "Архив приложения повреждён. Запустите команду ещё раз."
    mkdir -p "$(dirname "$TARGET")"
    rm -rf "$TARGET.new"
    /usr/bin/ditto "$WORK/app/Onwin.app" "$TARGET.new"
    rm -rf "$TARGET"
    mv "$TARGET.new" "$TARGET"
    /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -f "$TARGET" >/dev/null 2>&1 || true
    case "$TARGET" in
        /Applications/*) ok "Приложение установлено в «Программы»" ;;
        "$HOME/Applications/"*) ok "Приложение установлено в «Программы» в вашей папке" ;;
        *) ok "Приложение установлено: $TARGET" ;;
    esac
fi

printf '\n  %sГотово!%s %s установлен.\n' "$C_B" "$C_0" "$LABEL"
if [ "$FRESH" = 1 ]; then
    note "onwin сейчас откроется. Его также можно найти в Launchpad."
fi
note "Обновить позже — выполните эту же команду ещё раз."
printf '\n'
if [ "$FRESH" = 1 ]; then
    /usr/bin/open "$TARGET" || true
fi
