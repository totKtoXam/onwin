# Сторонние компоненты onwin

Собственный код onwin распространяется под лицензией **GNU GPL 3.0** (файл [LICENSE](LICENSE)).

Движок onwin (Wine и всё, что ему нужно для игр) собран из открытых исходников, перечисленных ниже. Каждый компонент
распространяется под **своей** лицензией. Полные тексты лицензий лежат в [third_party/licenses](third_party/licenses).
В готовом приложении они находятся в `Onwin.app/Contents/Resources/Licenses`, в движке — в `share/licenses`.

## Исходный код

Исходники всех компонентов под LGPL/GPL/MPL, из которых собран конкретный движок, прикреплены к его релизу на GitHub
(релиз с тегом `engine-…`, файлы `*-sources*.tar*`). Наши изменения — это патчи в [engine/patches](engine/patches)
и скрипты сборки [engine/build.sh](engine/build.sh), [engine/build-libs.sh](engine/build-libs.sh). Если архив недоступен, напишите
в Issues репозитория — исходники вышлем.

## Компоненты движка

| Компонент | Версия | Лицензия | Файл лицензии |
|---|---|---|---|
| Wine с патчами CodeWeavers (открытые исходники CrossOver) | 11.0 (исходники CrossOver 26.3.0) | LGPL-2.1+ | `wine-LGPL-2.1.txt`, `wine-LICENSE.txt`, `wine-AUTHORS.txt` |
| Библиотеки, входящие в исходники Wine (`libs/`: vkd3d, FAudio, mpg123, musl, libpng, libjpeg, zlib, lcms2, libxml2, libxslt и др.) | из исходников Wine | свои лицензии каждой библиотеки (LGPL, zlib, MIT, BSD и др.) | тексты — в исходниках Wine, `libs/*`; vkd3d: `vkd3d.txt`, `vkd3d-LICENSE.txt` |
| DXVK (форк CodeWeavers) + патчи onwin | 1.10.3 | zlib | `dxvk.txt` |
| DXMT | 0.80 | LGPL-2.1+ | `DXMT.txt` |
| MoltenVK | 1.4.2 | Apache-2.0 | `MoltenVK-Apache-2.0.txt` |
| GStreamer + base/good/bad/ugly (только нужные плагины) | 1.28.9 | LGPL-2.1+ | `gstreamer-LGPL-2.1.txt`, `gst-plugins-LGPL-2.1.txt` |
| GLib | 2.90.1 | LGPL-2.1+ | `glib-LGPL-2.1.txt` |
| GnuTLS | 3.8.13 | LGPL-2.1+ | `gnutls-LGPL-2.1.txt` |
| Nettle | 4.0 | LGPL-3.0+ или GPL-2.0+ | `nettle-LGPL-3.0.txt`, `nettle-GPL-2.0.txt` |
| GMP | 6.3.0 | LGPL-3.0+ или GPL-2.0+ | `gmp-LGPL-3.0.txt`, `gmp-GPL-2.0.txt` |
| FreeType | 2.15.0 | FreeType License (FTL) | `freetype-LICENSE.txt`, `freetype-FTL.txt` |
| SDL3 | 3.4.20 | zlib | `SDL3.txt` |
| sdl2-compat | 2.32.74 | zlib | `sdl2-compat.txt` |
| libffi | 3.8.0 | MIT | `libffi-MIT.txt` |
| PCRE2 | 10.49 | BSD-3-Clause (с исключением для библиотек) | `pcre2-BSD.txt` |
| proxy-libintl | 0.5 | LGPL-2.1+ | `proxy-libintl.txt` |
| Wine Mono | 10.4.1 | MIT, LGPL и др. (см. файл) | `wine-mono.txt` |
| Wine Gecko | 2.47.4 | MPL-2.0 | `wine-gecko-MPL-2.0.txt` |

Части FreeType: «Portions of this software are copyright © 2026 The FreeType Project (https://freetype.org). All rights reserved.»

## Компоненты приложения

| Компонент | Версия | Лицензия | Файл лицензии |
|---|---|---|---|
| cabextract (распаковка CAB-архивов Microsoft) | 1.11 | GPL-2.0+ | `cabextract-GPL-2.0.txt` |

## Что onwin не распространяет

- **D3DMetal** (часть Apple Game Porting Toolkit). Пользователь сам скачивает его с сайта Apple под своей учётной записью,
  onwin только помогает импортировать.
- **Компоненты Microsoft** (DirectX, Visual C++, .NET, шрифты и т. п.). Они скачиваются с серверов Microsoft на компьютере
  пользователя по его запросу.
- Игры, лаунчеры и их оформление. Обложки Steam загружаются из Steam при показе.

## Товарные знаки

onwin — независимый проект. Windows, DirectX, Mac, macOS, Metal, Steam и другие названия принадлежат их владельцам
и упоминаются только для описания совместимости и происхождения открытого кода.
