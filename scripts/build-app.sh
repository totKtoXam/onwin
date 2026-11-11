#!/bin/bash
# Builds onwin and assembles build/Onwin.app.
#
#   scripts/build-app.sh [--with-engine <engine dir>] [--debug] [--universal] [--no-icon] [--no-sign]
#
#   --with-engine <dir>  copy a built engine (bin/wine, lib/wine, ..., onwin-engine.json) into
#                        Onwin.app/Contents/SharedSupport/Engine (EngineManager finds it there)
#   --debug              build the debug configuration instead of release
#   --universal          build arm64 + x86_64 (needs full Xcode; default is the native arch —
#                        the app is native, Wine itself runs under Rosetta)
#   --no-icon            skip icon generation
#   --no-sign            skip code signing (onwin Code Signing certificate if present, else ad-hoc)
#
# Requires Command Line Tools (swift, codesign; iconutil optional). Works with macOS /bin/bash 3.2.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE="$ROOT/app"
BUILD="$ROOT/build"
# Папка с суффиксом .noindex не индексируется Spotlight, поэтому рабочая сборка не появляется
# в Launchpad вторым значком рядом с /Applications/Onwin.app.
APP="$BUILD/app.noindex/Onwin.app"

CONFIG="release"
ENGINE=""
UNIVERSAL=0
MAKE_ICON=1
SIGN=1

die() { echo "build-app: ошибка: $*" >&2; exit 1; }
note() { echo "==> $*"; }
warn() { echo "build-app: предупреждение: $*" >&2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --with-engine)
            [ $# -ge 2 ] || die "--with-engine требует путь к движку"
            ENGINE="$2"; shift 2 ;;
        --with-engine=*)
            ENGINE="${1#--with-engine=}"; shift ;;
        --debug) CONFIG="debug"; shift ;;
        --universal) UNIVERSAL=1; shift ;;
        --no-icon) MAKE_ICON=0; shift ;;
        --no-sign) SIGN=0; shift ;;
        -h|--help)
            sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) die "неизвестный параметр: $1" ;;
    esac
done

# Do not let a missing toolchain pop up the CLT installer dialog: check first.
if ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
    die "не установлены Command Line Tools. Установите их: xcode-select --install"
fi
command -v swift >/dev/null 2>&1 || die "swift не найден в PATH"

if [ -n "$ENGINE" ]; then
    ENGINE="$(cd "$ENGINE" 2>/dev/null && pwd)" || die "папка движка не найдена"
    [ -x "$ENGINE/bin/wine" ] || die "в $ENGINE нет bin/wine — это не движок onwin"
    [ -f "$ENGINE/onwin-engine.json" ] || warn "в движке нет onwin-engine.json (onwin не покажет версию)"
fi

# --- Version -----------------------------------------------------------------------------------
VERSION="$(sed -nE 's/.*static let string = "([^"]+)".*/\1/p' "$PACKAGE/Sources/OnwinCore/WineRunner.swift" | head -n 1)"
[ -n "$VERSION" ] || VERSION="0.1.0"
BUILD_NUMBER="${ONWIN_BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"   # release.sh passes one number for all builds
note "onwin $VERSION ($BUILD_NUMBER), конфигурация $CONFIG"

# --- Compile -----------------------------------------------------------------------------------
SWIFT_ARGS=(-c "$CONFIG" --package-path "$PACKAGE")
if [ "$UNIVERSAL" = 1 ]; then
    SWIFT_ARGS=("${SWIFT_ARGS[@]}" --arch arm64 --arch x86_64)
fi
note "swift build ${SWIFT_ARGS[*]}"
swift build "${SWIFT_ARGS[@]}"
BIN_DIR="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)"
[ -x "$BIN_DIR/Onwin" ] || die "не найден собранный $BIN_DIR/Onwin"
[ -x "$BIN_DIR/onwinctl" ] || die "не найден собранный $BIN_DIR/onwinctl"
[ -x "$BIN_DIR/onwin-launcher" ] || die "не найден собранный $BIN_DIR/onwin-launcher"

# --- Bundle layout -----------------------------------------------------------------------------
note "сборка $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Onwin" "$APP/Contents/MacOS/Onwin"
cp "$BIN_DIR/onwinctl" "$APP/Contents/MacOS/onwinctl"
# Main executable of the Launchpad launchers (LauncherBuilder copies it into every <program>.app).
cp "$BIN_DIR/onwin-launcher" "$APP/Contents/MacOS/onwin-launcher"
chmod 755 "$APP/Contents/MacOS/Onwin" "$APP/Contents/MacOS/onwinctl" "$APP/Contents/MacOS/onwin-launcher"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Host tools used by the component installer (DLLs from Microsoft cabinets). OnwinCore's HostTools
# looks next to the executable first (Contents/MacOS), so the bundled copy always wins over PATH.
CABEXTRACT="$BUILD/tools/cabextract"
if [ ! -x "$CABEXTRACT" ]; then
    note "собираю cabextract (scripts/build-cabextract.sh)"
    "$SCRIPT_DIR/build-cabextract.sh" || warn "не удалось собрать cabextract — компоненты из CAB-архивов будут недоступны"
fi
if [ -x "$CABEXTRACT" ]; then
    cp "$CABEXTRACT" "$APP/Contents/MacOS/cabextract"
    chmod 755 "$APP/Contents/MacOS/cabextract"
fi

# SwiftPM resource bundles (none today, but keep them if a target gains resources).
for bundle in "$BIN_DIR"/*.bundle; do
    [ -e "$bundle" ] || continue
    ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"
    warn "скопирован ресурсный бандл $(basename "$bundle") — проверьте, что Bundle.module его находит"
done

# --- Licenses ----------------------------------------------------------------------------------
# onwin's GPL-3.0 text, the list of third-party components and their license texts (THIRD_PARTY_NOTICES.md).
mkdir -p "$APP/Contents/Resources/Licenses"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/Licenses/onwin-GPL-3.0.txt"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$ROOT"/third_party/licenses/*.txt "$APP/Contents/Resources/Licenses/"

# --- Icon --------------------------------------------------------------------------------------
ICON_KEY=""
if [ "$MAKE_ICON" = 1 ]; then
    ICON_WORK="$BUILD/icon"
    rm -rf "$ICON_WORK"
    mkdir -p "$ICON_WORK"
    ICONSET="$ICON_WORK/AppIcon.iconset"
    FALLBACK_ICNS="$ICON_WORK/AppIcon-direct.icns"
    note "рисую иконку"
    ICON_OK=0
    if swift "$SCRIPT_DIR/make-icon.swift" "$ICONSET" "$FALLBACK_ICNS"; then
        ICON_OK=1
    elif swiftc -O -o "$ICON_WORK/make-icon" "$SCRIPT_DIR/make-icon.swift" \
         && "$ICON_WORK/make-icon" "$ICONSET" "$FALLBACK_ICNS"; then
        ICON_OK=1
    fi
    if [ "$ICON_OK" = 1 ]; then
        if command -v iconutil >/dev/null 2>&1 \
           && iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then
            :
        else
            warn "iconutil недоступен или не сработал — использую .icns, записанный напрямую"
            cp "$FALLBACK_ICNS" "$APP/Contents/Resources/AppIcon.icns"
        fi
        ICON_KEY="AppIcon"
    else
        warn "не удалось нарисовать иконку — приложение будет без неё"
    fi
fi

# --- Info.plist --------------------------------------------------------------------------------
ICON_PLIST=""
if [ -n "$ICON_KEY" ]; then
    ICON_PLIST="    <key>CFBundleIconFile</key>
    <string>$ICON_KEY</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>ru</string>
    <key>CFBundleExecutable</key>
    <string>Onwin</string>
    <key>CFBundleIdentifier</key>
    <string>app.onwin.Onwin</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>onwin</string>
    <key>CFBundleDisplayName</key>
    <string>onwin</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
$ICON_PLIST
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.games</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>onwin — запуск Windows-программ на Mac</string>

    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Программа Windows</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.microsoft.windows-executable</string>
                <string>app.onwin.exe</string>
            </array>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>exe</string>
                <string>com</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Установщик Windows</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.microsoft.msi-installer</string>
                <string>app.onwin.msi</string>
            </array>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>msi</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Ярлык Windows</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>app.onwin.lnk</string>
            </array>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>lnk</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Пакетный файл Windows</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>app.onwin.bat</string>
            </array>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>bat</string>
                <string>cmd</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Архив пространства onwin</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Owner</string>
            <key>LSTypeIsPackage</key>
            <false/>
            <key>LSItemContentTypes</key>
            <array>
                <string>app.onwin.space-archive</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Рецепт onwin</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Owner</string>
            <key>LSTypeIsPackage</key>
            <false/>
            <key>LSItemContentTypes</key>
            <array>
                <string>app.onwin.recipe</string>
            </array>
        </dict>
    </array>

    <!-- Launchpad launchers open onwin://run?space=<uuid> (older launchers: ?bottle=)&program=<id>&file=<path>
         (LauncherBuilder / LaunchRequest in OnwinCore/Launchers.swift). -->
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>app.onwin.Onwin.run</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>onwin</string>
            </array>
        </dict>
    </array>

    <!-- Windows programs run as children of onwin, so macOS asks for camera / microphone access on
         onwin's behalf (voice chat in games and launchers, video calls). Without these keys TCC
         denies (or kills) the request instead of asking. -->
    <key>NSCameraUsageDescription</key>
    <string>Windows-программам, запущенным в onwin, нужна камера — например, для видеозвонков и трансляций.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Windows-программам, запущенным в onwin, нужен микрофон — например, для голосового чата в играх и лаунчерах.</string>

    <!-- onwin's own formats: space archive (tar.gz made by SpaceManager.archive; opening one restores it;
         .onwinbottle is the extension used by development builds before spaces were renamed)
         and user recipe (.onwinrecipe). -->
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>app.onwin.space-archive</string>
            <key>UTTypeDescription</key>
            <string>Архив пространства onwin</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.data</string>
                <string>public.archive</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>onwinspace</string>
                    <string>onwinbottle</string>
                </array>
                <key>public.mime-type</key>
                <array>
                    <string>application/x-onwin-space</string>
                </array>
            </dict>
        </dict>
        <!-- User recipe ("Мои приложения", OnwinCore/UserRecipes.swift): JSON; opening one shows it for
             review in the recipe editor, nothing is installed or run. -->
        <dict>
            <key>UTTypeIdentifier</key>
            <string>app.onwin.recipe</string>
            <key>UTTypeDescription</key>
            <string>Рецепт onwin</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.json</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>onwinrecipe</string>
                </array>
                <key>public.mime-type</key>
                <array>
                    <string>application/x-onwin-recipe</string>
                </array>
            </dict>
        </dict>
    </array>

    <!-- Imported, not exported: onwin does not own these formats. If the system (or another
         app) already declares a type, its declaration wins and ours is only a fallback. -->
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>com.microsoft.windows-executable</string>
            <key>UTTypeDescription</key>
            <string>Программа Windows</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.data</string>
                <string>public.executable</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>exe</string>
                </array>
                <key>public.mime-type</key>
                <array>
                    <string>application/vnd.microsoft.portable-executable</string>
                    <string>application/x-msdownload</string>
                </array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>app.onwin.exe</string>
            <key>UTTypeDescription</key>
            <string>Программа Windows</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.data</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>exe</string>
                    <string>com</string>
                </array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>com.microsoft.msi-installer</string>
            <key>UTTypeDescription</key>
            <string>Установщик Windows</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.data</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>msi</string>
                </array>
                <key>public.mime-type</key>
                <array>
                    <string>application/x-msi</string>
                </array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>app.onwin.msi</string>
            <key>UTTypeDescription</key>
            <string>Установщик Windows</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.data</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>msi</string>
                </array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>app.onwin.lnk</string>
            <key>UTTypeDescription</key>
            <string>Ярлык Windows</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.data</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>lnk</string>
                </array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>app.onwin.bat</string>
            <key>UTTypeDescription</key>
            <string>Пакетный файл Windows</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.data</string>
                <string>public.plain-text</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>bat</string>
                    <string>cmd</string>
                </array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
PLIST

if [ -x /usr/bin/plutil ]; then
    /usr/bin/plutil -lint "$APP/Contents/Info.plist" >/dev/null || die "Info.plist невалиден"
fi

# --- Engine ------------------------------------------------------------------------------------
if [ -n "$ENGINE" ]; then
    note "копирую движок $ENGINE → Contents/SharedSupport/Engine"
    mkdir -p "$APP/Contents/SharedSupport"
    ditto "$ENGINE" "$APP/Contents/SharedSupport/Engine"
    mkdir -p "$APP/Contents/SharedSupport/Engine/share/licenses"
    cp "$ROOT"/third_party/licenses/*.txt "$APP/Contents/SharedSupport/Engine/share/licenses/"
fi

# --- Signing -----------------------------------------------------------------------------------
if [ "$SIGN" = 1 ]; then
    if command -v codesign >/dev/null 2>&1; then
        # onwin's own certificate (scripts/make-signing-identity.sh) keeps the app's identity stable, so
        # macOS remembers microphone / camera / folder permissions across updates. Without it: ad-hoc.
        # ONWIN_SIGN_IDENTITY overrides ("-" = ad-hoc, or a certificate name / SHA-1).
        IDENTITY="${ONWIN_SIGN_IDENTITY:-}"
        if [ -z "$IDENTITY" ]; then
            IDENTITY="$(/usr/bin/security find-identity -p codesigning 2>/dev/null \
                | sed -nE 's/^ *[0-9]+\) ([0-9A-F]{40}) "onwin Code Signing".*/\1/p' | head -n 1)"
        fi
        if [ -z "$IDENTITY" ] || [ "$IDENTITY" = "-" ]; then
            IDENTITY="-"
            [ -n "${ONWIN_SIGN_IDENTITY:-}" ] || warn "нет сертификата «onwin Code Signing» (scripts/make-signing-identity.sh) — ad-hoc подпись, macOS будет заново спрашивать разрешения после каждой сборки"
            note "ad-hoc подпись"
        else
            note "подпись сертификатом $IDENTITY"
        fi
        codesign --force --deep --sign "$IDENTITY" "$APP"
        codesign --verify "$APP" 2>/dev/null || warn "codesign --verify сообщил о проблемах"
    else
        warn "codesign не найден — приложение не подписано"
    fi
fi

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# Рабочую копию не регистрируем в Launch Services — запускать нужно ту, что в «Программах».
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
# Если onwin уже установлен в /Applications — обновляем его этой сборкой.
if [ -d /Applications/Onwin.app ] && [ "${ONWIN_NO_INSTALL:-0}" != 1 ]; then
    note "обновляю /Applications/Onwin.app"
    rm -rf /Applications/Onwin.app.new
    ditto "$APP" /Applications/Onwin.app.new
    rm -rf /Applications/Onwin.app
    mv /Applications/Onwin.app.new /Applications/Onwin.app
    "$LSREGISTER" -f /Applications/Onwin.app >/dev/null 2>&1 || true
fi

note "готово: $APP"
echo "    Запуск:      open \"$APP\""
echo "    CLI в PATH:  \"$SCRIPT_DIR/install-cli.sh\""
