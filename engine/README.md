# Движок onwin

Движок — это Wine 11.0 из официальных исходников CrossOver 26.3 (патчи CodeWeavers), собранный под
x86_64 (на Apple Silicon он работает через Rosetta 2), плюс всё, что нужно играм:

| Часть | Версия | Откуда | Где в движке |
|---|---|---|---|
| Wine + патчи CodeWeavers (WoW64: i386 + x86_64) | 11.0 (CrossOver 26.3.0) | `sources/sources/wine` | `bin/`, `lib/wine/`, `share/wine/` |
| onwincompat — наша замена закрытого `cxcompatdb.so` (выбор графики для каждой программы) | — | `compat/onwincompat.c` | `lib/wine/x86_64-unix/cxcompatdb.so` |
| DXVK (форк CodeWeavers) + наши патчи `patches/dxvk` | 1.10.3 | `sources/sources/dxvk` | `lib/dxvk/` |
| DXMT | 0.80 | официальный релиз github.com/3Shain/dxmt | `lib/dxmt/` (+ `winemetal.dll` в `lib/wine/*-windows`, как в CrossOver) |
| MoltenVK | 1.4.2 | официальный релиз KhronosGroup | `lib/external/` |
| gmp, nettle, gnutls, freetype | 6.3.0, 4.0, 3.8.13, 2.15.0 | официальные исходники, `build-libs.sh` | `lib/external/` |
| SDL3 + sdl2-compat (геймпады) | 3.4.20, 2.32.74 | `build-libs.sh` | `lib/external/` |
| glib, GStreamer + 18 плагинов (видео и звук в играх, VideoToolbox) | 2.90.1, 1.28.9 | `build-libs.sh` | `lib/external/`, `lib/gstreamer-1.0/` |
| Wine Mono, Wine Gecko | 10.4.1, 2.47.4 (ровно те, что ждёт Wine 11.0) | dl.winehq.org | `share/wine/mono`, `share/wine/gecko` |

D3DMetal (Apple Game Porting Toolkit) в движок не входит: его нельзя распространять. Его импортирует
приложение onwin (каталог → «D3DMetal») или `onwinctl d3dmetal-fetch`.

## Что нужно

- Command Line Tools (`xcode-select --install`), Rosetta 2.
- Обычный Homebrew для Apple Silicon (`/opt/homebrew`) — только **инструменты** сборки:
  `brew install autoconf automake libtool pkgconf bison flex mingw-w64 meson ninja glslang gettext cmake`.
  Intel-версия Homebrew не нужна (и больше не поддерживается): все x86_64-библиотеки собираются
  из исходников скриптом `build-libs.sh`.

## Сборка

```bash
./build-libs.sh     # x86_64-библиотеки → build/x86_64-libs (первый раз ~15 мин)
./build.sh          # движок → dist/onwin-cx26.3 (первый раз ~40–60 мин, потом инкрементально)
./build.sh install  # установить в onwin (~/Library/Application Support/onwin/Engines)
```

`./build.sh --status` показывает готовые этапы, `./build.sh --force <этап>` пересобирает этап
(например, после правки `compat/onwincompat.c` — `--force compat`, после патчей DXVK — `--force dxvk`).
Этапы: toolchain moltenvk wine-configure wine-build wine-install compat dxvk dxmt addons bundle manifest verify.
Журналы — `build/logs/`. Все загрузки проверяются по SHA-256.

Итог: ~1,1 ГБ, проверка `verify` убеждается, что в движке нет ссылок на Homebrew и он переносим.

## Проверка графики

`tests/d3dprobe.exe` (исходник `tests/d3dprobe.c`, сборка `x86_64-w64-mingw32-gcc -O2 -o d3dprobe.exe d3dprobe.c -ld3d11 -ldxgi -luuid -lgdi32 -luser32`)
создаёт устройство Direct3D 11 и печатает адаптер:

```bash
onwinctl set Test backend dxmt && onwinctl run Test engine/tests/d3dprobe.exe
```

Проверено 11.11.2026 на Apple M5: DXMT и DXVK — D3D11 feature level 11_0, WineD3D — 9_3, D3D12 через vkd3d — есть.
