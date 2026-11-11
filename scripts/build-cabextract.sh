#!/bin/bash
# Builds a native (arm64) cabextract for onwin's component installer.
#
#   scripts/build-cabextract.sh [--force]
#
# Output: build/tools/cabextract (a single binary; libmspack is linked in, only libSystem is needed).
# scripts/build-app.sh copies it into Onwin.app/Contents/MacOS, where OnwinCore's `HostTools`
# finds it (Bundle.main → $ONWIN_CABEXTRACT → build/tools → PATH).
#
# Source: the latest stable upstream release, cabextract 1.11 (2023-02-24, https://www.cabextract.org.uk/),
# pinned by SHA-256 (the same hash Homebrew's formula pins). CrossOver 26.3 ships 1.9.1 in
# engine/sources/sources/cabextract; we use the newer upstream release instead.
# The tarball is kept in engine/sources/upstream; it is downloaded only when missing.
#
# Works with macOS /bin/bash 3.2; needs only the Command Line Tools (clang, make).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION="1.11"
SHA256="b5546db1155e4c718ff3d4b278573604f30dd64c3c5bfd4657cd089b823a3ac6"
URL="https://www.cabextract.org.uk/cabextract-$VERSION.tar.gz"
TARBALL="$ROOT/engine/sources/upstream/cabextract-$VERSION.tar.gz"
WORK="$ROOT/build/cabextract-build"
OUT="$ROOT/build/tools/cabextract"

die() { echo "build-cabextract: ошибка: $*" >&2; exit 1; }
note() { echo "==> $*"; }

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

if [ "$FORCE" = 0 ] && [ -x "$OUT" ] && "$OUT" --version 2>/dev/null | grep -q "$VERSION"; then
    note "cabextract $VERSION уже собран: $OUT"
    exit 0
fi

mkdir -p "$(dirname "$TARBALL")"
if [ ! -f "$TARBALL" ]; then
    note "скачиваю $URL"
    curl -fL --retry 3 -o "$TARBALL.part" "$URL" || die "не удалось скачать $URL"
    mv "$TARBALL.part" "$TARBALL"
fi
ACTUAL="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
[ "$ACTUAL" = "$SHA256" ] || die "SHA-256 не совпадает для $TARBALL: $ACTUAL (ожидался $SHA256)"

rm -rf "$WORK"
mkdir -p "$WORK"
tar -xzf "$TARBALL" -C "$WORK"
SRC="$WORK/cabextract-$VERSION"
[ -x "$SRC/configure" ] || die "в архиве нет configure"

note "configure (arm64, встроенный libmspack)"
cd "$SRC"
CC="/usr/bin/clang -arch arm64" \
CFLAGS="-O2 -mmacosx-version-min=14.0" \
LDFLAGS="-mmacosx-version-min=14.0" \
    ./configure --host=aarch64-apple-darwin --disable-dependency-tracking --prefix="$WORK/prefix" >/dev/null

note "make"
make -j"$(sysctl -n hw.ncpu)" >/dev/null

mkdir -p "$(dirname "$OUT")"
cp "$SRC/cabextract" "$OUT"
chmod 755 "$OUT"
strip -x "$OUT" 2>/dev/null || true

# Must not depend on anything but the system (no Homebrew libraries).
if otool -L "$OUT" | tail -n +2 | grep -v -E '^\s*/usr/lib/' | grep -q .; then
    otool -L "$OUT"
    die "cabextract зависит от несистемных библиотек"
fi
"$OUT" --version
note "готово: $OUT ($(lipo -archs "$OUT"))"
