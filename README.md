# onwin

Windows-программы и игры на Mac с Apple Silicon — бесплатно и с открытым кодом.

**Сайт и установка:** https://totktoxam.github.io/onwin/

```bash
curl -fsSL https://totktoxam.github.io/onwin/install.sh | bash
```

Та же команда обновляет onwin: она скачивает только изменившиеся части. Полный образ диска (DMG) лежит в
[релизах](https://github.com/totKtoXam/onwin/releases/latest). Нужен Mac с процессором Apple и macOS 14 или новее.

## Что умеет

- **Пространства** — отдельные «маленькие Windows», у каждого свой диск C:, свои программы и настройки.
- Движок Wine 11 с графикой D3DMetal (Apple Game Porting Toolkit, импортируется с сайта Apple), DXMT и DXVK.
- Steam с плитками установленных игр, каталог лаунчеров и компонентов (DirectX, Visual C++, .NET, шрифты), которые
  ставятся автоматически перед первым запуском программы.
- Ярлыки Windows-программ в Launchpad и Dock, командная строка `onwinctl`.

## Сборка из исходников

```bash
cd app && swift build -c release      # приложение и onwinctl
scripts/build-app.sh                  # Onwin.app
engine/build-libs.sh && engine/build.sh   # движок Wine (долго; см. engine/README.md)
```

Правила разработки (в том числе для ИИ-агентов) — в [AGENTS.md](AGENTS.md).

## Поддержать проект

onwin развивается на пожертвования: https://totktoxam.github.io/onwin/donate.html

## Лицензия

Код onwin — [GPL-3.0](LICENSE). Сторонние компоненты движка распространяются под своими лицензиями, см.
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md); исходники компонентов приложены к релизам движка.

Названия Windows, Mac, Steam и других продуктов принадлежат их владельцам; onwin — независимый проект.
