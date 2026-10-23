# Aerial iOS — карта проекта

Кинотека Aerial для iPhone и iPad: Swift + SwiftUI, видео — libmpv (MPVKit), раздачи — встроенный TorrServer (TorrServerKit).
Брат приложений для Android TV и Windows из `F:\Aerial`: оттуда перенесены каталог TMDb (`VodTmdbClient`), поиск раздач
(`ParserState`, `Torrentio`), клиент TorrServer, разбор названий раздач (`ReleaseInfo.kt`) и правило разделов. Меняется
поведение там — сверить здесь. Вид — по образцу приложения Apple TV для iPhone, с цветами Aerial (#7FDCFF, #3E7BEA).

**Документация — часть изменения.** Переносишь, переименовываешь, добавляешь файл или меняешь путь данных — в той же
правке обнови этот файл. Код и описание расходиться не должны.

## Сборка (Mac нет)

- Проект Xcode генерирует XcodeGen из `project.yml`; `*.xcodeproj` и `Config/Info.plist` в git не хранятся.
- CI — `.github/workflows/build.yml` (`macos-26`, Xcode 26.6): одна сборка для тестов, затем на симуляторе iPhone 17 Pro
  (iOS 26.5) все тесты, на iPad Pro 11" — снимки экранов; в конце неподписанный `Aerial.ipa`. Все проверки — в одном
  прогоне (~20 мин): новые шаги добавлять в `ScreensTests`, а не отдельными прогонами. Артефакты: `Aerial-ipa` и
  `Aerial-check` — снимки `screens/iphone`, `screens/ipad`, журналы `logs/` (сборка `test-build.log`, тесты
  `test-iphone.log`/`test-ipad.log`, итоги `test-results-*.json`, `archive.log`; с симулятора — `app/app.log`,
  `app/mpv.log`, журналы TorrServer).
  Скачать: `gh run download <id> -R brobefine/AerialiOS`. Репозиторий открытый — минуты macOS не считаются.
- Ключи TMDb — секреты репозитория `TMDB_API_KEY`, `TMDB_READ_TOKEN` → `Config/Secrets.xcconfig` (не в git) → Info.plist
  (`TMDBApiKey`, `TMDBReadToken`). Значения — из `tmdb.apiKey`/`tmdb.readToken` в `F:\Aerial\local.properties`.
- Установка на iPhone — .ipa через Sideloadly или AltStore с Windows (бесплатный Apple ID — подпись на 7 дней).
- Язык Swift 5 (строгая проверка параллельности не включена): без Mac каждая ошибка компиляции стоит круга CI.
- Иконка — `tools/make_icon.py`: знак из вектора ТВ в стекле (Liquid Glass вручную, `.icon` из Icon Composer требует Mac).

## Что где — `Aerial/`

- `App/AerialApp.swift` — вход; `RootView` — вкладки «Главная», «Медиатека», «Поиск» и плеер поверх всего
  (`Playback.request` → `PlayerView`); `UITestHooks` — запуск из UI-тестов (`-uiTest`, `-smokeLink`).
- `Core/` — `Log` (журналы `Documents/logs`), `HTTP`, `DiskCache` (ответы TMDb: срок по виду запроса, при сбое — старый
  ответ), `Text` (`Rx` — NSRegularExpression с просмотром назад; `SearchText`, `Format`).
- `Data/` — `Models` (`VodItem`, `VodShelf.accepts`, `CinemaSection`), `TMDb` (прямой API → Worker-прокси, последний
  ответивший маршрут первым; ответы `TMDb*`; `TMDbImage` — CDN, затем Worker), `Catalogue` (ряды разделов, страница фильма,
  сезоны, поиск, актёр, логотип; `GenreStore`), `AppSettings`, `Library` («Мой список», прогресс, `WatchSource` —
  раздача и файл для «Продолжить»).
- `Torrents/` — `TorrServerClient` (HTTP-API: add, stat, awaitFiles, preload с ранним стартом, streamURL, settings),
  `Torrents` (`EmbeddedTorrServer` — 127.0.0.1:18090, перезапуск после сна, настройки кэша; выбор встроенный/внешний),
  `Release` (`Release`, `ReleaseInfo` — разбор названия, `EpisodeMatch` — файл серии), `ReleaseSearch` (JacRed exact →
  Jackett, плюс `Torrentio`).
- `Player/` — `MPVCore` (libmpv: опции, события в главный поток, команды; `MPVViewController` — слой Metal),
  `PlayerModel` (TorrServer → подкачка → mpv; прогресс каждые 5 с), `PlayerView` (панель в духе Apple TV, поворот),
  `NowPlaying` (экран блокировки и «Пункт управления»).
- `UI/` — `Theme` (цвета, стекло iOS 26 с запасным материалом), `CachedImage` (`ImageLoader`: память → диск → сеть,
  уменьшение при декодировании), `Components` (`Route`, `PosterCard`, `RatingRing`, `RankedPoster`, `PosterShelf`,
  `ContinueShelf`, `FlowLayout`), `Home/` (главная, карусель, разделы, `TitleArt`), `Details/`, `Releases/`,
  `Browse/` (поиск, «Смотреть всё», актёр, медиатека), `Settings/`.
- `Resources/Assets.xcassets` — иконка, акцент, фон запуска.

## Прочее

- `Packages/TorrServerKit` — готовая gomobile-сборка TorrServer (релиз MatriX.147.1, адрес и checksum в `Package.swift`)
  и обёртка `TorrServerEngine` (`start`, `stop`, `isRunning`).
- MPVKit 1.0.0 (mpv 0.41, LGPL-сборка) — пакет из `project.yml`.
- `AerialTests/` — разбор раздач, файлов серий, адресов, ответов TMDb (Swift Testing); `AerialUITests/ScreensTests` —
  снимки экранов и проверка воспроизведения на свободном Big Buck Bunny.
- `.claude/skills/` — скиллы Apple (rshankras/claude-code-apple-skills, MIT; см. `SOURCE-apple-skills.txt`).

## Данные на устройстве

- UserDefaults: настройки (`parser.*`, `torrserver.*`, `tmdbProxy`), медиатека (`library.saved`, `library.entries`).
- Caches: `api-cache/` (TMDb), `images/` (картинки).
- Documents (видно в «Файлах» › На iPhone › Aerial): `logs/app.log`, `logs/mpv.log` (+ `.1` — прошлый запуск),
  `TorrServer/` (база и журнал встроенного сервера).
