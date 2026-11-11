#!/bin/bash
# onwin — сборка движка Wine из исходников CrossOver 26.3 для macOS.
#
# Результат: engine/dist/<id>/ (по умолчанию id = onwin-cx26.3) в раскладке, которую ждёт
# OnwinCore/Engine.swift:
#   bin/wine, bin/wineserver
#   lib/wine/{x86_64-unix,x86_64-windows,i386-windows}    Wine 11.0 + патчи CodeWeavers (WoW64)
#   lib/wine/x86_64-unix/cxcompatdb.so                    наш engine/compat/onwincompat.c
#   lib/dxvk/{x86_64-windows,i386-windows}                DXVK 1.10.3 (форк CodeWeavers) для MoltenVK
#   lib/dxmt/{x86_64-unix,x86_64-windows,i386-windows}    DXMT (официальный релиз 3Shain/dxmt)
#   lib/external/                                         MoltenVK, freetype, gnutls, SDL2, ... (+ зависимости)
#   lib/gstreamer-1.0/                                    плагины GStreamer (если собран с GStreamer)
#   share/wine/
#   onwin-engine.json
#
# Использование:
#   ./build.sh [параметры] [этап ...]
#
# Этапы (без аргументов выполняются все по порядку, кроме install):
#   toolchain moltenvk wine-configure wine-build wine-install compat dxvk dxmt bundle manifest verify install
#
# Параметры:
#   -j N, --jobs N        число параллельных задач make (по умолчанию — число ядер)
#   --force               выполнить заново выбранные этапы, даже если они уже готовы
#   --install             в конце установить движок командой `onwinctl engine-install`
#   --no-dxvk             не собирать DXVK
#   --no-dxmt             не ставить DXMT
#   --gstreamer=auto|yes|no   поддержка GStreamer (по умолчанию auto — если найден в x86_64-Homebrew)
#   --debug               собирать с отладочной информацией (-g); результат заметно больше
#   --status              показать, какие этапы готовы
#   --clean               удалить промежуточные файлы сборки (engine/build, кроме downloads)
#   --distclean           удалить engine/build целиком и engine/dist/<id>
#   -h, --help            эта справка
#
# Переменные окружения:
#   ONWIN_ENGINE_ID         идентификатор движка (onwin-cx26.3)
#   ONWIN_DIST              куда собирать (engine/dist/$ONWIN_ENGINE_ID)
#   ONWIN_MOLTENVK_DYLIB    путь к уже имеющемуся libMoltenVK.dylib (тогда ничего не скачивается)
#   ONWIN_MOLTENVK_VERSION  версия официального релиза MoltenVK (1.4.2); для другой версии
#                           задайте и ONWIN_MOLTENVK_SHA256
#   ONWIN_DXMT_VERSION      версия DXMT (v0.80); для другой версии задайте и ONWIN_DXMT_SHA256
#   ONWIN_NATIVE_CLANG=0    запускать clang под Rosetta (по умолчанию — родной arm64 clang
#                           с -arch x86_64, это заметно быстрее)
#   ONWIN_MACOS_MIN         MACOSX_DEPLOYMENT_TARGET (11.0)
#   ONWIN_GST_PLUGINS       список плагинов GStreamer через пробел
set -euo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# ------------------------------------------------------------------ Rosetta
# Весь Wine для macOS — x86_64 (Apple Silicon запускает его через Rosetta 2). Чтобы
# config.guess, тесты configure и инструменты x86_64-Homebrew видели x86_64-хост,
# скрипт перезапускает сам себя под `arch -x86_64`.
if [ "$(uname -m)" != "x86_64" ]; then
    if [ "${ONWIN_BUILD_REEXEC:-}" = "1" ]; then
        echo "Не удалось перейти в режим x86_64 (Rosetta 2 установлена?)" >&2
        exit 1
    fi
    export ONWIN_BUILD_REEXEC=1
    exec /usr/bin/arch -x86_64 /bin/bash "$SELF" "$@"
fi

# ------------------------------------------------------------------ пути и версии
ENGINE_DIR="$(dirname "$SELF")"
PROJECT_DIR="$(dirname "$ENGINE_DIR")"
APP_DIR="$PROJECT_DIR/app"
SRC_ROOT="$ENGINE_DIR/sources/sources"
WINE_SRC="$SRC_ROOT/wine"
DXVK_SRC="$SRC_ROOT/dxvk"
COMPAT_SRC="$ENGINE_DIR/compat/onwincompat.c"

BUILD="$ENGINE_DIR/build"
LOGS="$BUILD/logs"
STAMPS="$BUILD/stamps"
DOWNLOADS="$BUILD/downloads"
TOOLBIN="$BUILD/toolbin"
WINE_BUILD="$BUILD/wine"
DXVK_BUILD="$BUILD/dxvk"
MVK_STAGE="$BUILD/moltenvk"
DXMT_STAGE="$BUILD/dxmt"
TMPDIR_BUILD="$BUILD/tmp"

CX_SOURCE_VERSION="26.3.0"
ENGINE_ID="${ONWIN_ENGINE_ID:-onwin-cx26.3}"
DIST="${ONWIN_DIST:-$ENGINE_DIR/dist/$ENGINE_ID}"

# x86_64-библиотеки (gmp, nettle, gnutls, freetype…) собирает ./build-libs.sh: x86_64-Homebrew
# больше не поддерживается Homebrew, поэтому библиотеки собираются из официальных исходников.
X86_PREFIX="${ONWIN_X86_PREFIX:-$ENGINE_DIR/build/x86_64-libs}"
ARM_PREFIX=/opt/homebrew

# MoltenVK: официальный релиз KhronosGroup (сборка из исходников CW требует полного Xcode).
# В исходниках CrossOver лежит MoltenVK 1.2.10 (форк CW); берём актуальный официальный.
MOLTENVK_DEFAULT_VERSION="1.4.2"
MOLTENVK_DEFAULT_SHA256="f95765a6229cb7b915990a2890ce12ebe36a730b021545d3d52ae69ce4c4024e"
MOLTENVK_VERSION="${ONWIN_MOLTENVK_VERSION:-$MOLTENVK_DEFAULT_VERSION}"
if [ "$MOLTENVK_VERSION" = "$MOLTENVK_DEFAULT_VERSION" ]; then
    MOLTENVK_SHA256="${ONWIN_MOLTENVK_SHA256:-$MOLTENVK_DEFAULT_SHA256}"
else
    MOLTENVK_SHA256="${ONWIN_MOLTENVK_SHA256:-}"
fi
MOLTENVK_URL="https://github.com/KhronosGroup/MoltenVK/releases/download/v${MOLTENVK_VERSION}/MoltenVK-macos.tar"

# DXMT: официальный релиз 3Shain/dxmt (в архиве CrossOver его нет). Вариант "-builtin"
# уже помечен как встроенные DLL Wine.
DXMT_DEFAULT_VERSION="v0.80"
DXMT_DEFAULT_SHA256="8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d"
DXMT_VERSION="${ONWIN_DXMT_VERSION:-$DXMT_DEFAULT_VERSION}"
if [ "$DXMT_VERSION" = "$DXMT_DEFAULT_VERSION" ]; then
    DXMT_SHA256="${ONWIN_DXMT_SHA256:-$DXMT_DEFAULT_SHA256}"
else
    DXMT_SHA256="${ONWIN_DXMT_SHA256:-}"
fi
DXMT_URL="https://github.com/3Shain/dxmt/releases/download/${DXMT_VERSION}/dxmt-${DXMT_VERSION}-builtin.tar.gz"

# Плагины GStreamer — тот же набор, что нужен winegstreamer для типичных роликов в играх
# (applemedia = аппаратное декодирование H.264/HEVC через VideoToolbox; osxaudio = atdec, AAC/MP3
# через AudioToolbox — в GStreamer ≥ 1.26 он перенесён из applemedia).
GST_PLUGINS="${ONWIN_GST_PLUGINS:-applemedia asf audioconvert audioparsers audioresample avi coreelements deinterlace id3demux isomp4 opengl osxaudio playback typefindfunctions videoconvertscale videofilter videoparsersbad wavparse}"

ALL_STAGES="toolchain moltenvk wine-configure wine-build wine-install compat dxvk dxmt addons bundle manifest verify"

# ------------------------------------------------------------------ параметры
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
FORCE=0
DO_INSTALL=0
WITH_DXVK=1
WITH_DXMT=1
GSTREAMER=auto
DEBUG_BUILD=0
ACTION=build
REQUESTED=""

while [ $# -gt 0 ]; do
    case "$1" in
        -j|--jobs) shift; JOBS="${1:?после --jobs нужно число}" ;;
        -j*) JOBS="${1#-j}" ;;
        --jobs=*) JOBS="${1#--jobs=}" ;;
        --force) FORCE=1 ;;
        --install) DO_INSTALL=1 ;;
        --no-dxvk) WITH_DXVK=0 ;;
        --no-dxmt) WITH_DXMT=0 ;;
        --gstreamer=*) GSTREAMER="${1#--gstreamer=}" ;;
        --debug) DEBUG_BUILD=1 ;;
        --status) ACTION=status ;;
        --clean) ACTION=clean ;;
        --distclean) ACTION=distclean ;;
        -h|--help)
            awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$SELF"
            exit 0 ;;
        -*) echo "Неизвестный параметр: $1 (см. --help)" >&2; exit 2 ;;
        *)
            case " $ALL_STAGES install " in
                *" $1 "*) REQUESTED="$REQUESTED $1" ;;
                *) echo "Неизвестный этап: $1. Этапы: $ALL_STAGES install" >&2; exit 2 ;;
            esac ;;
    esac
    shift
done
case "$GSTREAMER" in auto|yes|no) ;; *) echo "--gstreamer: auto, yes или no" >&2; exit 2 ;; esac

# ------------------------------------------------------------------ вывод и журналы
say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mВнимание:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mОшибка:\033[0m %s\n' "$*" >&2; exit 1; }

mkdir -p "$LOGS" "$STAMPS" "$DOWNLOADS" "$TOOLBIN" "$TMPDIR_BUILD"

CURRENT_STAGE=""
LOCK_DIR="$BUILD/.build.lock"
HAVE_LOCK=0
on_exit() {
    local status=$?
    if [ $status -ne 0 ] && [ -n "$CURRENT_STAGE" ]; then
        echo >&2
        printf '\033[1;31mЭтап «%s» не завершён.\033[0m Журнал: %s\n' "$CURRENT_STAGE" "$LOGS/$CURRENT_STAGE.log" >&2
        echo "Исправьте причину и запустите ./build.sh снова — готовые этапы будут пропущены." >&2
    fi
    [ "$HAVE_LOCK" = 1 ] && rm -rf "$LOCK_DIR"
    return 0
}
trap on_exit EXIT

# Две сборки одновременно ломают друг друга: этап toolchain пересоздаёт build/toolbin, пока
# make другой сборки им пользуется. Поэтому сборка и очистка берут блокировку.
acquire_lock() {
    local pid
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            die "уже идёт другая сборка (PID $pid). Дождитесь её окончания."
        fi
        rm -rf "$LOCK_DIR"   # процесс, взявший блокировку, уже завершился
        mkdir "$LOCK_DIR" || die "не удалось создать $LOCK_DIR"
    fi
    echo $$ >"$LOCK_DIR/pid"
    HAVE_LOCK=1
}

# logrun <журнал> <команда...> — выполняет команду, весь вывод пишет в журнал этапа.
logrun() {
    local log="$LOGS/$1.log"
    shift
    printf '\n[%s] $ %s\n' "$(date '+%H:%M:%S')" "$*" >>"$log"
    if ! "$@" >>"$log" 2>&1; then
        printf '\033[1;31mКоманда завершилась с ошибкой:\033[0m %s\n' "$*" >&2
        echo "Последние строки журнала $log:" >&2
        tail -n 40 "$log" >&2
        exit 1
    fi
}

stamp_file() { echo "$STAMPS/$1.done"; }
# not_older <этап> <от чего зависит...> — отметка этапа не старше отметок зависимостей.
not_older() {
    local s="$1" d
    shift
    for d in "$@"; do
        [ "$(stamp_file "$d")" -nt "$(stamp_file "$s")" ] && return 1
    done
    return 0
}

# Проверки, что результат этапа действительно на месте (на случай, если dist удалили вручную).
check_moltenvk()       { [ -f "$MVK_STAGE/lib/libMoltenVK.dylib" ]; }
check_wine_configure() { [ -f "$WINE_BUILD/Makefile" ] && [ -f "$WINE_BUILD/include/config.h" ] &&
                         [ "$(cat "$WINE_BUILD/.onwin-configure-args" 2>/dev/null)" = "$(wine_configure_signature)" ]; }
check_wine_build()     { { [ -x "$WINE_BUILD/loader/wine" ] || [ -x "$WINE_BUILD/loader/wine64" ]; } && not_older wine-build wine-configure; }
check_wine_install()   { [ -x "$DIST/bin/wine" ] && [ -f "$DIST/lib/wine/x86_64-unix/ntdll.so" ] && not_older wine-install wine-build; }
check_compat()         { [ -f "$DIST/lib/wine/x86_64-unix/cxcompatdb.so" ]; }
check_dxvk()           { [ "$WITH_DXVK" = 0 ] || [ -f "$DIST/lib/dxvk/x86_64-windows/d3d11.dll" ]; }
check_dxmt()           { [ "$WITH_DXMT" = 0 ] || { [ -f "$DIST/lib/dxmt/x86_64-windows/d3d11.dll" ] && [ -f "$DIST/lib/wine/x86_64-windows/winemetal.dll" ]; }; }
check_addons()         { [ -d "$DIST/share/wine/mono/wine-mono-$WINE_MONO_VERSION" ] && [ -d "$DIST/share/wine/gecko/wine-gecko-$WINE_GECKO_VERSION-x86_64" ]; }
check_bundle()         { [ -f "$DIST/lib/external/libMoltenVK.dylib" ] && not_older bundle moltenvk wine-install compat dxmt; }
check_manifest()       { [ -f "$DIST/onwin-engine.json" ]; }

stage_ready() {
    local name="$1" fn
    [ -f "$(stamp_file "$name")" ] || return 1
    fn="check_${name//-/_}"
    if declare -F "$fn" >/dev/null; then
        "$fn" || return 1
    fi
    return 0
}

# Этапы, которые всегда выполняются (дешёвые и зависят от текущего окружения).
ALWAYS_RUN=" toolchain manifest verify install "

run_stage() {
    local name="$1" title="$2" fn start
    fn="stage_${name//-/_}"
    case "$ALWAYS_RUN" in
        *" $name "*) ;;
        *)
            if [ "$FORCE" = 0 ] && stage_ready "$name"; then
                say "[$name] уже готово — пропускаю"
                return 0
            fi ;;
    esac
    CURRENT_STAGE="$name"
    say "[$name] $title"
    printf '\n========== %s  %s ==========\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$name" >>"$LOGS/$name.log"
    start=$(date +%s)
    rm -f "$(stamp_file "$name")"
    "$fn"
    date '+%Y-%m-%dT%H:%M:%S' >"$(stamp_file "$name")"
    info "готово за $(( ($(date +%s) - start) / 60 )) мин $(( ($(date +%s) - start) % 60 )) с"
    CURRENT_STAGE=""
}

# ------------------------------------------------------------------ вспомогательное
abspath()  { perl -MCwd=realpath -e 'my $p = realpath($ARGV[0]); print defined $p ? $p : $ARGV[0]' "$1"; }
relpath()  { perl -MFile::Spec -e 'print File::Spec->abs2rel($ARGV[0], $ARGV[1])' "$1" "$2"; }

is_macho() {
    local t
    t="$(file -b "$1" 2>/dev/null || true)"
    case "$t" in *Mach-O*) return 0 ;; *) return 1 ;; esac
}

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# download <url> <файл> <sha256|пусто>
download() {
    local url="$1" out="$2" sum="$3" got
    if [ -f "$out" ]; then
        if [ -z "$sum" ] || [ "$(sha256_of "$out")" = "$sum" ]; then
            info "уже скачано: $(basename "$out")"
            return 0
        fi
        warn "контрольная сумма $(basename "$out") не совпала — качаю заново"
        rm -f "$out"
    fi
    info "скачиваю $url"
    curl -fL --retry 3 --retry-delay 2 -C - -o "$out.part" "$url" || {
        rm -f "$out.part"
        die "не удалось скачать $url"
    }
    if [ -n "$sum" ]; then
        got="$(sha256_of "$out.part")"
        if [ "$got" != "$sum" ]; then
            rm -f "$out.part"
            die "SHA-256 не совпадает для $url: ожидалось $sum, получено $got"
        fi
    else
        warn "для $url не задана контрольная сумма — проверка пропущена (SHA-256: $(sha256_of "$out.part"))"
    fi
    mv "$out.part" "$out"
}

# Метка встроенной DLL Wine: строка "Wine builtin DLL" (32 байта с нулями) сразу после
# DOS-заголовка, по смещению 0x40. Её проверяет wineserver (server/mapping.c), и без неё
# ntdll отбрасывает DLL из пути встроенных DLL (dlls/ntdll/unix/virtual.c,
# virtual_map_builtin_module: "found in WINEDLLPATH but not a builtin, ignoring").
# Так же, как Wine при `make install` (winebuild --builtin), помечаем DLL DXVK/DXMT.
has_builtin_marker() {
    perl -e 'open(my $f, "<", $ARGV[0]) or exit 2; binmode $f;
             read($f, my $h, 0x60) == 0x60 or exit 1;
             exit((substr($h, 0, 2) eq "MZ" && substr($h, 0x40, 16) eq "Wine builtin DLL") ? 0 : 1)' "$1"
}

mark_builtin() {
    local f="$1" wb="$WINE_BUILD/tools/winebuild/winebuild"
    if [ -x "$wb" ]; then
        "$wb" --builtin "$f"
    else
        # Та же операция, что make_builtin_files() в tools/winebuild/spec32.c.
        perl -e 'my $p = $ARGV[0]; open(my $f, "+<", $p) or die "$p: $!\n"; binmode $f;
                 read($f, my $h, 0x40) == 0x40 or die "$p: слишком короткий файл\n";
                 substr($h, 0, 2) eq "MZ" or die "$p: не PE-файл\n";
                 my $lfanew = unpack("V", substr($h, 0x3c, 4));
                 $lfanew >= 0x60 or die "$p: нет места для метки Wine (e_lfanew=$lfanew)\n";
                 seek($f, 0x40, 0) or die; print $f pack("a32", "Wine builtin DLL"); close($f) or die "$p: $!\n";' "$f"
    fi
    has_builtin_marker "$f" || die "не удалось пометить $f как встроенную DLL Wine"
}

# mark_dir_builtin <папка> — помечает все *.dll в папке
mark_dir_builtin() {
    local d="$1" f n=0
    for f in "$d"/*.dll; do
        [ -f "$f" ] || continue
        if ! has_builtin_marker "$f"; then
            mark_builtin "$f"
            n=$((n + 1))
        fi
    done
    info "$(basename "$(dirname "$d")")/$(basename "$d"): помечено встроенными — $n"
}

# ------------------------------------------------------------------ toolchain
# Все инструменты собираются в engine/build/toolbin, и PATH сборки состоит только из него
# и системных каталогов — так в Wine не попадёт ничего случайного из /usr/local или
# arm64-Homebrew (/opt/homebrew), а pkg-config смотрит только в x86_64-Homebrew.

# find_first <имя> <каталог...>
find_first() {
    local name="$1" d
    shift
    for d in "$@"; do
        if [ -x "$d/$name" ]; then echo "$d/$name"; return 0; fi
    done
    return 1
}

link_tool() { # <имя в toolbin> <путь>
    ln -sf "$2" "$TOOLBIN/$1"
    info "$(printf '%-28s' "$1") → $2"
}

# Выбрать каталог-источник для обычных инструментов: x86_64-Homebrew, затем arm64-Homebrew.
TOOL_DIRS="$X86_PREFIX/bin $ARM_PREFIX/bin"

require_tool() { # <имя в toolbin> <формула> <каталог...>
    local name="$1" formula="$2" p
    shift 2
    # shellcheck disable=SC2086
    if p="$(find_first "$name" "$@")"; then
        link_tool "$name" "$p"
    else
        die "не найден $name (формула $formula). Запустите ./deps.sh"
    fi
}

detect_devtools() {
    local dev
    dev="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
    if [ -n "$dev" ] && { [ -x "$dev/usr/bin/clang" ] || [ -x "$dev/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang" ]; }; then
        return 0
    fi
    die "нет Command Line Tools. Установите: xcode-select --install"
}

write_cc_wrappers() { # <native: 1|0>
    local native="$1" pre=""
    [ "$native" = 1 ] && pre="/usr/bin/arch -arm64 "
    cat >"$TOOLBIN/onwin-x86_64-clang" <<EOF
#!/bin/bash
exec ${pre}/usr/bin/clang -arch x86_64 "\$@"
EOF
    cat >"$TOOLBIN/onwin-x86_64-clang++" <<EOF
#!/bin/bash
exec ${pre}/usr/bin/clang++ -arch x86_64 "\$@"
EOF
    chmod +x "$TOOLBIN/onwin-x86_64-clang" "$TOOLBIN/onwin-x86_64-clang++"
}

test_cc() {
    local t="$TMPDIR_BUILD/cctest"
    printf 'int main(void) { return 0; }\n' >"$t.c"
    rm -f "$t"
    "$TOOLBIN/onwin-x86_64-clang" -o "$t" "$t.c" >>"$LOGS/toolchain.log" 2>&1 || return 1
    case "$(file -b "$t" 2>/dev/null)" in *x86_64*) ;; *) return 1 ;; esac
    "$t" || return 1
}

stage_toolchain() {
    detect_devtools
    { [ -f "$X86_PREFIX/lib/libgnutls.30.dylib" ] && [ -f "$X86_PREFIX/lib/libfreetype.6.dylib" ]; } ||
        die "нет x86_64-библиотек в $X86_PREFIX. Сначала запустите ./build-libs.sh"

    case "$ENGINE_DIR$DIST" in
        *" "*) die "путь к engine/ или dist/ содержит пробел — Makefile'ы Wine так не работают. Перенесите проект." ;;
    esac
    case "$DIST" in
        /|"$HOME"|"$HOME/"|/Applications*|/System*|/usr*|/Library*) die "ONWIN_DIST=$DIST — недопустимое место для сборки" ;;
        /?*) ;;
        *) die "ONWIN_DIST должен быть абсолютным путём (сейчас: $DIST)" ;;
    esac
    [ -x "$WINE_SRC/configure" ] || die "нет исходников Wine: $WINE_SRC (распакуйте crossover-sources-$CX_SOURCE_VERSION.tar.gz в engine/sources)"

    rm -f "$TOOLBIN"/*

    # Парсеры: keg-only формулы, поэтому ищем в opt/<формула>/bin.
    require_tool bison   bison   "$X86_PREFIX/opt/bison/bin" "$ARM_PREFIX/opt/bison/bin"
    require_tool flex    flex    "$X86_PREFIX/opt/flex/bin"  "$ARM_PREFIX/opt/flex/bin"
    # shellcheck disable=SC2086
    if p="$(find_first pkg-config $TOOL_DIRS)" || p="$(find_first pkgconf $TOOL_DIRS)"; then
        link_tool pkg-config "$p"
    else
        die "не найден pkg-config (формула pkgconf). Запустите ./deps.sh"
    fi
    # shellcheck disable=SC2086
    require_tool msgfmt  gettext $TOOL_DIRS
    # shellcheck disable=SC2086
    require_tool msgmerge gettext $TOOL_DIRS
    if p="$(find_first gmake $TOOL_DIRS)"; then
        link_tool make "$p"
    else
        warn "GNU make 4 (формула make) не найден — использую /usr/bin/make 3.81"
        link_tool make /usr/bin/make
    fi
    if [ "$WITH_DXVK" = 1 ]; then
        # shellcheck disable=SC2086
        require_tool meson meson $TOOL_DIRS
        # shellcheck disable=SC2086
        require_tool ninja ninja $TOOL_DIRS
        # shellcheck disable=SC2086
        require_tool glslangValidator glslang $TOOL_DIRS
    fi

    # MinGW: все x86_64-w64-mingw32-* и i686-w64-mingw32-* из одного каталога.
    local mingw_dir="" d f pfx
    for d in $TOOL_DIRS; do
        if [ -x "$d/x86_64-w64-mingw32-gcc" ] && [ -x "$d/i686-w64-mingw32-gcc" ]; then mingw_dir="$d"; break; fi
    done
    [ -n "$mingw_dir" ] || die "нет кросс-компиляторов mingw-w64 (x86_64-w64-mingw32-gcc, i686-w64-mingw32-gcc). Запустите ./deps.sh"
    for pfx in x86_64-w64-mingw32 i686-w64-mingw32; do
        for f in "$mingw_dir/$pfx-"*; do
            [ -e "$f" ] || continue
            ln -sf "$f" "$TOOLBIN/$(basename "$f")"
        done
    done
    info "$(printf '%-28s' 'mingw-w64') → $mingw_dir ($("$mingw_dir/x86_64-w64-mingw32-gcc" -dumpversion))"

    # Компилятор для x86_64-части (macOS): Apple clang с -arch x86_64.
    local native=0
    if [ "${ONWIN_NATIVE_CLANG:-1}" = 1 ] && [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ]; then
        native=1
    fi
    write_cc_wrappers "$native"
    if ! test_cc; then
        if [ "$native" = 1 ]; then
            warn "родной arm64 clang с -arch x86_64 не сработал — запускаю clang под Rosetta"
            write_cc_wrappers 0
            test_cc || die "clang -arch x86_64 не собирает рабочую программу (журнал: $LOGS/toolchain.log)"
        else
            die "clang -arch x86_64 не собирает рабочую программу (журнал: $LOGS/toolchain.log)"
        fi
    fi
    if [ "$native" = 1 ] && grep -q 'arch -arm64' "$TOOLBIN/onwin-x86_64-clang"; then
        info "$(printf '%-28s' 'clang (macOS-часть)') → /usr/bin/clang -arch x86_64 (родной arm64)"
    else
        info "$(printf '%-28s' 'clang (macOS-часть)') → /usr/bin/clang -arch x86_64 (под Rosetta)"
    fi

    local free
    free="$(df -g "$ENGINE_DIR" | awk 'NR==2 {print $4}')"
    if [ -n "$free" ] && [ "$free" -lt 15 ] 2>/dev/null; then
        warn "свободно только ${free} ГБ; сборке нужно ~10–15 ГБ"
    fi
}

# Окружение сборки: только toolbin + системные каталоги; pkg-config — только x86_64-Homebrew.
setup_build_env() {
    export PATH="$TOOLBIN:/usr/bin:/bin:/usr/sbin:/sbin"
    export PKG_CONFIG="$TOOLBIN/pkg-config"
    export PKG_CONFIG_LIBDIR="$X86_PREFIX/lib/pkgconfig:$X86_PREFIX/share/pkgconfig"
    unset PKG_CONFIG_PATH CPATH LIBRARY_PATH C_INCLUDE_PATH OBJC_INCLUDE_PATH CPLUS_INCLUDE_PATH || true
    export MACOSX_DEPLOYMENT_TARGET="${ONWIN_MACOS_MIN:-11.0}"
    export TMPDIR="$TMPDIR_BUILD"
}

# ------------------------------------------------------------------ moltenvk
stage_moltenvk() {
    local src="${ONWIN_MOLTENVK_DYLIB:-}" archs
    setup_build_env
    mkdir -p "$MVK_STAGE/lib"
    rm -f "$MVK_STAGE/lib/libMoltenVK.dylib"
    if [ -n "$src" ]; then
        [ -f "$src" ] || die "ONWIN_MOLTENVK_DYLIB=$src — файла нет"
        info "использую готовый $src"
        cp "$(abspath "$src")" "$MVK_STAGE/lib/libMoltenVK.dylib"
        echo "custom ($src)" >"$MVK_STAGE/VERSION"
    else
        local tarball="$DOWNLOADS/MoltenVK-macos-v$MOLTENVK_VERSION.tar" x="$MVK_STAGE/extract" found
        info "MoltenVK $MOLTENVK_VERSION (официальный релиз KhronosGroup)"
        download "$MOLTENVK_URL" "$tarball" "$MOLTENVK_SHA256"
        rm -rf "$x"
        mkdir -p "$x"
        logrun moltenvk tar -xf "$tarball" -C "$x"
        found="$(find "$x" -path '*dynamic/dylib/macOS/libMoltenVK.dylib' -type f | sed -n 1p)"
        [ -n "$found" ] || found="$(find "$x" -name libMoltenVK.dylib -type f ! -path '*/static/*' | sed -n 1p)"
        [ -n "$found" ] || die "в $tarball не найден libMoltenVK.dylib для macOS"
        cp "$found" "$MVK_STAGE/lib/libMoltenVK.dylib"
        echo "$MOLTENVK_VERSION" >"$MVK_STAGE/VERSION"
        rm -rf "$x"
    fi
    chmod u+w "$MVK_STAGE/lib/libMoltenVK.dylib"
    archs="$(lipo -archs "$MVK_STAGE/lib/libMoltenVK.dylib" 2>/dev/null || true)"
    case " $archs " in
        *" x86_64 "*) ;;
        *) die "libMoltenVK.dylib без x86_64 (архитектуры: ${archs:-?}) — Wine под Rosetta его не загрузит" ;;
    esac
    if [ "$archs" != "x86_64" ]; then
        # Универсальный dylib: оставляем только x86_64, вдвое меньше.
        logrun moltenvk lipo "$MVK_STAGE/lib/libMoltenVK.dylib" -thin x86_64 -output "$MVK_STAGE/lib/libMoltenVK.x86_64.dylib"
        mv "$MVK_STAGE/lib/libMoltenVK.x86_64.dylib" "$MVK_STAGE/lib/libMoltenVK.dylib"
    fi
    info "libMoltenVK.dylib: $(du -h "$MVK_STAGE/lib/libMoltenVK.dylib" | awk '{print $1}')"
}

# ------------------------------------------------------------------ wine
OPT_FLAGS="-O2"
[ "$DEBUG_BUILD" = 1 ] && OPT_FLAGS="-g -O2"

pkg_exists() {
    [ -x "$TOOLBIN/pkg-config" ] || return 1
    PKG_CONFIG_LIBDIR="$X86_PREFIX/lib/pkgconfig:$X86_PREFIX/share/pkgconfig" PKG_CONFIG_PATH= \
        "$TOOLBIN/pkg-config" --exists "$@" 2>/dev/null
}

GST_FLAG=""
SDL_FLAG=""
decide_optional() {
    case "$GSTREAMER" in
        yes) GST_FLAG="--with-gstreamer" ;;
        no)  GST_FLAG="--without-gstreamer" ;;
        auto)
            if pkg_exists gstreamer-1.0 gstreamer-video-1.0 gstreamer-audio-1.0 gstreamer-tag-1.0; then
                GST_FLAG="--with-gstreamer"
            else
                GST_FLAG="--without-gstreamer"
            fi ;;
    esac
    if pkg_exists sdl2; then SDL_FLAG="--with-sdl"; else SDL_FLAG="--without-sdl"; fi
}

# Параметры configure. Каждый проверен по engine/sources/sources/wine/configure
# (ac_user_opts) — и ещё раз автоматически в verify_configure_flags().
#
#  Явное --with-X делает отсутствие библиотеки ошибкой (WINE_ERROR_WITH / WINE_WARNING_WITH /
#  WINE_NOTICE_WITH в aclocal.m4) — так поступаем только для обязательных вещей.
#  opengl, opencl, cups, pcap, pcsclite, krb5/gssapi, unwind на macOS берутся из системы
#  и определяются автоматически (явное --with-opengl, например, требовал бы EGL).
wine_configure_args() {
    printf '%s\n' \
        "--prefix=$DIST" \
        "--enable-archs=i386,x86_64" \
        "--disable-tests" \
        "--without-x" \
        "--without-wayland" \
        "--with-mingw" \
        "--with-coreaudio" \
        "--with-freetype" \
        "--with-gnutls" \
        "--with-vulkan" \
        "--with-gettext" \
        "--without-gettextpo" \
        "--without-fontconfig" \
        "--without-alsa" \
        "--without-pulse" \
        "--without-oss" \
        "--without-dbus" \
        "--without-udev" \
        "--without-usb" \
        "--without-v4l2" \
        "--without-sane" \
        "--without-gphoto" \
        "--without-capi" \
        "--without-netapi" \
        "--without-hwloc" \
        "--without-inotify" \
        "--without-ffmpeg" \
        "$GST_FLAG" \
        "$SDL_FLAG" \
        "CC=$TOOLBIN/onwin-x86_64-clang" \
        "CXX=$TOOLBIN/onwin-x86_64-clang++" \
        "OBJC=$TOOLBIN/onwin-x86_64-clang" \
        "CFLAGS=$OPT_FLAGS" \
        "CXXFLAGS=$OPT_FLAGS" \
        "OBJCFLAGS=$OPT_FLAGS" \
        "CPPFLAGS=-I$X86_PREFIX/include" \
        "LDFLAGS=-L$MVK_STAGE/lib -L$X86_PREFIX/lib -Wl,-headerpad_max_install_names" \
        "CROSSCFLAGS=$OPT_FLAGS" \
        "ac_cv_lib_soname_vulkan="
    # ac_cv_lib_soname_vulkan= : не брать libvulkan (vulkan-loader), если он вдруг стоит в
    # /usr/local — Wine должен загружать MoltenVK напрямую (SONAME_LIBVULKAN=libMoltenVK.dylib).
}

wine_configure_signature() {
    decide_optional
    wine_configure_args
    echo "macos-min=${ONWIN_MACOS_MIN:-11.0}"
}

# Каждый --enable-*/--with-*/--without-*/--disable-* должен существовать в configure.
verify_configure_flags() {
    local a name bad=0 known nl='
'
    known="$(awk '/^ac_user_opts=/{f=1; next} f && /^'"'"'/{exit} f' "$WINE_SRC/configure")"
    [ -n "$known" ] || die "не удалось прочитать ac_user_opts из $WINE_SRC/configure"
    while IFS= read -r a; do
        case "$a" in
            --prefix=*) continue ;;
            --enable-*|--disable-*|--with-*|--without-*) ;;
            *) continue ;;
        esac
        name="${a%%=*}"
        name="${name#--}"
        case "$name" in
            enable-*)  name="enable_${name#enable-}" ;;
            disable-*) name="enable_${name#disable-}" ;;
            without-*) name="with_${name#without-}" ;;
            with-*)    name="with_${name#with-}" ;;
        esac
        name="$(echo "$name" | tr '-' '_')"
        case "$nl$known$nl" in
            *"$nl$name$nl"*) ;;
            *) warn "configure не знает параметр $a"; bad=1 ;;
        esac
    done <<EOF
$(wine_configure_args)
EOF
    [ "$bad" = 0 ] || die "в списке параметров configure есть неизвестные (см. выше)"
}

stage_wine_configure() {
    setup_build_env
    decide_optional
    verify_configure_flags
    info "GStreamer: ${GST_FLAG#--}, SDL2: ${SDL_FLAG#--}"
    mkdir -p "$WINE_BUILD"
    if [ -f "$WINE_BUILD/config.status" ] &&
       [ "$(cat "$WINE_BUILD/.onwin-configure-args" 2>/dev/null)" != "$(wine_configure_signature)" ]; then
        info "параметры изменились — начинаю конфигурацию заново"
        rm -f "$WINE_BUILD/config.cache" "$WINE_BUILD/config.status"
    fi
    local args=() a
    while IFS= read -r a; do
        [ -n "$a" ] && args+=("$a")
    done <<EOF
$(wine_configure_args)
EOF
    (
        cd "$WINE_BUILD"
        logrun wine-configure "$WINE_SRC/configure" "${args[@]}"
    )
    wine_configure_signature >"$WINE_BUILD/.onwin-configure-args"

    # Короткая сводка того, что нашёл configure.
    local h="$WINE_BUILD/include/config.h" s
    for s in SONAME_LIBFREETYPE SONAME_LIBGNUTLS SONAME_LIBVULKAN SONAME_LIBSDL2 SONAME_LIBCUPS SONAME_LIBKRB5; do
        if grep -q "^#define $s " "$h"; then
            info "$(printf '%-20s' "$s") $(sed -n "s/^#define $s \"\(.*\)\"/\1/p" "$h")"
        fi
    done
    grep -q '^#define SONAME_LIBVULKAN "libMoltenVK' "$h" ||
        die "configure не связал Vulkan с MoltenVK (SONAME_LIBVULKAN), см. $LOGS/wine-configure.log"
    if grep -E -q "configure: (WARNING|OpenCL|libunwind)" "$LOGS/wine-configure.log" 2>/dev/null; then
        info "предупреждения configure — в конце $LOGS/wine-configure.log"
    fi
}

stage_wine_build() {
    setup_build_env
    # Наши патчи к Wine (engine/patches/wine/*.patch), например понятные имена в Dock.
    local wp
    for wp in "$ENGINE_DIR"/patches/wine/*.patch; do
        [ -f "$wp" ] || continue
        if patch -d "$WINE_SRC" -p1 -R --dry-run -s -f <"$wp" >/dev/null 2>&1; then continue; fi
        patch -d "$WINE_SRC" -p1 -s -f <"$wp" || die "не удалось применить $(basename "$wp")"
        info "применён патч $(basename "$wp")"
    done
    info "make -j$JOBS — это самый долгий этап (обычно 30–60 минут)"
    # sfnt2fon (утилита сборки шрифтов) линкуется с нашим libfreetype через @rpath, а DYLD_*
    # не доходит до неё через /usr/bin/make и /bin/sh (SIP). Добавляем ей rpath на x86_64-libs.
    logrun wine-build make -C "$WINE_BUILD" -j"$JOBS" tools/sfnt2fon/sfnt2fon
    if ! otool -l "$WINE_BUILD/tools/sfnt2fon/sfnt2fon" | grep -q "path $X86_PREFIX/lib "; then
        install_name_tool -add_rpath "$X86_PREFIX/lib" "$WINE_BUILD/tools/sfnt2fon/sfnt2fon"
        codesign --force -s - "$WINE_BUILD/tools/sfnt2fon/sfnt2fon" >/dev/null 2>&1 || true
    fi
    logrun wine-build make -C "$WINE_BUILD" -j"$JOBS"
}

stage_wine_install() {
    setup_build_env
    # install-lib: только среда выполнения (без заголовков, winegcc/winebuild и .a — это install-dev).
    # Wine сам помечает свои PE-файлы при установке (winebuild --builtin как strip-программа).
    rm -rf "$DIST/bin" "$DIST/lib/wine" "$DIST/share/wine"
    mkdir -p "$DIST"
    logrun wine-install make -C "$WINE_BUILD" -j"$JOBS" install-lib
    [ -x "$DIST/bin/wine" ] || die "после make install-lib нет $DIST/bin/wine"
    [ -x "$DIST/bin/wineserver" ] || die "после make install-lib нет $DIST/bin/wineserver"
    [ -f "$DIST/lib/wine/i386-windows/ntdll.dll" ] || die "нет i386-windows/ntdll.dll — 32-битная часть WoW64 не собралась"
}

# ------------------------------------------------------------------ compat
stage_compat() {
    setup_build_env
    [ -f "$COMPAT_SRC" ] || die "нет $COMPAT_SRC"
    local out="$DIST/lib/wine/x86_64-unix/cxcompatdb.so"
    [ -d "$(dirname "$out")" ] || die "нет $(dirname "$out") — сначала этап wine-install"
    # Имя cxcompatdb.so выбрано потому, что его ищет ntdll CrossOver (CW Hack 24067,
    # dlls/ntdll/unix/loader.c). prepend_dll_path() берётся через dlsym — линковать с ntdll не нужно.
    logrun compat "$TOOLBIN/onwin-x86_64-clang" -shared -fPIC $OPT_FLAGS -Wall \
        -o "$out" "$COMPAT_SRC" \
        -Wl,-install_name,@rpath/cxcompatdb.so -Wl,-headerpad_max_install_names
    case "$(file -b "$out")" in *x86_64*) ;; *) die "cxcompatdb.so собран не под x86_64" ;; esac
}

# ------------------------------------------------------------------ dxvk
write_dxvk_cross() { # <bits> <файл>
    local bits="$1" out="$2" pfx cpu fam
    if [ "$bits" = 64 ]; then pfx=x86_64-w64-mingw32; cpu=x86_64; fam=x86_64
    else pfx=i686-w64-mingw32; cpu=x86; fam=x86; fi
    # На основе dxvk/build-win64.txt и build-win32.txt, но с абсолютными путями к toolbin.
    # -include cstdint: DXVK 1.10.3 (2022) местами полагается на транзитивные include,
    # которые убрали в GCC 13+.
    cat >"$out" <<EOF
[binaries]
c = '$TOOLBIN/$pfx-gcc'
cpp = '$TOOLBIN/$pfx-g++'
ar = '$TOOLBIN/$pfx-ar'
strip = '$TOOLBIN/$pfx-strip'
windres = '$TOOLBIN/$pfx-windres'

[built-in options]
cpp_args = ['-include', 'cstdint']

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'windows'
cpu_family = '$fam'
cpu = '$cpu'
endian = 'little'
EOF
}

verify_meson_options() {
    local o
    for o in enable_tests build_id; do
        grep -q "^option('$o'" "$DXVK_SRC/meson_options.txt" || die "в dxvk/meson_options.txt нет опции $o"
    done
}

stage_dxvk() {
    if [ "$WITH_DXVK" = 0 ]; then info "пропущено (--no-dxvk)"; return 0; fi
    setup_build_env
    [ -f "$DXVK_SRC/meson.build" ] || die "нет исходников DXVK: $DXVK_SRC"
    verify_meson_options
    [ -x "$TOOLBIN/meson" ] || die "нет meson — запустите ./deps.sh"
    # Наши патчи к исходникам DXVK (engine/patches/dxvk/*.patch) — для нового mingw-w64.
    local p
    for p in "$ENGINE_DIR"/patches/dxvk/*.patch; do
        [ -f "$p" ] || continue
        if patch -d "$DXVK_SRC" -p1 -R --dry-run -s -f <"$p" >/dev/null 2>&1; then
            continue    # уже применён
        fi
        patch -d "$DXVK_SRC" -p1 -s -f <"$p" || die "не удалось применить $(basename "$p")"
        info "применён патч $(basename "$p")"
    done
    local bits dest
    rm -rf "$DXVK_BUILD"
    mkdir -p "$DXVK_BUILD"
    for bits in 64 32; do
        write_dxvk_cross "$bits" "$DXVK_BUILD/cross-win$bits.txt"
        # Как dxvk/package-release.sh (его использует CI CodeWeavers, dxvk/cxlab/build.yml):
        # release, --strip, bindir/libdir = x64/x32, без тестов.
        logrun dxvk meson setup "$DXVK_BUILD/build.$bits" "$DXVK_SRC" \
            --cross-file "$DXVK_BUILD/cross-win$bits.txt" \
            --buildtype release \
            --prefix "$DXVK_BUILD/install" \
            --bindir "x$bits" \
            --libdir "x$bits" \
            --strip \
            -Denable_tests=false \
            -Dbuild_id=false
        logrun dxvk ninja -C "$DXVK_BUILD/build.$bits" -j"$JOBS" install
    done
    # Раскладка onwin: lib/dxvk/{i386-windows,x86_64-windows} — та же схема <arch>-windows, что у
    # остальных бэкендов (Graphics.swift). Ставим и dxgi.dll из DXVK (штатная связка DXVK: его d3d11
    # работает с его dxgi).
    rm -rf "$DIST/lib/dxvk"
    for bits in 64 32; do
        if [ "$bits" = 64 ]; then dest="$DIST/lib/dxvk/x86_64-windows"; else dest="$DIST/lib/dxvk/i386-windows"; fi
        mkdir -p "$dest"
        cp "$DXVK_BUILD/install/x$bits/"*.dll "$dest/"
        mark_dir_builtin "$dest"
    done
    info "DLL: $(cd "$DIST/lib/dxvk/x86_64-windows" && ls *.dll | tr '\n' ' ')"
}

# ------------------------------------------------------------------ dxmt
stage_dxmt() {
    if [ "$WITH_DXMT" = 0 ]; then info "пропущено (--no-dxmt)"; return 0; fi
    setup_build_env
    local tarball="$DOWNLOADS/dxmt-$DXMT_VERSION-builtin.tar.gz" top sub
    info "DXMT $DXMT_VERSION (официальный релиз github.com/3Shain/dxmt)"
    download "$DXMT_URL" "$tarball" "$DXMT_SHA256"
    rm -rf "$DXMT_STAGE"
    mkdir -p "$DXMT_STAGE"
    logrun dxmt tar -xzf "$tarball" -C "$DXMT_STAGE"
    top="$(find "$DXMT_STAGE" -type d -name x86_64-windows | sed -n 1p)"
    [ -n "$top" ] || die "в архиве DXMT нет x86_64-windows/"
    top="$(dirname "$top")"
    [ -f "$top/x86_64-unix/winemetal.so" ] || die "в архиве DXMT нет x86_64-unix/winemetal.so"
    rm -rf "$DIST/lib/dxmt"
    mkdir -p "$DIST/lib/dxmt"
    for sub in x86_64-unix x86_64-windows i386-windows; do
        if [ -d "$top/$sub" ]; then
            cp -R "$top/$sub" "$DIST/lib/dxmt/$sub"
        else
            warn "в DXMT $DXMT_VERSION нет $sub/"
        fi
    done
    for sub in x86_64-windows i386-windows; do
        [ -d "$DIST/lib/dxmt/$sub" ] && mark_dir_builtin "$DIST/lib/dxmt/$sub"
    done
    # winemetal.dll лежит ещё и среди обычных DLL Wine (lib/wine/<arch>-windows),
    # иначе wineboot не создаёт для неё заглушку в C:\windows\system32 и загрузчик Wine её не ищет
    # ("Library winemetal.dll ... not found"). Её unix-часть winemetal.so остаётся в lib/dxmt и
    # подхватывается, когда onwincompat ставит lib/dxmt первым в путь поиска.
    for sub in x86_64-windows i386-windows; do
        [ -f "$DIST/lib/dxmt/$sub/winemetal.dll" ] && cp "$DIST/lib/dxmt/$sub/winemetal.dll" "$DIST/lib/wine/$sub/winemetal.dll"
    done
    echo "$DXMT_VERSION" >"$DIST/lib/dxmt/VERSION"
    info "x86_64-windows: $(cd "$DIST/lib/dxmt/x86_64-windows" && ls *.dll | tr '\n' ' ')"
}

# ------------------------------------------------------------------ addons
# Wine Mono и Gecko лежат распакованными в движке (share/wine/{mono,gecko}).
# Wine (dlls/mscoree/metahost.c, dlls/mshtml) находит их там сам — без окна «Установить Wine Mono?»
# и без скачивания в каждом пространстве. Версии должны точно совпадать с Wine 11.0
# (dlls/mscoree/mscoree_private.h, dlls/appwiz.cpl/addons.c). SHA-256 посчитаны по файлам
# с dl.winehq.org (официальных сумм для .tar.xz там нет).
WINE_MONO_VERSION=10.4.1
WINE_MONO_SHA256=a16606ef0724202e6a6848ece6e0cbba64d11e2f11aefe744af1d93c6d9f99bb
WINE_GECKO_VERSION=2.47.4
WINE_GECKO_X86_SHA256=2cfc8d5c948602e21eff8a78613e1826f2d033df9672cace87fed56e8310afb6
WINE_GECKO_X64_SHA256=fd88fc7e537d058d7a8abf0c1ebc90c574892a466de86706a26d254710a82814

stage_addons() {
    local mono="$DOWNLOADS/wine-mono-$WINE_MONO_VERSION-x86.tar.xz"
    local g32="$DOWNLOADS/wine-gecko-$WINE_GECKO_VERSION-x86.tar.xz"
    local g64="$DOWNLOADS/wine-gecko-$WINE_GECKO_VERSION-x86_64.tar.xz"
    local up="$ENGINE_DIR/sources/upstream" f
    for f in "$mono" "$g32" "$g64"; do
        [ -f "$f" ] || [ ! -f "$up/$(basename "$f")" ] || cp "$up/$(basename "$f")" "$f"
    done
    download "https://dl.winehq.org/wine/wine-mono/$WINE_MONO_VERSION/$(basename "$mono")" "$mono" "$WINE_MONO_SHA256"
    download "https://dl.winehq.org/wine/wine-gecko/$WINE_GECKO_VERSION/$(basename "$g32")" "$g32" "$WINE_GECKO_X86_SHA256"
    download "https://dl.winehq.org/wine/wine-gecko/$WINE_GECKO_VERSION/$(basename "$g64")" "$g64" "$WINE_GECKO_X64_SHA256"
    [ -d "$DIST/share/wine" ] || die "нет $DIST/share/wine — сначала этап wine-install"
    rm -rf "$DIST/share/wine/mono" "$DIST/share/wine/gecko"
    mkdir -p "$DIST/share/wine/mono" "$DIST/share/wine/gecko"
    tar -xJf "$mono" -C "$DIST/share/wine/mono"
    tar -xJf "$g32" -C "$DIST/share/wine/gecko"
    tar -xJf "$g64" -C "$DIST/share/wine/gecko"
    check_addons || die "Wine Mono / Gecko распаковались не туда (ожидались wine-mono-$WINE_MONO_VERSION, wine-gecko-$WINE_GECKO_VERSION-x86_64)"
    info "share/wine/mono: $(ls "$DIST/share/wine/mono" | tr '\n' ' ')"
    info "share/wine/gecko: $(ls "$DIST/share/wine/gecko" | tr '\n' ' ')"
}

# ------------------------------------------------------------------ bundle
# Кладём в lib/external все не-системные dylib, которые нужны Wine:
#  * библиотеки, которые Wine загружает dlopen()'ом по soname (SONAME_LIB* в config.h:
#    libfreetype.6.dylib, libgnutls.30.dylib, libSDL2-2.0.0.dylib, libMoltenVK.dylib, ...).
#    WineRunner.swift ставит DYLD_FALLBACK_LIBRARY_PATH=<движок>/lib/external:<движок>/lib,
#    так что dlopen("libfreetype.6.dylib") находит нашу копию;
#  * всё, на что они и модули Wine ссылаются из /usr/local или /opt/homebrew (рекурсивно).
# Ссылки переписываются на @loader_path/<относительный путь>/<имя>, id библиотек —
# на @rpath/<имя>. Движок не зависит от Homebrew и переносим.

EXT=""
QUEUE=""
SRCMAP=""

is_foreign() {
    case "$1" in "$X86_PREFIX"/*|"$ARM_PREFIX"/*|/usr/local/*|/opt/local/*) return 0 ;; *) return 1 ;; esac
}

srcmap_get() { awk -F '\t' -v k="$1" '$1 == k { print $2; exit }' "$SRCMAP"; }

# bundle_lib <исходный путь> — копирует в lib/external (если ещё нет); печатает имя.
bundle_lib() {
    local src="$1" name real
    name="$(basename "$src")"
    if [ ! -e "$EXT/$name" ]; then
        real="$(abspath "$src")"
        [ -f "$real" ] || die "не найден $src"
        cp "$real" "$EXT/$name"
        chmod u+w "$EXT/$name"
        install_name_tool -id "@rpath/$name" "$EXT/$name" 2>>"$LOGS/bundle.log"
        printf '%s\t%s\n' "$EXT/$name" "$real" >>"$SRCMAP"
        echo "$EXT/$name" >>"$QUEUE"
        echo "    + $name  ← $real" >>"$LOGS/bundle.log"
    fi
    echo "$name"
}

# find_in_brew <имя dylib> — оригинал в x86_64-Homebrew или пусто.
find_in_brew() {
    local name="$1" cand
    if [ -f "$X86_PREFIX/lib/$name" ]; then echo "$X86_PREFIX/lib/$name"; return 0; fi
    for cand in "$X86_PREFIX"/opt/*/lib/"$name"; do
        if [ -f "$cand" ]; then echo "$cand"; return 0; fi
    done
    return 0
}

# resolve_dep <ссылка> <каталог исходника|пусто> <каталог файла> — путь к файлу в Homebrew или пусто.
resolve_dep() {
    local dep="$1" srcdir="$2" filedir="$3" cand rest
    if is_foreign "$dep"; then echo "$dep"; return 0; fi
    if [ -z "$srcdir" ]; then
        # Файл Wine, который уже обрабатывали при прошлом запуске этапа: ссылка уже наша
        # (@loader_path/../../external/libX.dylib), а lib/external пересоздан — ищем оригинал.
        case "$dep" in
            @loader_path/*)
                rest="${dep#@loader_path/}"
                case "$rest" in
                    *external/*)
                        [ -e "$filedir/$rest" ] || find_in_brew "$(basename "$rest")" ;;
                esac ;;
            # Модули Wine, слинкованные с библиотеками из x86_64-libs (winegstreamer.so →
            # @rpath/libgstreamer-1.0.0.dylib…): у них нет LC_RPATH, ссылку надо переписать на
            # lib/external. Свои @rpath/ntdll.so, winemac.so в x86_64-libs нет — остаются как есть.
            @rpath/*)
                rest="${dep#@rpath/}"
                [ -e "$filedir/$rest" ] || [ -e "$DIST/lib/wine/x86_64-unix/$rest" ] || find_in_brew "$rest" ;;
        esac
        return 0
    fi
    case "$dep" in
        @loader_path/*)
            cand="$srcdir/${dep#@loader_path/}"
            if [ -f "$cand" ]; then
                cand="$(abspath "$cand")"
                if is_foreign "$cand"; then echo "$cand"; fi
            fi ;;
        @rpath/*)
            rest="${dep#@rpath/}"
            for cand in "$srcdir/$rest" "$srcdir/../lib/$rest" "$X86_PREFIX/lib/$rest"; do
                if [ -f "$cand" ]; then
                    cand="$(abspath "$cand")"
                    is_foreign "$cand" && echo "$cand"
                    return 0
                fi
            done ;;
    esac
    return 0
}

fix_refs() {
    local f="$1" own src srcdir dep res name rel ref changed=0
    own="$(otool -D "$f" 2>/dev/null | sed -n '2p')"
    src="$(srcmap_get "$f")"
    srcdir=""
    [ -n "$src" ] && srcdir="$(dirname "$src")"
    rel="$(relpath "$EXT" "$(dirname "$f")")"
    while IFS= read -r dep; do
        [ -n "$dep" ] || continue
        [ "$dep" = "$own" ] && continue
        res="$(resolve_dep "$dep" "$srcdir" "$(dirname "$f")")"
        [ -n "$res" ] || continue
        name="$(bundle_lib "$res")"
        if [ "$rel" = "." ]; then ref="@loader_path/$name"; else ref="@loader_path/$rel/$name"; fi
        if [ "$dep" != "$ref" ]; then
            install_name_tool -change "$dep" "$ref" "$f" 2>>"$LOGS/bundle.log"
            changed=1
        fi
    done <<EOF
$(otool -L "$f" | tail -n +2 | awk '{print $1}')
EOF
    if [ "$changed" = 1 ] || [ -n "$src" ]; then
        # install_name_tool портит подпись; ставим ad-hoc подпись заново.
        codesign --force --sign - "$f" >>"$LOGS/bundle.log" 2>&1 || warn "не удалось подписать $f"
    fi
}

stage_bundle() {
    setup_build_env
    EXT="$DIST/lib/external"
    QUEUE="$BUILD/bundle.queue"
    SRCMAP="$BUILD/bundle.srcmap"
    rm -rf "$EXT" "$DIST/lib/gstreamer-1.0"
    mkdir -p "$EXT"
    : >"$QUEUE"
    : >"$SRCMAP"

    # 1. MoltenVK
    check_moltenvk || die "нет MoltenVK — сначала этап moltenvk"
    bundle_lib "$MVK_STAGE/lib/libMoltenVK.dylib" >/dev/null

    # 2. Библиотеки, которые Wine грузит dlopen()'ом по soname.
    local h="$WINE_BUILD/include/config.h" so real n=0
    [ -f "$h" ] || die "нет $h — сначала этап wine-configure"
    while IFS= read -r so; do
        [ -n "$so" ] || continue
        [ "$so" = "libMoltenVK.dylib" ] && continue
        if [ -f "$X86_PREFIX/lib/$so" ]; then
            bundle_lib "$X86_PREFIX/lib/$so" >/dev/null
            n=$((n + 1))
            case "$so" in
                libSDL2-2.0*)
                    # sdl2-compat загружает SDL3 через dlopen("@loader_path/libSDL3.dylib"), затем
                    # dlopen("libSDL3.dylib") — otool эту связь не видит, а имя без «.0».
                    # Без libSDL3.dylib рядом sdl2-compat показывает модальное окно «Cannot continue».
                    if [ -f "$X86_PREFIX/lib/libSDL3.0.dylib" ]; then
                        bundle_lib "$X86_PREFIX/lib/libSDL3.0.dylib" >/dev/null
                        ln -sf libSDL3.0.dylib "$EXT/libSDL3.dylib"
                    fi ;;
            esac
        else
            echo "    = $so — системная, не копирую" >>"$LOGS/bundle.log"
        fi
    done <<EOF
$(sed -n 's/^#define SONAME_LIB[A-Z0-9_]* "\(.*\)"$/\1/p' "$h")
EOF
    info "библиотек по soname: $n (+ MoltenVK)"

    # 3. Плагины GStreamer (если winegstreamer собран с GStreamer).
    local gst_so="$DIST/lib/wine/x86_64-unix/winegstreamer.so" gst_deps="" p copied=0
    [ -f "$gst_so" ] && gst_deps="$(otool -L "$gst_so" 2>/dev/null || true)"
    if case "$gst_deps" in *libgstreamer-1.0*) true ;; *) false ;; esac; then
        mkdir -p "$DIST/lib/gstreamer-1.0"
        for p in $GST_PLUGINS; do
            if [ -f "$X86_PREFIX/lib/gstreamer-1.0/libgst$p.dylib" ]; then
                real="$(abspath "$X86_PREFIX/lib/gstreamer-1.0/libgst$p.dylib")"
                cp "$real" "$DIST/lib/gstreamer-1.0/"
                chmod u+w "$DIST/lib/gstreamer-1.0/libgst$p.dylib"
                printf '%s\t%s\n' "$DIST/lib/gstreamer-1.0/libgst$p.dylib" "$real" >>"$SRCMAP"
                copied=$((copied + 1))
            else
                warn "плагин GStreamer $p не найден в $X86_PREFIX/lib/gstreamer-1.0"
            fi
        done
        info "плагинов GStreamer: $copied"
    fi

    # 4. Все Mach-O движка — в очередь; затем обходим очередь (bundle_lib дописывает в неё).
    local f d
    for d in "$DIST/bin" "$DIST/lib/wine/x86_64-unix" "$DIST/lib/dxmt/x86_64-unix" "$DIST/lib/gstreamer-1.0"; do
        [ -d "$d" ] || continue
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            is_macho "$f" && echo "$f" >>"$QUEUE"
        done <<EOF
$(find "$d" -type f)
EOF
    done
    local i=1
    while :; do
        f="$(sed -n "${i}p" "$QUEUE")"
        [ -n "$f" ] || break
        fix_refs "$f"
        i=$((i + 1))
    done
    info "в lib/external: $(ls "$EXT" | wc -l | tr -d ' ') dylib, $(du -sh "$EXT" | awk '{print $1}')"
}

# ------------------------------------------------------------------ manifest
json_escape() { printf '%s' "$1" | perl -pe 's/\\/\\\\/g; s/"/\\"/g'; }

stage_manifest() {
    local wine_version dxvk_version mvk_version dxmt_version built
    wine_version="$(sed -n 's/^Wine version //p' "$WINE_SRC/VERSION")"
    [ -n "$wine_version" ] || wine_version="unknown"
    dxvk_version=""
    [ -f "$DIST/lib/dxvk/x86_64-windows/d3d11.dll" ] && dxvk_version="$(cat "$DXVK_SRC/RELEASE" 2>/dev/null || echo '?')-cx"
    dxmt_version="$(cat "$DIST/lib/dxmt/VERSION" 2>/dev/null || true)"
    mvk_version="$(cat "$MVK_STAGE/VERSION" 2>/dev/null || echo '?')"
    built="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    # Поля id/displayName/wineVersion/crossoverSourceVersion/built читает Engine.Info;
    # components — справочно (JSONDecoder лишние ключи игнорирует).
    cat >"$DIST/onwin-engine.json" <<EOF
{
  "id": "$(json_escape "$ENGINE_ID")",
  "displayName": "Wine $(json_escape "$wine_version") (CrossOver $CX_SOURCE_VERSION)",
  "wineVersion": "$(json_escape "$wine_version")",
  "crossoverSourceVersion": "$CX_SOURCE_VERSION",
  "built": "$built",
  "components": {
    "wine": "$(json_escape "$wine_version")",
    "dxvk": "$(json_escape "$dxvk_version")",
    "dxmt": "$(json_escape "$dxmt_version")",
    "moltenvk": "$(json_escape "$mvk_version")",
    "gstreamer": $([ -d "$DIST/lib/gstreamer-1.0" ] && echo true || echo false)
  }
}
EOF
    info "$DIST/onwin-engine.json"
}

# ------------------------------------------------------------------ verify
stage_verify() {
    setup_build_env
    local problems=0 f t leftovers=""
    must() { if [ ! -e "$DIST/$1" ]; then warn "нет $1"; problems=$((problems + 1)); fi; }
    must bin/wine
    must bin/wineserver
    must lib/wine/x86_64-unix/ntdll.so
    must lib/wine/x86_64-unix/cxcompatdb.so
    must lib/wine/x86_64-unix/winemac.so
    must lib/wine/x86_64-unix/winevulkan.so
    must lib/wine/x86_64-windows/ntdll.dll
    must lib/wine/i386-windows/ntdll.dll
    must lib/wine/x86_64-windows/wow64.dll
    must lib/external/libMoltenVK.dylib
    # sdl2-compat без libSDL3.dylib рядом показывает модальное окно и не работает.
    if [ -f "$DIST/lib/external/libSDL2-2.0.0.dylib" ] && [ ! -e "$DIST/lib/external/libSDL3.dylib" ]; then
        warn "нет lib/external/libSDL3.dylib (нужен sdl2-compat)"; problems=$((problems + 1))
    fi
    must share/wine
    must onwin-engine.json
    [ "$WITH_DXVK" = 1 ] && must lib/dxvk/x86_64-windows/d3d11.dll
    [ "$WITH_DXVK" = 1 ] && must lib/dxvk/i386-windows/d3d11.dll
    [ "$WITH_DXMT" = 1 ] && must lib/dxmt/x86_64-unix/winemetal.so
    [ "$WITH_DXMT" = 1 ] && must lib/dxmt/x86_64-windows/d3d11.dll

    t="$(file -b "$DIST/lib/wine/x86_64-unix/ntdll.so" 2>/dev/null || true)"
    case "$t" in *x86_64*) ;; *) warn "ntdll.so не x86_64: $t"; problems=$((problems + 1)) ;; esac

    # Метки встроенных DLL.
    for f in "$DIST"/lib/dxvk/*/*.dll "$DIST"/lib/dxmt/*/*.dll; do
        [ -f "$f" ] || continue
        if ! has_builtin_marker "$f"; then warn "без метки Wine builtin: ${f#$DIST/}"; problems=$((problems + 1)); fi
    done

    # Не осталось ссылок на Homebrew, x86_64-libs, каталоги сборки и т.п.: допустимы только
    # системные пути и @loader_path/@rpath на файлы, которые лежат в самом движке.
    local dep own fdir n
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        is_macho "$f" || continue
        own="$(otool -D "$f" 2>/dev/null | sed -n '2p')"
        fdir="$(dirname "$f")"
        while IFS= read -r dep; do
            [ -n "$dep" ] || continue
            [ "$dep" = "$own" ] && continue
            case "$dep" in
                /usr/lib/*|/System/*) ;;
                @loader_path/*) [ -e "$fdir/${dep#@loader_path/}" ] || leftovers="$leftovers ${f#$DIST/}→$dep" ;;
                # @rpath/ntdll.so, @rpath/winemac.so у winemetal.so (DXMT) и т.п. — модули Wine,
                # которые к этому моменту уже загружены; dyld находит их по install name.
                @rpath/*) n="${dep#@rpath/}"
                          [ -e "$fdir/$n" ] || [ -e "$DIST/lib/external/$n" ] || [ -e "$DIST/lib/wine/x86_64-unix/$n" ] ||
                              leftovers="$leftovers ${f#$DIST/}→$dep" ;;
                *) leftovers="$leftovers ${f#$DIST/}→$dep" ;;
            esac
        done <<DEPS
$(otool -L "$f" | tail -n +2 | awk '{print $1}')
DEPS
    done <<EOF
$(find "$DIST/bin" "$DIST/lib" -type f \( -name '*.so' -o -name '*.dylib' -o -path "$DIST/bin/*" \))
EOF
    if [ -n "$leftovers" ]; then
        warn "ссылки на библиотеки вне движка или на отсутствующие файлы:$leftovers"
        problems=$((problems + 1))
    fi

    # Wine запускается (без префикса, только версия).
    local v
    if v="$(DYLD_FALLBACK_LIBRARY_PATH="$DIST/lib/external:$DIST/lib:/usr/lib" WINEDEBUG=-all "$DIST/bin/wine" --version 2>&1)"; then
        info "bin/wine --version → $v"
    else
        warn "bin/wine --version не сработал: $v"
        problems=$((problems + 1))
    fi

    info "размер движка: $(du -sh "$DIST" | awk '{print $1}')"
    [ "$problems" = 0 ] || die "проверка нашла проблем: $problems"
    info "движок в порядке: $DIST"
}

# ------------------------------------------------------------------ install
find_swift() {
    local dev
    dev="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
    [ -n "$dev" ] && { [ -x "$dev/usr/bin/swift" ] || [ -x "$dev/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" ]; }
}

stage_install() {
    local ctl="" native=""
    [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ] && native="/usr/bin/arch -arm64"
    for ctl in "$APP_DIR/.build/release/onwinctl" "$APP_DIR/.build/debug/onwinctl"; do
        [ -x "$ctl" ] && break
        ctl=""
    done
    if [ -z "$ctl" ]; then
        find_swift || die "нет onwinctl и нет swift. Соберите приложение (cd app && swift build -c release) и повторите: ./build.sh install"
        info "собираю onwinctl (swift build -c release)"
        # Swift — родной arm64, не под Rosetta.
        logrun install env PATH=/usr/bin:/bin:/usr/sbin:/sbin $native /usr/bin/swift build -c release --package-path "$APP_DIR" --product onwinctl
        ctl="$APP_DIR/.build/release/onwinctl"
        [ -x "$ctl" ] || die "swift build не создал $ctl"
    fi
    logrun install $native "$ctl" engine-install "$DIST"
    tail -n 1 "$LOGS/install.log" | sed 's/^/    /'
}

# ------------------------------------------------------------------ действия
show_status() {
    local s mark
    say "Состояние сборки ($DIST)"
    for s in $ALL_STAGES; do
        if stage_ready "$s"; then mark="готово  "; else mark="не готово"; fi
        printf '    %-16s %s\n' "$s" "$mark"
    done
}

safe_rm() { # удаляет только внутри engine/
    local p
    for p in "$@"; do
        case "$p" in
            "$ENGINE_DIR"/?*) rm -rf "$p" ;;
            *) die "отказываюсь удалять $p (вне $ENGINE_DIR)" ;;
        esac
    done
}

[ "$ACTION" = status ] || acquire_lock

case "$ACTION" in
    status) show_status; exit 0 ;;
    clean)
        say "Удаляю промежуточные файлы (загрузки сохраняю)"
        safe_rm "$WINE_BUILD" "$DXVK_BUILD" "$MVK_STAGE" "$DXMT_STAGE" "$TMPDIR_BUILD" "$STAMPS" "$TOOLBIN" \
                "$BUILD/bundle.queue" "$BUILD/bundle.srcmap"
        exit 0 ;;
    distclean)
        # Удаляем только своё: в engine/build могут лежать результаты других скриптов
        # (например, build-libs.sh: libs-work/, x86_64-libs/).
        say "Удаляю файлы build.sh в engine/build, загрузки и $DIST"
        safe_rm "$WINE_BUILD" "$DXVK_BUILD" "$MVK_STAGE" "$DXMT_STAGE" "$TMPDIR_BUILD" "$STAMPS" "$TOOLBIN" \
                "$DOWNLOADS" "$BUILD/bundle.queue" "$BUILD/bundle.srcmap"
        for s in $ALL_STAGES install; do rm -f "$LOGS/$s.log"; done
        case "$DIST" in "$ENGINE_DIR"/*) safe_rm "$DIST" ;; *) warn "$DIST вне engine/ — удалите вручную" ;; esac
        exit 0 ;;
esac

STAGES="${REQUESTED:-$ALL_STAGES}"
if [ "$DO_INSTALL" = 1 ]; then
    case " $STAGES " in *" install "*) ;; *) STAGES="$STAGES install" ;; esac
fi
# toolchain нужен любому этапу (он создаёт toolbin).
case " $STAGES " in *" toolchain "*) ;; *) STAGES="toolchain $STAGES" ;; esac

say "onwin: сборка движка $ENGINE_ID (исходники CrossOver $CX_SOURCE_VERSION)"
info "результат: $DIST"
info "журналы:   $LOGS"
info "потоков:   $JOBS"
START_ALL=$(date +%s)

for s in $STAGES; do
    case "$s" in
        toolchain)      run_stage toolchain      "Проверяю инструменты и готовлю toolbin" ;;
        moltenvk)       run_stage moltenvk       "MoltenVK (Vulkan поверх Metal)" ;;
        wine-configure) run_stage wine-configure "Конфигурирую Wine (WoW64: i386 + x86_64)" ;;
        wine-build)     run_stage wine-build     "Собираю Wine" ;;
        wine-install)   run_stage wine-install   "Устанавливаю Wine в $DIST" ;;
        compat)         run_stage compat         "Собираю cxcompatdb.so (onwincompat)" ;;
        dxvk)           run_stage dxvk           "Собираю DXVK 1.10.3 (форк CodeWeavers)" ;;
        dxmt)           run_stage dxmt           "Ставлю DXMT $DXMT_VERSION" ;;
        addons)         run_stage addons         "Встраиваю Wine Mono $WINE_MONO_VERSION и Wine Gecko $WINE_GECKO_VERSION" ;;
        bundle)         run_stage bundle         "Собираю библиотеки в lib/external и делаю движок переносимым" ;;
        manifest)       run_stage manifest       "Пишу onwin-engine.json" ;;
        verify)         run_stage verify         "Проверяю результат" ;;
        install)        run_stage install        "Устанавливаю движок через onwinctl engine-install" ;;
    esac
done

ELAPSED=$(( $(date +%s) - START_ALL ))
say "Готово за $((ELAPSED / 60)) мин $((ELAPSED % 60)) с. Движок: $DIST"
if [ "$DO_INSTALL" = 0 ]; then
    info "Установить в onwin: ./build.sh install   (или onwinctl engine-install \"$DIST\")"
    info "Для разработки без установки: ONWIN_ENGINE=\"$DIST\""
fi
