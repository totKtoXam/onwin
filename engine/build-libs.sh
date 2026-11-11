#!/bin/bash
# Сборка x86_64-библиотек, которые Wine загружает во время работы:
#   * gmp → nettle → gnutls, freetype;
#   * SDL3 + sdl2-compat (libSDL2-2.0.0.dylib поверх SDL3) — геймпады (winebus.sys);
#   * libffi, pcre2, proxy-libintl → glib → GStreamer (core, base, good, bad, ugly) — видео и звук
#     в играх через winegstreamer (Media Foundation / DirectShow). Плагины — только нужные winegstreamer
#     (applemedia = аппаратное декодирование H.264/HEVC через VideoToolbox, osxaudio/atdec = AAC/MP3
#     через AudioToolbox; FFmpeg/gst-libav не нужен).
# Берутся последние стабильные версии с официальных сайтов, с проверкой SHA-256.
# Результат: engine/build/x86_64-libs/{include,lib,lib/gstreamer-1.0}. Intel-версия Homebrew не нужна:
# инструменты (pkgconf, meson, ninja, cmake…) — из обычного Homebrew для Apple Silicon, код
# компилируется clang -arch x86_64; программы x86_64, которые запускаются во время сборки, работают
# через Rosetta 2.
# Каждый шаг повторно не выполняется: метка build/libs-work/.done-<имя>-<версия> хранит версии
# зависимостей, так что обновление, например, glib пересоберёт и GStreamer.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
UPSTREAM="$HERE/sources/upstream"
WORK="$HERE/build/libs-work"
PREFIX="$HERE/build/x86_64-libs"
LOGS="$HERE/build/logs"
JOBS="$(sysctl -n hw.ncpu)"
MACOS_MIN="11.0"
mkdir -p "$UPSTREAM" "$WORK" "$PREFIX" "$LOGS"

# name|version|file|url|sha256
LIBS=(
  "gmp|6.3.0|gmp-6.3.0.tar.xz|https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz|a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898"
  "nettle|4.0|nettle-4.0.tar.gz|https://ftp.gnu.org/gnu/nettle/nettle-4.0.tar.gz|3addbc00da01846b232fb3bc453538ea5468da43033f21bb345cb1e9073f5094"
  "gnutls|3.8.13|gnutls-3.8.13.tar.xz|https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.13.tar.xz|ffed8ec1bf09c2426d4f14aae377de4753b53e537d685e604e99a8b16ca9c97e"
  "freetype|2.15.0|freetype-2.15.0.tar.xz|https://download.savannah.gnu.org/releases/freetype/freetype-2.15.0.tar.xz|93cd47eb719c325107f2d3cf087d06299e944c3b48a40b55537302304dea1dd5"
)
# SDL: github.com/libsdl-org/SDL и github.com/libsdl-org/sdl2-compat (SHA-256 — как в релизах GitHub).
SDL3="SDL3|3.4.20|SDL3-3.4.20.tar.gz|https://github.com/libsdl-org/SDL/releases/download/release-3.4.20/SDL3-3.4.20.tar.gz|f3bb06f55bed9557227a700af2ea62e49497ebdf58037732a731a5fb3ef8581f"
SDL2COMPAT="sdl2-compat|2.32.74|sdl2-compat-2.32.74.tar.gz|https://github.com/libsdl-org/sdl2-compat/releases/download/release-2.32.74/sdl2-compat-2.32.74.tar.gz|ec68abde77e2e459c8abc4f9587b8976b5d2a657b2bfda2fb3a079b0f8924588"
# Зависимости glib.
LIBFFI="libffi|3.8.0|libffi-3.8.0.tar.gz|https://github.com/libffi/libffi/releases/download/v3.8.0/libffi-3.8.0.tar.gz|7da3e2d9a171eb0a038f592ecad3ff2bb2550f3496d87b3b29ad0cf4430c0db4"
PCRE2="pcre2|10.49|pcre2-10.49.tar.bz2|https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.49/pcre2-10.49.tar.bz2|53c156e1ba416a20da8e65395daa132da0d80e76910424caca3fcdae7831d384"
# proxy-libintl — заглушка libintl, которую glib сам берёт как subproject (хэш совпадает
# с subprojects/proxy-libintl.wrap из glib); собирается вместе с glib, отдельного шага нет.
PROXY_LIBINTL="proxy-libintl|0.5|proxy-libintl-0.5.tar.gz|https://github.com/frida/proxy-libintl/archive/refs/tags/0.5.tar.gz|f7a1cbd7579baaf575c66f9d99fb6295e9b0684a28b095967cfda17857595303"
# glib: download.gnome.org (SHA-256 — из glib-*.sha256sum).
GLIB="glib|2.90.1|glib-2.90.1.tar.xz|https://download.gnome.org/sources/glib/2.90/glib-2.90.1.tar.xz|93c941aa17d5eb1d53fe838365f29a8b4e539c222a256d974ec8f30fc413e396"
# GStreamer: gstreamer.freedesktop.org/src (SHA-256 — из *.tar.xz.sha256sum).
GST_VERSION="1.28.9"
GST_URL="https://gstreamer.freedesktop.org/src"
GSTREAMER="gstreamer|$GST_VERSION|gstreamer-$GST_VERSION.tar.xz|$GST_URL/gstreamer/gstreamer-$GST_VERSION.tar.xz|6dbf744f583131a34845cc641e803843766a9ba80ce00378a9043fd6d8d5fb38"
GST_BASE="gst-plugins-base|$GST_VERSION|gst-plugins-base-$GST_VERSION.tar.xz|$GST_URL/gst-plugins-base/gst-plugins-base-$GST_VERSION.tar.xz|c1fda668b520e6aef763c0eb962c032c9fe52bce322e8b00c69b4e9e847bddc1"
GST_GOOD="gst-plugins-good|$GST_VERSION|gst-plugins-good-$GST_VERSION.tar.xz|$GST_URL/gst-plugins-good/gst-plugins-good-$GST_VERSION.tar.xz|e518cd97483706a252e95e60312a22d23dec6f5e7673af6f5bde719c3a9ca7f4"
GST_BAD="gst-plugins-bad|$GST_VERSION|gst-plugins-bad-$GST_VERSION.tar.xz|$GST_URL/gst-plugins-bad/gst-plugins-bad-$GST_VERSION.tar.xz|4a4e0b7bf84f868378c48f143a7ac3a98923b488a5b74f1a35ba46bc3c43f6b1"
GST_UGLY="gst-plugins-ugly|$GST_VERSION|gst-plugins-ugly-$GST_VERSION.tar.xz|$GST_URL/gst-plugins-ugly/gst-plugins-ugly-$GST_VERSION.tar.xz|550a52536962186f5488e06b5c08f31ae0f18400aee32a3385156d31cb4b1189"

# Плагины, которые должны получиться: демультиплексоры, парсеры и конвертеры, которые использует
# winegstreamer, + applemedia (VideoToolbox) + osxaudio. В GStreamer ≥ 1.26 декодер AudioToolbox
# (atdec: AAC, MP3, ALAC…) перенесён из applemedia (-bad) в osxaudio (-good). Без osxaudio decodebin
# не найдёт декодер AAC.
GST_PLUGINS="applemedia asf audioconvert audioparsers audioresample avi coreelements deinterlace id3demux isomp4 opengl osxaudio playback typefindfunctions videoconvertscale videofilter videoparsersbad wavparse"

export CC="clang -arch x86_64"
export CXX="clang++ -arch x86_64"
export CFLAGS="-O2 -mmacosx-version-min=$MACOS_MIN"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-arch x86_64 -mmacosx-version-min=$MACOS_MIN -L$PREFIX/lib -Wl,-headerpad_max_install_names"
export CPPFLAGS="-I$PREFIX/include"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
[ -d /opt/homebrew/bin ] && export PATH="/opt/homebrew/bin:$PATH"
# bison и flex в Homebrew — keg-only; системный bison 2.3 слишком стар для GStreamer (нужен ≥ 2.4).
for d in /opt/homebrew/opt/flex/bin /opt/homebrew/opt/bison/bin; do [ -d "$d" ] && export PATH="$d:$PATH"; done
HOST="--host=x86_64-apple-darwin --build=aarch64-apple-darwin"

need_tool() { # need_tool <программа> <формула Homebrew>
    command -v "$1" >/dev/null 2>&1 && return 0
    echo "✗ Нет $1. Установите: HOMEBREW_NO_AUTO_UPDATE=1 brew install $2" >&2
    exit 1
}
need_tool pkg-config pkgconf
need_tool meson meson
need_tool ninja ninja
need_tool cmake cmake

# Cross-файл meson для x86_64-darwin: meson не понимает --host, а Rosetta запускает x86_64-программы,
# поэтому needs_exe_wrapper = false (проверки configure и glib-mkenums/glib-compile-* работают).
CROSS="$WORK/x86_64-darwin.ini"
cat >"$CROSS" <<EOF
[constants]
arch = ['-arch', 'x86_64']
min = ['-mmacosx-version-min=$MACOS_MIN']

[binaries]
c = ['clang'] + arch
cpp = ['clang++'] + arch
objc = ['clang'] + arch
objcpp = ['clang++'] + arch
ar = 'ar'
strip = 'strip'
pkg-config = '$(command -v pkg-config)'
cmake = '$(command -v cmake)'
glib-mkenums = '$PREFIX/bin/glib-mkenums'
glib-genmarshal = '$PREFIX/bin/glib-genmarshal'
glib-compile-resources = '$PREFIX/bin/glib-compile-resources'
glib-compile-schemas = '$PREFIX/bin/glib-compile-schemas'
gdbus-codegen = '$PREFIX/bin/gdbus-codegen'

[built-in options]
c_args = min + ['-I$PREFIX/include']
cpp_args = min + ['-I$PREFIX/include']
objc_args = min + ['-I$PREFIX/include']
objcpp_args = min + ['-I$PREFIX/include']
c_link_args = arch + min + ['-L$PREFIX/lib', '-Wl,-headerpad_max_install_names']
cpp_link_args = arch + min + ['-L$PREFIX/lib', '-Wl,-headerpad_max_install_names']
objc_link_args = arch + min + ['-L$PREFIX/lib', '-Wl,-headerpad_max_install_names']
objcpp_link_args = arch + min + ['-L$PREFIX/lib', '-Wl,-headerpad_max_install_names']

[properties]
needs_exe_wrapper = false
pkg_config_libdir = ['$PREFIX/lib/pkgconfig']

[host_machine]
system = 'darwin'
subsystem = 'macos'
kernel = 'xnu'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

fetch() { # fetch <entry> → prints source dir
    local name version file url sha
    IFS='|' read -r name version file url sha <<<"$1"
    if [ ! -f "$UPSTREAM/$file" ]; then
        echo "  ↓ $file" >&2
        curl -fL --retry 5 -o "$UPSTREAM/$file.part" "$url" >&2
        mv "$UPSTREAM/$file.part" "$UPSTREAM/$file"
    fi
    verify_sha "$UPSTREAM/$file" "$sha"
    rm -rf "$WORK/$name"; mkdir -p "$WORK/$name"
    tar -xf "$UPSTREAM/$file" -C "$WORK/$name" --strip-components=1
    echo "$WORK/$name"
}

verify_sha() { # verify_sha <файл> <sha256>
    local got; got="$(shasum -a 256 "$1" | awk '{print $1}')"
    if [ "$got" != "$2" ]; then echo "✗ Контрольная сумма $(basename "$1") не совпала ($got)" >&2; exit 1; fi
}

download() { # download <entry> — только скачать и проверить (для subproject'ов)
    local name version file url sha
    IFS='|' read -r name version file url sha <<<"$1"
    if [ ! -f "$UPSTREAM/$file" ]; then
        echo "  ↓ $file" >&2
        curl -fL --retry 5 -o "$UPSTREAM/$file.part" "$url" >&2
        mv "$UPSTREAM/$file.part" "$UPSTREAM/$file"
    fi
    verify_sha "$UPSTREAM/$file" "$sha"
}

# Подпись шага: версии зависимостей (с их подписями), чтобы обновление зависимости
# пересобирало зависящие от неё библиотеки.
dep_sig() { # dep_sig <entry>...
    local e name version sig=""
    for e in "$@"; do
        IFS='|' read -r name version _ <<<"$e"
        sig="$sig $name-$version[$(cat "$WORK/.done-$name-$version" 2>/dev/null || true)]"
    done
    printf '%s' "${sig# }"
}

is_macho() { case "$(file -b "$1" 2>/dev/null)" in *Mach-O*) return 0 ;; *) return 1 ;; esac; }

# fix_macho <файл> <rpath> — id → @rpath/<имя из id>, ссылки на $PREFIX/lib → @rpath, свой rpath
# вместо абсолютных (каталоги сборки). Ничего не меняет, если всё уже правильно.
fix_macho() {
    local f="$1" want="$2" changed=0 id dep rp have=0
    id="$(otool -D "$f" 2>/dev/null | sed -n '2p')"
    if [ -n "$id" ] && [ "${id#@rpath/}" = "$id" ]; then
        install_name_tool -id "@rpath/$(basename "$id")" "$f"; changed=1
    fi
    while IFS= read -r dep; do
        [ -n "$dep" ] || continue
        case "$dep" in
            "$PREFIX"/lib/*|"$WORK"/*)
                install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$f"; changed=1 ;;
        esac
    done <<EOF
$(otool -L "$f" | tail -n +2 | awk '{print $1}')
EOF
    while IFS= read -r rp; do
        [ -n "$rp" ] || continue
        if [ "$rp" = "$want" ]; then have=1; continue; fi
        case "$rp" in /*) install_name_tool -delete_rpath "$rp" "$f"; changed=1 ;; esac
    done <<EOF
$(otool -l "$f" | awk '$1 == "cmd" && $2 == "LC_RPATH" { getline; getline; print $2 }')
EOF
    if [ "$have" = 0 ]; then install_name_tool -add_rpath "$want" "$f"; changed=1; fi
    # install_name_tool портит подпись — ставим ad-hoc подпись заново.
    if [ "$changed" = 1 ]; then codesign --force --sign - "$f" >/dev/null 2>&1 || true; fi
}

# Библиотеки должны находиться по @rpath, чтобы движок можно было переносить:
# lib/*.dylib → @loader_path, lib/gstreamer-1.0/* → @loader_path/.., bin/* → @loader_path/../lib,
# libexec/gstreamer-1.0/* → @loader_path/../../lib.
fix_install_names() {
    local f
    for f in "$PREFIX"/lib/*.dylib; do
        [ -f "$f" ] && [ ! -L "$f" ] && fix_macho "$f" "@loader_path"
    done
    for f in "$PREFIX"/lib/gstreamer-1.0/*.dylib "$PREFIX"/lib/gstreamer-1.0/*.so; do
        [ -f "$f" ] && [ ! -L "$f" ] && fix_macho "$f" "@loader_path/.."
    done
    for f in "$PREFIX"/bin/*; do
        [ -f "$f" ] && [ ! -L "$f" ] && is_macho "$f" && fix_macho "$f" "@loader_path/../lib"
    done
    for f in "$PREFIX"/libexec/gstreamer-1.0/*; do
        [ -f "$f" ] && [ ! -L "$f" ] && is_macho "$f" && fix_macho "$f" "@loader_path/../../lib"
    done
    return 0
}

# .pc-файлы: GStreamer и SDL3 на macOS дописывают в Libs «-Wl,-rpath,<префикс>/lib» — тогда в модули
# Wine (winegstreamer.so…) попал бы абсолютный путь к каталогу сборки. Убираем его. И sdl2.pc:
# sdl2-compat ставит sdl2-compat.pc с «Provides: sdl2» — ссылка sdl2.pc нужна pkg-config без Provides.
fix_pkgconfig() {
    local pc
    for pc in "$PREFIX"/lib/pkgconfig/*.pc; do
        [ -f "$pc" ] && [ ! -L "$pc" ] || continue
        if grep -q -e '-Wl,-rpath,' "$pc"; then sed -i '' -E 's/ ?-Wl,-rpath,[^ ]+//g' "$pc"; fi
    done
    if [ -f "$PREFIX/lib/pkgconfig/sdl2-compat.pc" ] && [ ! -e "$PREFIX/lib/pkgconfig/sdl2.pc" ]; then
        ln -s sdl2-compat.pc "$PREFIX/lib/pkgconfig/sdl2.pc"
    fi
    return 0
}

# build <autotools|meson|cmake> <entry> "<зависимости>" [аргументы configure/meson/cmake...]
build() {
    local kind="$1" entry="$2" deps="$3"; shift 3
    local name version sig marker
    IFS='|' read -r name version _ <<<"$entry"
    # shellcheck disable=SC2086
    sig="$(dep_sig $deps)"
    # Параметры сборки (и cross-файл для meson) тоже входят в метку: их изменение пересобирает шаг.
    if [ "${OPTS_IN_SIG:-1}" = 1 ]; then
        sig="${sig:+$sig }opts:$( { printf '%s\n' "$kind" "$@"; if [ "$kind" = meson ]; then cat "$CROSS"; fi; } |
            shasum -a 256 | cut -c1-12)"
    fi
    marker="$WORK/.done-$name-$version"
    if [ -f "$marker" ] && [ "$(cat "$marker")" = "$sig" ]; then echo "• $name $version уже собран"; return; fi
    echo "• Собираю $name $version…"
    local dir; dir="$(fetch "$entry")"
    case "$name" in
        glib)
            # Заглушка libintl — из нашего проверенного архива, без скачивания meson'ом.
            download "$PROXY_LIBINTL"
            mkdir -p "$dir/subprojects/packagecache"
            cp "$UPSTREAM/proxy-libintl-0.5.tar.gz" "$dir/subprojects/packagecache/" ;;
    esac
    set +e
    (
        set -e
        cd "$dir"
        case "$kind" in
            autotools)
                ./configure --prefix="$PREFIX" $HOST --enable-shared --disable-static "$@"
                make -j"$JOBS"
                make install ;;
            meson)
                # Всё для x86_64 задаёт cross-файл; переменные CC/CFLAGS meson отнёс бы к сборочной машине.
                unset CC CXX CFLAGS CXXFLAGS LDFLAGS CPPFLAGS
                meson setup _build --cross-file "$CROSS" --prefix="$PREFIX" --libdir=lib \
                    --buildtype=release -Db_ndebug=if-release --wrap-mode=nodownload \
                    -Ddefault_library=shared "$@"
                meson compile -C _build -j "$JOBS"
                meson install -C _build ;;
            cmake)
                unset CC CXX CFLAGS CXXFLAGS LDFLAGS CPPFLAGS
                cmake -S . -B _build -G Ninja -DCMAKE_BUILD_TYPE=Release \
                    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
                    -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
                    -DCMAKE_PREFIX_PATH="$PREFIX" -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" \
                    -DCMAKE_INSTALL_NAME_DIR=@rpath -DCMAKE_SHARED_LINKER_FLAGS=-Wl,-headerpad_max_install_names \
                    "$@"
                cmake --build _build -j "$JOBS"
                cmake --install _build ;;
        esac
    ) >"$LOGS/lib-$name.log" 2>&1
    local rc=$?
    set -e
    if [ $rc -ne 0 ]; then echo "✗ $name: ошибка, см. $LOGS/lib-$name.log"; tail -30 "$LOGS/lib-$name.log"; exit 1; fi
    # Следующие шаги запускают установленные программы (glib-compile-resources…) — пути чиним сразу.
    fix_install_names
    fix_pkgconfig
    printf '%s' "$sig" >"$marker"
    echo "  ✓ $name $version"
}

# Первые четыре библиотеки: метка — только версия (как было до появления подписей с параметрами).
step() { OPTS_IN_SIG=0 build autotools "$1" "" "${@:2}"; }

# ------------------------------------------------------------------ gnutls, freetype
step "${LIBS[0]}" --disable-cxx --enable-fat
step "${LIBS[1]}" --disable-documentation --disable-openssl \
    --with-include-path="$PREFIX/include" --with-lib-path="$PREFIX/lib"
step "${LIBS[2]}" --disable-doc --disable-manpages --disable-tools --disable-tests \
    --disable-cxx --disable-guile --without-p11-kit --with-included-libtasn1 --with-included-unistring \
    --without-idn --without-brotli --without-zstd --without-tpm --without-tpm2 --disable-nls \
    --without-zlib --disable-hardware-acceleration
step "${LIBS[3]}" --without-harfbuzz --without-png --without-brotli --without-bzip2 --with-zlib=yes

# ------------------------------------------------------------------ SDL3 + sdl2-compat
# Wine (winebus.sys) ищет pkg-config sdl2 и dlopen'ит libSDL2-2.0.0.dylib; sdl2-compat даёт этот
# интерфейс поверх SDL3 и сам загружает SDL3: dlopen("@loader_path/libSDL3.dylib"), затем
# dlopen("libSDL3.dylib") — поэтому рядом с libSDL2-2.0.0.dylib должен лежать libSDL3.dylib
# (в префиксе это ссылка на libSDL3.0.dylib, в lib/external движка её создаёт build.sh).
build cmake "$SDL3" "" \
    -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST_LIBRARY=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF \
    -DSDL_INSTALL_DOCS=OFF -DSDL_INSTALL_CPACK=OFF -DSDL_X11=OFF -DSDL_VENDOR_INFO=onwin
build cmake "$SDL2COMPAT" "$SDL3" \
    -DSDL2COMPAT_TESTS=OFF -DSDL2COMPAT_INSTALL_CPACK=OFF -DSDL2COMPAT_X11=OFF \
    -DSDL2COMPAT_VENDOR_INFO=onwin -DSDL3_INCLUDE_DIRS="$PREFIX/include"

# ------------------------------------------------------------------ glib
build autotools "$LIBFFI" "" --disable-docs --disable-multi-os-directory
build autotools "$PCRE2" "" --enable-pcre2-8 --disable-pcre2-16 --disable-pcre2-32 --enable-jit \
    --disable-pcre2grep-libz --disable-pcre2grep-libbz2 --disable-pcre2test-libedit --disable-pcre2test-libreadline
# zlib — системная из SDK (meson находит её сам), libiconv — системная.
build meson "$GLIB" "$LIBFFI $PCRE2" \
    -Dtests=false -Dinstalled_tests=false -Dnls=disabled -Dintrospection=disabled \
    -Ddocumentation=false -Dman-pages=disabled -Dselinux=disabled -Dxattr=false -Dlibmount=disabled \
    -Dsysprof=disabled -Ddtrace=disabled -Dsystemtap=disabled -Dlibelf=disabled -Doss_fuzz=disabled \
    -Dglib_debug=disabled -Dbsymbolic_functions=false

# ------------------------------------------------------------------ GStreamer
# auto_features=disabled: собираются только нужные winegstreamer плагины, без
# документации, тестов, introspection, X11/GTK и прочего.
GST_COMMON="-Dauto_features=disabled -Ddoc=disabled -Dnls=disabled -Dtests=disabled"
# shellcheck disable=SC2086
build meson "$GSTREAMER" "$GLIB" $GST_COMMON -Dintrospection=disabled -Dexamples=disabled \
    -Dbenchmarks=disabled -Dtools=enabled -Dcheck=disabled -Dptp-helper=disabled -Dlibunwind=disabled \
    -Dlibdw=disabled -Ddbghelp=disabled -Dbash-completion=disabled -Dcoretracers=disabled \
    -Dregistry=true -Dgst_parse=true -Doption-parsing=true
# shellcheck disable=SC2086
build meson "$GST_BASE" "$GLIB $GSTREAMER" $GST_COMMON -Dintrospection=disabled -Dexamples=disabled \
    -Dtools=disabled -Dorc=disabled \
    -Daudioconvert=enabled -Daudioresample=enabled -Dplayback=enabled -Dtypefind=enabled \
    -Dvideoconvertscale=enabled \
    -Dgl=enabled -Dgl_api=opengl -Dgl_platform=cgl -Dgl_winsys=cocoa
# shellcheck disable=SC2086
build meson "$GST_GOOD" "$GLIB $GSTREAMER $GST_BASE" $GST_COMMON -Dexamples=disabled \
    -Dorc=disabled -Dasm=disabled \
    -Daudioparsers=enabled -Davi=enabled -Ddeinterlace=enabled -Did3demux=enabled -Disomp4=enabled \
    -Dvideofilter=enabled -Dwavparse=enabled -Dosxaudio=enabled
# shellcheck disable=SC2086
build meson "$GST_BAD" "$GLIB $GSTREAMER $GST_BASE" $GST_COMMON -Dintrospection=disabled -Dexamples=disabled \
    -Dtools=disabled -Dorc=disabled -Dgpl=disabled -Dvulkan=disabled \
    -Dgl=enabled -Dapplemedia=enabled -Dvideoparsers=enabled
# shellcheck disable=SC2086
build meson "$GST_UGLY" "$GLIB $GSTREAMER $GST_BASE" $GST_COMMON \
    -Dorc=disabled -Dgpl=disabled -Dasfdemux=enabled

fix_install_names
fix_pkgconfig

# ------------------------------------------------------------------ проверка
fail=0
for p in $GST_PLUGINS; do
    [ -f "$PREFIX/lib/gstreamer-1.0/libgst$p.dylib" ] || { echo "✗ нет плагина GStreamer $p"; fail=1; }
done
for f in "$PREFIX"/lib/*.dylib "$PREFIX"/lib/gstreamer-1.0/*.dylib; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    if [ "$(lipo -archs "$f")" != "x86_64" ]; then echo "✗ $(basename "$f"): $(lipo -archs "$f")"; fail=1; fi
    bad="$(otool -L "$f" | tail -n +2 | awk '{print $1}' | grep -v -E '^(@rpath/|@loader_path/|/usr/lib/|/System/Library/)' || true)"
    if [ -n "$bad" ]; then echo "✗ $(basename "$f") ссылается на: $bad"; fail=1; fi
done
if grep -l -e '-Wl,-rpath,' "$PREFIX"/lib/pkgconfig/*.pc 2>/dev/null; then echo "✗ в .pc остался -Wl,-rpath"; fail=1; fi
[ "$fail" = 0 ] || exit 1

echo "Готово: $PREFIX"
for lib in "$PREFIX"/lib/*.dylib; do [ -L "$lib" ] || echo "  $(basename "$lib"): $(lipo -archs "$lib")"; done
echo "  плагины GStreamer: $(ls "$PREFIX/lib/gstreamer-1.0" | grep -c '\.dylib$')"
