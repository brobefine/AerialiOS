# Aerial iOS — карта проекта

Кинотека Aerial для iPhone и iPad: Swift + SwiftUI, видео — libmpv (MPVKit), раздачи — встроенный TorrServer (TorrServerKit).
Брат приложений для Android TV и Windows из `F:\Aerial`: оттуда перенесены каталог TMDb (`VodTmdbClient`), поиск раздач
(`ParserState`, `Torrentio`), клиент TorrServer, разбор названий раздач (`ReleaseInfo.kt`), правило разделов, подбор
«Вам понравится?» (`VodRecommendations`), оценки «Нравится/Обожаю/Не моё», пропуск заставки (`SkipSegments`), загрузки
(`TorrentDownloads`), «Скоро новые серии», подписки на актёров, подсказки поиска (`SearchSuggestions`), оценки MDBList. Меняется
поведение там — сверить здесь. Вид — по образцу приложения Apple TV для iPhone, с цветами Aerial (#7FDCFF, #3E7BEA).

**Документация — часть изменения.** Переносишь, переименовываешь, добавляешь файл или меняешь путь данных — в той же
правке обнови этот файл. Код и описание расходиться не должны.

## Сборка (Mac нет)

- Проект Xcode генерирует XcodeGen из `project.yml`; `*.xcodeproj` и `Config/Info.plist` в git не хранятся.
- CI — `.github/workflows/build.yml` (`macos-26`, Xcode 26.6): задачи параллельно — `screens` (модульные тесты и
  `testScreens` на iPhone 17 Pro, iOS 26.5), `player` (`testPlaybackSmoke`), `ipa` (неподписанный `Aerial.ipa`); `ipad`
  (`testTabletScreens` на iPad Pro 11") — только при ручном запуске с галочкой. Симулятор грузится **после** сборки:
  загрузка в фоне отнимала процессор и диск — пакеты шли 330 с вместо 33, сборка 178 с вместо 42. Кэша пакетов нет —
  не ускорял. XcodeGen — готовый из релиза; в UI-тестах анимации выключены (`UITestHooks`).
  Пользователь просил прогон за несколько минут: все проверки — в одном прогоне, новые шаги — в `ScreensTests`,
  ждать элементы, а не секунды. Артефакты: `Aerial-ipa`, `Aerial-check-<задача>` — снимки `screens/`, журналы `logs/`
  (`build.log`, `test.log`, `test-results.json`, `archive.log`; с симулятора — `app/app.log`, `app/mpv.log`,
  журналы TorrServer).
  Скачать: `gh run download <id> -R brobefine/AerialiOS`. Репозиторий открытый — минуты macOS не считаются.
- Ключи TMDb — секреты репозитория `TMDB_API_KEY`, `TMDB_READ_TOKEN` → `Config/Secrets.xcconfig` (не в git) → Info.plist
  (`TMDBApiKey`, `TMDBReadToken`). Значения — из `tmdb.apiKey`/`tmdb.readToken` в `F:\Aerial\local.properties`.
- Установка на iPhone — .ipa через Sideloadly или AltStore с Windows (бесплатный Apple ID — подпись на 7 дней).
- Язык Swift 5 (строгая проверка параллельности не включена): без Mac каждая ошибка компиляции стоит круга CI.
- Иконка — `tools/make_icon.py`: знак из вектора ТВ в стекле (Liquid Glass вручную, `.icon` из Icon Composer требует Mac).

## Что где — `Aerial/`

- `App/AerialApp.swift` — вход (`SIGPIPE` выключен: после сна iOS сокеты мёртвые, запись в них убивала процесс;
  в фоне без фильма и загрузки встроенный TorrServer останавливается, при возврате поднимается, загрузки продолжаются); `RootView` — вкладки в нижней
  пилюле: «Главная», «Медиатека», «Настройки», «Поиск»; плеер показывает `Playback` через UIKit (`PlayerHostingController`,
  альбомная ориентация); `UITestHooks` — запуск из UI-тестов (`-uiTest`, `-smokeLink`).
- `Core/` — `Log` (журналы `Documents/logs`), `HTTP`, `DiskCache` (ответы TMDb: срок по виду запроса, при сбое — старый
  ответ), `Text` (`Rx` — NSRegularExpression с просмотром назад; `SearchText`, `Suggestions` — подсказки поиска с раскладкой и опечатками,
  `Format`).
- `Data/` — `Models` (`VodItem`, `VodShelf.accepts`, `CinemaSection`), `TMDb` (прямой API → Worker-прокси, последний
  ответивший маршрут первым; ответы `TMDb*`; `TMDbImage` — CDN, затем Worker), `Catalogue` (ряды разделов, страница фильма,
  сезоны, поиск, актёр, логотип, рекомендации TMDb; `GenreStore`), `AppSettings`, `Library` («Мой список», оценки
  `TasteMark`, прогресс, `WatchSource` — раздача и файл для «Продолжить»; `tasteRevision` — когда пересчитывать подбор),
  `Recommendations` (алгоритм подбора — перенос `VodRecommendations` ТВ; `Taste` — соседи TMDb по оценкам и просмотрам,
  устойчивый порядок «Вам понравится?» по разделу, ряды «Потому что вам понравилось…» — `BecauseRow`), `Feeds`
  («Скоро новые серии» — `UpcomingEpisode` из `next_episode_to_air`; «Новое с вашими актёрами» по подпискам
  `Library.followed`), `MdbList` (оценки IMDb/RT/Metacritic по ключу пользователя).
- `Torrents/` — `TorrServerClient` (HTTP-API: add, stat, awaitFiles, preload с ранним стартом, streamURL, settings),
  `Torrents` (`EmbeddedTorrServer` — 127.0.0.1:18090, перезапуск после сна, настройки кэша; выбор встроенный/внешний),
  `Release` (`Release`, `ReleaseInfo` — разбор названия, `EpisodeMatch` — файл серии), `ReleaseSearch` (JacRed exact →
  Jackett, плюс `Torrentio`), `Downloads` (очередь загрузок: файл раздачи с TorrServer → `.part` с докачкой Range
  (`FileFetcher`) → `Documents/Downloads/<работа>`; `localURL` — скачанный файл, `Playback` играет его с диска;
  в фоне iOS даёт полминуты, при возврате очередь продолжается).
- `Player/` — `MPVCore` (libmpv: опции, события в главный поток, команды; `MPVViewController` — слой Metal),
  `PlayerModel` (TorrServer → подкачка → mpv или скачанный файл; скорость; прогресс каждые 5 с; следующая серия — следующий файл той же раздачи,
  `planNext`; `PlayerScreen` — новая серия открывается новым `PlayerView` в том же окне через `Playback.advance`),
  `PlayerView` (панель в духе Apple TV, поворот; справа внизу — «Пропустить заставку» и карточка «Далее» с отсчётом),
  `SkipSegments` (заставка и титры: IntroDB по IMDb, затем AniSkip через ARM), `NowPlaying` (экран блокировки и
  «Пункт управления»).
- `UI/` — `Theme` (цвета, стекло iOS 26 с запасным материалом), `CachedImage` (`ImageLoader`: память → диск → сеть,
  уменьшение при декодировании), `Components` (`Route`, `PosterCard`, `RatingRing`, `RankedPoster`, `PosterShelf`,
  `ContinueShelf`, `FlowLayout`, `TasteLevel`/`TasteMenuItems` — оценка, `PosterMenu` — меню постера по долгому нажатию),
  `Home/` (главная без баннера: разделы — страницы `TabView`, листаются свайпом и капсулами `ShelfPicker`/`Chip`;
  под «Продолжить» — «Вам понравится?» и «Потому что…»; `TitleArt`), `Details/` (содержимое скользит поверх неподвижного постера, под постером — его
  зеркало в размытии, под информацией — живое размытие `frost`; серии с зеркальным размытием кадра), `Releases/`
  (карточки, фильтр качества — страницы со свайпом; сортировка и качество запоминаются; удержание — «Скачать»),
  `Browse/` (поиск с недавними и подсказками, «Смотреть всё», актёр с подпиской, медиатека; `DownloadsView` —
  загрузки и их файлы), `Settings/`. На главной — ещё `UpcomingShelf`.
- `Resources/Assets.xcassets` — иконка, акцент, фон запуска.

## Прочее

- `Packages/TorrServerKit` — готовая gomobile-сборка TorrServer (релиз MatriX.147.1, адрес и checksum в `Package.swift`)
  и обёртка `TorrServerEngine` (`start`, `stop`, `isRunning`).
- MPVKit 1.0.0 (mpv 0.41, LGPL-сборка) — пакет из `project.yml`.
- `AerialTests/` — разбор раздач, файлов серий, адресов, ответов TMDb, подбор (`RecommendationsTests`), подсказки, MDBList, имена загрузок (`FeaturesTests`) (Swift Testing); `AerialUITests/ScreensTests` —
  снимки экранов и проверка воспроизведения на свободном Big Buck Bunny.
- `.claude/skills/` — скиллы Apple (rshankras/claude-code-apple-skills, MIT; см. `SOURCE-apple-skills.txt`).

## Данные на устройстве

- UserDefaults: настройки (`parser.*`, `torrserver.*`, `tmdbProxy`, `taste.history`, `player.autoplayNext`, `mdblist.key`,
  `mdblist.blocked`, `releases.sort`, `releases.quality`, `search.recent`), медиатека (`library.saved`, `library.entries`,
  `library.marks`, `library.followed`), подбор (`taste.related`, `taste.relatedKey`, `taste.forYou.<раздел>`).
- Caches: `api-cache/` (TMDb, MDBList), `images/` (картинки). Application Support: `downloads.json` — список загрузок.
- Documents (видно в «Файлах» › На iPhone › Aerial): `logs/app.log`, `logs/mpv.log` (+ `.1` — прошлый запуск),
  `TorrServer/` (база и журнал встроенного сервера), `Downloads/` (скачанные фильмы и серии; без резервной копии iCloud).
