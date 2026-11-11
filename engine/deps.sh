#!/bin/bash
# onwin — проверка и установка зависимостей для сборки движка (engine/build.sh).
#
# Библиотеки, которые Wine загружает в свой x86_64-процесс (freetype, gnutls), обязаны быть
# x86_64. По умолчанию их собирает ./build-libs.sh в engine/build/x86_64-libs (так же их ищет
# build.sh), и x86_64-Homebrew не нужен; инструменты сборки тогда берутся из arm64-Homebrew.
# Старый путь — x86_64-Homebrew в /usr/local (ONWIN_X86_PREFIX=/usr/local): тогда отсюда же
# ставятся формулы freetype, gnutls, sdl2 и (по желанию) gstreamer.
#
# Скрипт НЕ ставит сам Homebrew, Xcode/Command Line Tools и Rosetta — только печатает
# команды для этого.
#
#   ./deps.sh                    проверить и доустановить формулы
#   ./deps.sh --check            только проверить, ничего не ставить
#   ./deps.sh --with-gstreamer   плюс GStreamer (видео/аудио-кодеки для игр, ~1.5 ГБ зависимостей)
#   ./deps.sh --arm64-tools      инструменты (mingw-w64, meson, ninja, glslang, bison, flex, gettext,
#                                pkgconf, make) — из родного arm64-Homebrew в /opt/homebrew:
#                                кросс-компилятор работает без Rosetta и собирает быстрее.
#                                Библиотеки всё равно ставятся в x86_64-Homebrew.
#   ./deps.sh --with-moltenvk-brew  поставить molten-vk из x86_64-Homebrew (альтернатива
#                                официальному релизу KhronosGroup, который качает build.sh)
set -euo pipefail

X86_BREW=/usr/local/bin/brew
ARM_BREW=/opt/homebrew/bin/brew

# Откуда build.sh берёт x86_64-библиотеки (та же переменная и то же значение по умолчанию,
# что в build.sh): по умолчанию engine/build/x86_64-libs, которые собирает ./build-libs.sh,
# и тогда x86_64-Homebrew не нужен. ONWIN_X86_PREFIX=/usr/local — старый путь через x86_64-Homebrew.
HERE="$(cd "$(dirname "$0")" && pwd)"
LIBS_PREFIX="${ONWIN_X86_PREFIX:-$HERE/build/x86_64-libs}"
LIBS_FROM_BREW=0
[ "${LIBS_PREFIX%/}" = /usr/local ] && LIBS_FROM_BREW=1

# Инструменты сборки (архитектура не важна — они только запускаются во время сборки).
#   bison, flex   — парсеры Wine (системные bison 2.3 / flex слишком старые; формулы keg-only)
#   pkgconf       — pkg-config (бывшая формула pkg-config)
#   make          — GNU make 4 (gmake); /usr/bin/make 3.81 тоже работает, но медленнее
#   gettext       — msgfmt для переводов (--with-gettext)
#   mingw-w64     — кросс-компиляторы x86_64-w64-mingw32 и i686-w64-mingw32 для PE-части
#                   (WoW64: --enable-archs=i386,x86_64) и для DXVK
#   meson, ninja  — сборка DXVK
#   glslang       — glslangValidator, компилирует шейдеры DXVK в SPIR-V
TOOL_FORMULAE="bison flex pkgconf make gettext mingw-w64 meson ninja glslang"

# Библиотеки для x86_64-части Wine (dlopen() по soname; build.sh кладёт их в lib/external).
#   freetype — шрифты (обязательно, --with-freetype)
#   gnutls   — TLS/schannel/bcrypt (обязательно, --with-gnutls); тянет nettle, gmp, libtasn1,
#              libidn2, libunistring, p11-kit
#   sdl2     — геймпады (winebus через SDL)
LIB_FORMULAE="freetype gnutls sdl2"
GST_FORMULAE="gstreamer"
MVK_FORMULAE="molten-vk"

MODE=install
WITH_GST=0
ARM_TOOLS=0
WITH_MVK=0

for arg in "$@"; do
    case "$arg" in
        --check) MODE=check ;;
        --with-gstreamer) WITH_GST=1 ;;
        --arm64-tools) ARM_TOOLS=1 ;;
        --with-moltenvk-brew) WITH_MVK=1 ;;
        -h|--help)
            awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
            exit 0 ;;
        *) echo "Неизвестный параметр: $arg (см. --help)" >&2; exit 2 ;;
    esac
done

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

PROBLEMS=0
problem() { bad "$*"; PROBLEMS=$((PROBLEMS + 1)); }

# ---------------------------------------------------------------- система
say "Проверяю систему"
if [ "$(uname -s)" != "Darwin" ]; then
    echo "Этот скрипт только для macOS." >&2
    exit 1
fi
ok "macOS $(sw_vers -productVersion 2>/dev/null || echo '?')"

IS_ARM64=0
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = "1" ]; then
    IS_ARM64=1
fi

if [ "$IS_ARM64" = 1 ]; then
    if /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
        ok "Rosetta 2 работает"
    else
        problem "Rosetta 2 не установлена. Установите:"
        note "softwareupdate --install-rosetta --agree-to-license"
    fi
else
    ok "Intel Mac — Rosetta не нужна"
    if [ "$ARM_TOOLS" = 1 ]; then
        note "--arm64-tools на Intel Mac не имеет смысла, игнорирую"
        ARM_TOOLS=0
    fi
fi

# Command Line Tools / Xcode: проверяем по файлам, НЕ вызывая clang (на системе без CLT
# вызов /usr/bin/clang открывает окно установщика).
DEVDIR="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
HAVE_CLT=0
if [ -n "$DEVDIR" ]; then
    if [ -x "$DEVDIR/usr/bin/clang" ] || [ -x "$DEVDIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang" ]; then
        HAVE_CLT=1
    fi
fi
if [ "$HAVE_CLT" = 1 ]; then
    ok "Инструменты разработчика: $DEVDIR"
else
    problem "Нет Command Line Tools (clang, ld, otool, install_name_tool, lipo, git). Установите:"
    note "xcode-select --install"
    note "(полный Xcode не нужен — MoltenVK берём готовым релизом)"
fi

FREE_GB="$(df -g "$(dirname "$0")" 2>/dev/null | awk 'NR==2 {print $4}')"
if [ -n "$FREE_GB" ] && [ "$FREE_GB" -lt 25 ] 2>/dev/null; then
    problem "Свободно только ${FREE_GB} ГБ — нужно около 25 ГБ (Homebrew-зависимости + сборка + результат)"
else
    ok "Свободного места: ${FREE_GB:-?} ГБ"
fi

# ---------------------------------------------------------------- Homebrew
say "Проверяю Homebrew"
HAVE_X86_BREW=0
if [ -x "$X86_BREW" ] && [ -d /usr/local/Homebrew ]; then
    HAVE_X86_BREW=1
    ok "x86_64-Homebrew: $X86_BREW"
elif [ "$LIBS_FROM_BREW" = 1 ] || [ "$WITH_GST" = 1 ] || [ "$WITH_MVK" = 1 ]; then
    problem "x86_64-Homebrew в /usr/local не найден (нужен для ONWIN_X86_PREFIX=/usr/local, --with-gstreamer, --with-moltenvk-brew). Установите его:"
    note 'arch -x86_64 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    note "После установки снова запустите ./deps.sh"
else
    note "x86_64-Homebrew не установлен — не нужен: библиотеки собирает ./build-libs.sh"
fi

HAVE_ARM_BREW=0
if [ -x "$ARM_BREW" ]; then
    HAVE_ARM_BREW=1
    ok "arm64-Homebrew: $ARM_BREW"
fi
# Без x86_64-Homebrew инструменты на Apple Silicon берутся из arm64-Homebrew.
if [ "$IS_ARM64" = 1 ] && [ "$HAVE_X86_BREW" = 0 ]; then
    ARM_TOOLS=1
fi
if [ "$ARM_TOOLS" = 1 ] && [ "$HAVE_ARM_BREW" = 0 ]; then
    problem "нет arm64-Homebrew ($ARM_BREW) — инструменты сборки ставятся из него. Установите:"
    note '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
fi

x86brew() { HOMEBREW_NO_ENV_HINTS=1 /usr/bin/arch -x86_64 "$X86_BREW" "$@"; }
armbrew() { HOMEBREW_NO_ENV_HINTS=1 /usr/bin/arch -arm64 "$ARM_BREW" "$@"; }

# installed <x86|arm> <formula>
installed() {
    if [ "$1" = x86 ]; then
        [ "$HAVE_X86_BREW" = 1 ] && x86brew list --formula --versions "$2" >/dev/null 2>&1
    else
        [ "$HAVE_ARM_BREW" = 1 ] && armbrew list --formula --versions "$2" >/dev/null 2>&1
    fi
}

# Формула sdl2 в Homebrew со временем может замениться на sdl2-compat (SDL2 API поверх SDL3).
# Принимаем любую из двух.
resolve_sdl() {
    if installed x86 sdl2; then echo sdl2; return; fi
    if installed x86 sdl2-compat; then echo sdl2-compat; return; fi
    if [ "$HAVE_X86_BREW" = 1 ] && ! x86brew info --formula sdl2 >/dev/null 2>&1; then
        echo sdl2-compat; return
    fi
    echo sdl2
}

X86_WANT=""
ARM_WANT=""
if [ "$ARM_TOOLS" = 1 ]; then
    ARM_WANT="$TOOL_FORMULAE"
else
    X86_WANT="$TOOL_FORMULAE"
fi
if [ "$LIBS_FROM_BREW" = 1 ]; then
    SDL_FORMULA="$(resolve_sdl)"
    X86_WANT="$X86_WANT ${LIB_FORMULAE/sdl2/$SDL_FORMULA}"
fi
[ "$WITH_GST" = 1 ] && X86_WANT="$X86_WANT $GST_FORMULAE"
[ "$WITH_MVK" = 1 ] && X86_WANT="$X86_WANT $MVK_FORMULAE"

say "Проверяю формулы"
X86_MISSING=""
ARM_MISSING=""
for f in $X86_WANT; do
    if installed x86 "$f"; then ok "$f (x86_64)"; else bad "$f (x86_64) — не установлена"; X86_MISSING="$X86_MISSING $f"; fi
done
for f in $ARM_WANT; do
    if installed arm "$f"; then ok "$f (arm64)"; else bad "$f (arm64) — не установлена"; ARM_MISSING="$ARM_MISSING $f"; fi
done
if [ "$WITH_GST" = 0 ]; then
    if [ "$LIBS_FROM_BREW" = 1 ] && installed x86 gstreamer; then
        ok "gstreamer (x86_64) — есть, build.sh включит поддержку кодеков"
    elif [ "$LIBS_FROM_BREW" = 1 ]; then
        note "gstreamer не выбран: видеоролики в играх (Media Foundation) работать не будут."
        note "Чтобы добавить: ./deps.sh --with-gstreamer"
    else
        note "GStreamer в $LIBS_PREFIX нет: видеоролики в играх (Media Foundation) работать не будут."
    fi
fi

if [ "$MODE" = install ]; then
    if [ -n "$X86_MISSING" ] && [ "$HAVE_X86_BREW" = 1 ]; then
        say "Устанавливаю в x86_64-Homebrew:$X86_MISSING"
        # shellcheck disable=SC2086
        x86brew install $X86_MISSING
    fi
    if [ -n "$ARM_MISSING" ] && [ "$HAVE_ARM_BREW" = 1 ]; then
        say "Устанавливаю в arm64-Homebrew:$ARM_MISSING"
        # shellcheck disable=SC2086
        armbrew install $ARM_MISSING
    fi
elif [ -n "$X86_MISSING$ARM_MISSING" ]; then
    PROBLEMS=$((PROBLEMS + 1))
    [ -n "$X86_MISSING" ] && note "Установить: arch -x86_64 $X86_BREW install$X86_MISSING"
    [ -n "$ARM_MISSING" ] && note "Установить: $ARM_BREW install$ARM_MISSING"
fi

# ---------------------------------------------------------------- x86_64-библиотеки
say "Проверяю x86_64-библиотеки ($LIBS_PREFIX)"
for lib in libfreetype.6.dylib libgnutls.30.dylib; do
    if [ -f "$LIBS_PREFIX/lib/$lib" ]; then
        # file, а не lipo: без Command Line Tools /usr/bin/lipo открыл бы окно установщика.
        case "$(/usr/bin/file -bL "$LIBS_PREFIX/lib/$lib" 2>/dev/null)" in
            *x86_64*) ok "$lib (x86_64)" ;;
            *) problem "$LIBS_PREFIX/lib/$lib — не x86_64" ;;
        esac
    elif [ "$LIBS_FROM_BREW" = 1 ]; then
        problem "нет $LIBS_PREFIX/lib/$lib (формулы freetype/gnutls в x86_64-Homebrew)"
    else
        problem "нет $LIBS_PREFIX/lib/$lib — соберите библиотеки: ./build-libs.sh"
    fi
done
if [ "$LIBS_FROM_BREW" = 0 ] && [ "$WITH_GST" = 1 ]; then
    note "build.sh возьмёт GStreamer из x86_64-Homebrew только с ONWIN_X86_PREFIX=/usr/local"
fi

# ---------------------------------------------------------------- проверка инструментов
say "Проверяю кросс-компиляторы MinGW"
MINGW_BIN=""
for d in /usr/local/bin /opt/homebrew/bin; do
    if [ -x "$d/x86_64-w64-mingw32-gcc" ] && [ -x "$d/i686-w64-mingw32-gcc" ]; then MINGW_BIN="$d"; break; fi
done
if [ -z "$MINGW_BIN" ]; then
    if [ "$MODE" = check ] || [ "$HAVE_X86_BREW$HAVE_ARM_BREW" = "00" ]; then
        problem "x86_64-w64-mingw32-gcc / i686-w64-mingw32-gcc не найдены"
    else
        problem "mingw-w64 не найден даже после установки"
    fi
else
    for p in x86_64 i686; do
        ver="$("$MINGW_BIN/$p-w64-mingw32-gcc" -dumpversion 2>/dev/null || echo '?')"
        tm="$("$MINGW_BIN/$p-w64-mingw32-gcc" -v 2>&1 | sed -n 's/^Thread model: //p')"
        if [ "$tm" = "posix" ]; then
            ok "$p-w64-mingw32-gcc $ver (thread model: posix)"
        else
            # DXVK требует POSIX-модель потоков (так же собирает CodeWeavers, см. dxvk/cxlab/image.docker).
            bad "$p-w64-mingw32-gcc $ver: thread model '$tm' — DXVK рассчитан на 'posix', его сборка может не пройти"
        fi
    done
fi

# ---------------------------------------------------------------- итог
echo
if [ "$PROBLEMS" -gt 0 ]; then
    say "Есть проблемы: $PROBLEMS. Исправьте их и запустите ./deps.sh ещё раз."
    exit 1
fi
say "Все зависимости на месте. Дальше: ./build.sh"
