#!/bin/bash
# Refreshes third_party/licenses/ from the source archives the engine is built from
# (engine/sources, see engine/README.md). Run after updating a component version, review the diff,
# commit. DXMT, Wine Mono and Wine Gecko ship no license file in their binary archives: their texts
# (DXMT.txt, wine-mono.txt, wine-gecko-MPL-2.0.txt) are kept by hand from the upstream repositories.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/engine/sources"
UP="$SRC/upstream"
OUT="$ROOT/third_party/licenses"
mkdir -p "$OUT"
die() { echo "collect-licenses: ошибка: $*" >&2; exit 1; }
[ -d "$UP" ] || die "нет $UP — сначала скачайте исходники (engine/deps.sh, engine/build-libs.sh)"

# from_tar <archive glob> <member path without the top folder> <output name>
from_tar() {
    local archive member
    archive=$(ls $UP/$1 2>/dev/null | head -n 1) || true
    [ -n "$archive" ] || die "не найден архив $1"
    member=$(tar -tf "$archive" | grep -E "^[^/]+/$2\$" | head -n 1) || true
    [ -n "$member" ] || die "в $archive нет $2"
    tar -xOf "$archive" "$member" > "$OUT/$3"
}
from_tree() { [ -f "$SRC/sources/$1" ] || die "нет $SRC/sources/$1"; cp "$SRC/sources/$1" "$OUT/$2"; }

from_tree wine/COPYING.LIB          wine-LGPL-2.1.txt
from_tree wine/LICENSE              wine-LICENSE.txt
from_tree wine/AUTHORS              wine-AUTHORS.txt
from_tree dxvk/LICENSE              dxvk.txt
from_tree vkd3d/COPYING             vkd3d.txt
from_tree vkd3d/LICENSE             vkd3d-LICENSE.txt
from_tar 'MoltenVK-macos-*.tar'     'LICENSE'                 MoltenVK-Apache-2.0.txt
from_tar 'SDL3-*.tar.gz'            'LICENSE.txt'             SDL3.txt
from_tar 'sdl2-compat-*.tar.gz'     'LICENSE.txt'             sdl2-compat.txt
from_tar 'cabextract-*.tar.gz'      'COPYING'                 cabextract-GPL-2.0.txt
from_tar 'freetype-*.tar.xz'        'LICENSE.TXT'             freetype-LICENSE.txt
from_tar 'freetype-*.tar.xz'        'docs/FTL.TXT'            freetype-FTL.txt
from_tar 'glib-*.tar.xz'            'COPYING'                 glib-LGPL-2.1.txt
from_tar 'gmp-*.tar.xz'             'COPYING.LESSERv3'        gmp-LGPL-3.0.txt
from_tar 'gmp-*.tar.xz'             'COPYINGv2'               gmp-GPL-2.0.txt
from_tar 'gnutls-*.tar.xz'          'COPYING.LESSERv2'        gnutls-LGPL-2.1.txt
from_tar 'nettle-*.tar.gz'          'COPYING.LESSERv3'        nettle-LGPL-3.0.txt
from_tar 'nettle-*.tar.gz'          'COPYINGv2'               nettle-GPL-2.0.txt
from_tar 'gstreamer-1*.tar.xz'      'COPYING'                 gstreamer-LGPL-2.1.txt
from_tar 'gst-plugins-good-*.tar.xz' 'COPYING'                gst-plugins-LGPL-2.1.txt
from_tar 'libffi-*.tar.gz'          'LICENSE'                 libffi-MIT.txt
from_tar 'pcre2-*.tar.bz2'          'LICENCE.md'              pcre2-BSD.txt
from_tar 'proxy-libintl-*.tar.gz'   'COPYING'                 proxy-libintl.txt
echo "готово: $OUT"
