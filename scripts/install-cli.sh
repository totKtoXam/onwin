#!/bin/bash
# Puts onwinctl from Onwin.app on the PATH via a symlink.
#
#   scripts/install-cli.sh [path/to/Onwin.app]      install (default: /Applications/Onwin.app, then build/app.noindex/Onwin.app)
#   scripts/install-cli.sh --uninstall              remove the symlink(s)
#
# Target: /usr/local/bin when it exists and is writable without sudo, otherwise ~/.local/bin.
# Never uses sudo.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NAME="onwinctl"

die() { echo "install-cli: ошибка: $*" >&2; exit 1; }

pick_target_dir() {
    if [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then
        echo /usr/local/bin
    else
        echo "$HOME/.local/bin"
    fi
}

if [ "${1:-}" = "--uninstall" ]; then
    removed=0
    for dir in /usr/local/bin "$HOME/.local/bin"; do
        link="$dir/$NAME"
        if [ -L "$link" ]; then
            case "$(readlink "$link")" in
                *Onwin.app/Contents/MacOS/onwinctl)
                    rm -f "$link" && echo "удалено: $link" && removed=1 ;;
                *) echo "пропускаю $link: указывает не на Onwin.app" ;;
            esac
        fi
    done
    [ "$removed" = 1 ] || echo "ссылки onwinctl не найдены"
    exit 0
fi

APP="${1:-}"
if [ -z "$APP" ]; then
    for candidate in "/Applications/Onwin.app" "$ROOT/build/app.noindex/Onwin.app" "$HOME/Applications/Onwin.app"; do
        if [ -d "$candidate" ]; then APP="$candidate"; break; fi
    done
fi
[ -n "$APP" ] || die "Onwin.app не найден — сначала выполните scripts/build-app.sh или укажите путь"
APP="$(cd "$APP" 2>/dev/null && pwd)" || die "папка $APP не найдена"
TOOL="$APP/Contents/MacOS/$NAME"
[ -x "$TOOL" ] || die "в $APP нет Contents/MacOS/$NAME"

TARGET_DIR="$(pick_target_dir)"
mkdir -p "$TARGET_DIR"
LINK="$TARGET_DIR/$NAME"
if [ -e "$LINK" ] && [ ! -L "$LINK" ]; then
    die "$LINK уже существует и это не ссылка — не трогаю"
fi
ln -sfn "$TOOL" "$LINK"
echo "готово: $LINK → $TOOL"

case ":$PATH:" in
    *":$TARGET_DIR:"*) ;;
    *)
        echo
        echo "Папка $TARGET_DIR не в PATH. Добавьте в ~/.zshrc:"
        echo "    export PATH=\"$TARGET_DIR:\$PATH\""
        ;;
esac
