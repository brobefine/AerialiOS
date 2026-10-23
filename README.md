# Aerial для iPhone и iPad

Кинотека Aerial на Swift и SwiftUI: каталог TMDb, поиск раздач (JacRed, Torrentio), встроенный TorrServer
и плеер на libmpv (MPVKit) — MKV, HEVC, HDR, многоканальный звук, субтитры ASS.

## Сборка

Проект собирается на GitHub Actions (`.github/workflows/build.yml`): XcodeGen создаёт проект из `project.yml`,
затем идут тесты на симуляторе и сборка неподписанного `Aerial.ipa` (артефакт `Aerial-ipa`).

Локально на Mac:

```sh
brew install xcodegen
printf 'TMDB_API_KEY = <ключ>\n' > Config/Secrets.xcconfig
xcodegen generate && open Aerial.xcodeproj
```

## Установка

Неподписанный `.ipa` ставится через Sideloadly или AltStore со своим Apple ID.

## Компоненты

- [TorrServer](https://github.com/YouROK/TorrServer) — TorrServerKit.xcframework из официальных релизов.
- [MPVKit](https://github.com/mpvkit/MPVKit) — libmpv и FFmpeg для iOS.
- Данные о фильмах — [TMDb](https://www.themoviedb.org).
