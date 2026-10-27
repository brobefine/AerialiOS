# Aerial iOS — карта проекта

Кинотека Aerial для iPhone и iPad: Swift + SwiftUI, видео — libmpv (MPVKit), раздачи — встроенный TorrServer (TorrServerKit).
Брат приложений для Android TV и Windows из `F:\Aerial`: оттуда перенесены каталог TMDb (`VodTmdbClient`), поиск раздач
(`ParserState`, `Torrentio`), клиент TorrServer, разбор названий раздач (`ReleaseInfo.kt`), правило разделов, подбор
«Вам понравится?» (`VodRecommendations`), оценки «Нравится/Обожаю/Не моё», пропуск заставки (`SkipSegments`), загрузки
(`TorrentDownloads`), «Скоро новые серии», подписки на актёров, подсказки поиска (`SearchSuggestions`), оценки MDBList,
ИИ (`AiClient`: поиск по описанию, подбор и подборки по настроению, «Духовные родственники», «Разбор», сводка и перевод
отзывов), отзывы TMDb, история создания из Википедии (`WikiStories`), «Вышли в 4K», OpenSubtitles (ПК), друзья и комнаты
(`Friends`, `WatchParty`), «Вселенные» (готовые стены из `universes-data`), резервная копия. Меняется
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
  Так же Worker друзей и комнат — `AERIAL_API_URL`, `AERIAL_API_TOKEN` (из `aerial.apiUrl`/`aerial.apiToken`; в xcconfig
  адрес без схемы — `AERIAL_API_HOST`, «//» там комментарий) и ключ MDBList приложения — `MDBLIST_API_KEY`
  (`mdblist.apiKey`) → Info.plist `AerialApiHost`, `AerialApiToken`, `MDBListKey` → `Core/BuildKeys`. Нет секретов —
  друзья и комнаты выключены, MDBList — только по ключу пользователя.
- Установка на iPhone — .ipa через Sideloadly или AltStore с Windows (бесплатный Apple ID — подпись на 7 дней).
- Язык Swift 5 (строгая проверка параллельности не включена): без Mac каждая ошибка компиляции стоит круга CI.
- Иконка — `tools/make_icon.py`: знак из вектора ТВ в стекле (Liquid Glass вручную, `.icon` из Icon Composer требует Mac).

## Что где — `Aerial/`

- `App/AerialApp.swift` — вход (`SIGPIPE` выключен: после сна iOS сокеты мёртвые, запись в них убивала процесс;
  встроенный TorrServer в фоне не останавливается, загрузки при возврате продолжаются); `RootView` — вкладки в нижней
  пилюле: «Главная», «Медиатека», «Настройки», «Поиск»; плеер показывает `Playback` через UIKit (`PlayerHostingController`,
  открывается альбомным, поворачивается и в книжную; закрыть — крестик или смахнуть вниз); `UITestHooks` — запуск из UI-тестов (`-uiTest`, `-smokeLink`).
- `Core/` — `Localization` (`AppLanguage` — язык «как в системе»/русский/English, применяется при запуске; в тестах всегда
  русский; `L("…")` — строка интерфейса: русский текст — ключ, перевод — `English.table`, подстановки `%@`; TMDb, даты и ИИ —
  на том же языке), `English` (таблица перевода и формы множественного числа), `CrashGuard` (падения — сигналы и исключения в `logs/crash.log`; выход через exit() — отметка `exit.marker` (так
  перезапускает LiveContainer); как кончился прошлый запуск — «в фоне без
  падения» значит выгрузила система; к записи добавлено, когда ушёл в фон, сколько жил и сколько держал памяти), `Storage` (где данные; в LiveContainer
  база TorrServer — во временной папке процесса: её `flock` на файле в контейнере LiveContainer — 0xdead10cc, выгрузка
  через минуту после сворачивания; старая база копируется туда при первом запуске; `allowSuspendLocked` — атрибут
  `com.apple.runningboard.can-suspend-locked`, как `Dead10ccFix` LiveContainer: файлам базы при старте сервера и всем
  открытым файлам при уходе в фон), `BuildKeys` (ключи сборки из Info.plist), `Log` (журналы `Documents/logs`), `PerfMonitor` (`perf.log`: раз в 15 с
  ЦП, память, нагрев, заряд, яркость, что идёт и как декодируется видео; раз в минуту — СВОДКА: средний и пиковый ЦП, сеть
  Wi‑Fi/сотовая, расход заряда в час, заторы; после ухода в фон фоновое время — только на закрытие раздач, затем «ФОН: сплю через N с»; сторож главного потока в фоне спит на семафоре; у циклов `Task.sleep` — допуск; «ВНИМАНИЕ» — программное декодирование видео; «ЗАТОР» — главный поток молчал > 250 мс; `logs/metrics/` — отчёты и диагностика MetricKit; в `app.log` —
  «ДИАГНОСТИКА»: причины закрытий за сутки (`MXAppExitMetric`: jetsam, лимит памяти, блокировка файла, сторож) и
  код каждого падения; «ФАЙЛЫ» — открытые при уходе в фон, 🔒 — под `flock`), `HTTP`, `DiskCache` (ответы TMDb: срок по виду запроса, при сбое — старый
  ответ), `Text` (`Rx` — NSRegularExpression с просмотром назад; `SearchText`, `Suggestions` — подсказки поиска с раскладкой и опечатками,
  `Format`).
- `Data/` — `Models` (`VodItem`, `VodShelf.accepts`, `CinemaSection`), `TMDb` (прямой API → Worker-прокси, последний
  ответивший маршрут первым; ответы `TMDb*`; `TMDbImage` — CDN, затем Worker), `Catalogue` (ряды разделов, страница фильма,
  сезоны, поиск, актёр, логотип, рекомендации TMDb; `GenreStore`), `AppSettings`, `Library` («Мой список», оценки
  `TasteMark`, прогресс, `WatchSource` — раздача и файл для «Продолжить»; `tasteRevision` — когда пересчитывать подбор),
  `Recommendations` (алгоритм подбора — перенос `VodRecommendations` ТВ; `Taste` — соседи TMDb по оценкам и просмотрам,
  устойчивый порядок «Вам понравится?» по разделу, ряды «Потому что вам понравилось…» — `BecauseRow`), `Feeds`
  («Скоро новые серии» — `UpcomingEpisode` из `next_episode_to_air`; «Новое с вашими актёрами» по подпискам
  `Library.followed`; «Вышли в 4K» — `refreshFourK`), `MdbList` (оценки IMDb/RT/Metacritic: ключ пользователя или
  приложения), `RelativeCriteria`/`RelativeShades` (дерево черт «Духовных родственников»: 50 групп, 138 тонких черт, 4140 формулировок —
  собираются `F:/Aerial/tools/relatives/gen_swift.py`, руками не править), `RelativeRanker` (профили → подборки по сторонам
  фильма «Тоже: …», как на ТВ), `AI.profiles`/`AI.relativeIdeas`, `Catalogue.byKeywords` — кандидаты, `AI` (перенос `AiClient`: Gemini → Groq, ключи пользователя в UserDefaults `ai.*`, ответы в `DiskCache`;
  `Taste.refreshAI` — подбор и подборки по настроению, `Taste.resolve`/`Catalogue.resolve` — название ИИ → работа TMDb),
  `Wiki` (история создания и сюжет по номеру TMDb в Wikidata; `WikiPolicy` — разделы и очистка HTML), `Friends`
  (друзья по кодам, аккаунт устройств по PIN, статус «что смотрю» и стук — `presence` Worker'а), `Backup` (копия
  ключей UserDefaults в plist).
- `Torrents/` — `TorrServerClient` (HTTP-API: add, stat, awaitFiles, preload с ранним стартом, streamURL, settings),
  `Torrents` (`EmbeddedTorrServer` — 127.0.0.1:18090, запускается один раз за жизнь процесса — остановка и повторный
  запуск движка Go обрывали приложение при возврате из фона; настройки кэша; выбор встроенный/внешний;
  `releaseForBackground` — свернули без фильма и загрузки: раздачи закрываются (`drop`), кэш, пиры и сеть не висят во сне;
  свои ретрекеры выключены (`RetrackersMode` 0), раздача без читателей закрывается через 10 с, без uTP, 15 соединений),
  `Release` (`Release`, `ReleaseInfo` — разбор названия, `EpisodeMatch` — файл серии), `ReleaseSearch` (JacRed exact →
  Jackett, плюс `Torrentio`), `AutoPick` (автовыбор раздачи, перенос `autoOpen`/`autoScore` ТВ: оценка по качеству и
  озвучке из настроек `AppSettings.autoRelease/releaseQuality/releaseVoice`, три лучшие открываются разом, первая с
  файлами — победила, на всё 20 с), `DownloadLive` (загрузка в Dynamic Island — Live Activity при обычной установке), `DownloadKeepAlive` (беззвучный
  звук держит приложение живым, пока идёт загрузка; в LiveContainer — определяется по пути приложения — загрузка в Dynamic
  Island плашкой «Сейчас играет»), `ReleaseFacts` (трекеры, год, 3D, языки раздачи для фильтров), `Downloads` (очередь загрузок: файл раздачи с TorrServer → `.part` с докачкой Range
  (`FileFetcher`) → `Documents/Downloads/<работа>`; `localURL` — скачанный файл, `Playback` играет его с диска;
  в фоне не прерывается — [DownloadKeepAlive]).
- `Player/` — `MPVCore` (libmpv: опции, события в главный поток, команды; `MPVViewController` — слой Metal; после
  поворота — перенастройка вывода выключением и включением видео: контекст MoltenVK в MPVKit сам о смене размера не узнаёт),
  `PlayerModel` (TorrServer → подкачка → mpv или скачанный файл; закрыли до начала видео — раздача закрывается (`drop`), иначе сервер искал пиров минутами; время от mpv — не чаще раза в полсекунды, пиры при просмотре — раз в 15 с (батарея); скорость; прогресс каждые 5 с; следующая серия — следующий файл той же раздачи,
  `planNext`; `PlayerScreen` — новая серия открывается новым `PlayerView` в том же окне через `Playback.advance`),
  `PlayerView` (панель как у системного плеера iOS 26–27: −10/пауза/+10 в кругах жидкого стекла по центру видео, стеклянные
  панели сверху и снизу; показ и скрытие — прозрачностью и масштабом (вставка/удаление стекла не анимируется); поворот; справа внизу — «Пропустить заставку» и карточка «Далее» с отсчётом),
  `Native/` — системный плеер (по умолчанию, настройка `player.native`): `NativeEngine` (AVPlayer; протокол
  `PlayerEngine` — общий с `MPVCore`; MP4/MOV напрямую, MKV — через HLS; не справился — событие `.fallback`, и
  `PlayerModel` переходит на mpv; субтитры-текст — своей строкой `subtitleText`), `HLSServer` (127.0.0.1, VOD-плейлист,
  `HLSSession` — отрезки по запросу, следующий заранее, два в памяти; отпущенный сеанс живёт для окна PiP),
  `Remuxer` (FFmpeg из MPVKit: MKV → fMP4 по ключевым кадрам из Cues, видео как есть — HEVC `hvc1`, Dolby Vision 5 —
  `dvh1`, профиль 7 — базовый слой HDR10; AAC/AC3/E-AC3 как есть, остальной звук — `AudioTranscoder` в AAC стерео;
  dts — свои, `tfdt` абсолютный у каждого отрезка), `MP4Writer` (сборщик `mov` в память).
  `SkipSegments` (заставка и титры: IntroDB по IMDb, затем AniSkip через ARM), `OpenSubtitles` (поиск и `sub-add`),
  `WatchParty` (комната: WebSocket к `party/<код>`, действия ещё и POST с повтором до подтверждения, сторож связи;
  `PlayerModel` сверяет ход раз в секунду — `startPartySync`), `PartyViews` (уведомления и реакции поверх видео,
  `PartySheet` — комната, чат; `FriendsView`), `NowPlaying` (экран блокировки и
  «Пункт управления»), `PictureInPicture` (окно PiP через AVPlayer тем же потоком — только MP4/MOV/M4V; развернули — плеер Aerial с той же позиции).
- `UI/` — `Fonts` (Commissioner, как на ТВ: переменный шрифт `Resources/Fonts`, насыщенность — осью `wght`;
  `Font.aerial(.headline, .semibold)`, `.aerial(size:)` — вместо системных во всём приложении), `Theme` (цвета, стекло iOS 26 с запасным материалом и окраской; интерактивное стекло не используется — съедало касания),
  `Palette` (`PosterPalette` — цвет постера, перенос `VodPalette`: им окрашены кнопки страницы фильма и плеер; `RatingsRow` —
  оценки знаками источников и кольцами, как `RatingsRow` ТВ), `CachedImage` (`ImageLoader`: память → диск → сеть,
  уменьшение при декодировании), `Components` (`Route`, `PosterCard` — название и «год · Сериал» на самом постере, на размытом низу, как `posterInfo` ТВ, `MirrorBackdrop` — картинка серии или родственника с прогрессивным размытием вниз (`ProgressiveBlur`: `CIMaskedVariableBlur` по полосе «картинка + зеркало», потолок яркости как на ТВ, один раз в фоне, кэш), `RatingRing`, `RankedPoster`, `PosterShelf`,
  `ContinueShelf`, `FlowLayout`, `TasteLevel`/`TasteMenuItems` — оценка, `PosterMenu` — «Мой список» как на ТВ: «Смотреть позже», убрать из «Продолжить», оценка; им же кнопка страницы фильма),
  `Home/` (главная без баннера: разделы — постраничная горизонтальная прокрутка (`scrollPosition`, свайп и капсулы; не `TabView` — на iOS 27 он не переключался касанием); капсулы — слоем строгой высоты над страницами, листаются свайпом и капсулами `ShelfPicker`/`Chip` (последняя — «Вселенные»);
  под «Продолжить» — «Вам понравится?» и «Потому что…»; `TitleArt`), `Details/` (содержимое скользит поверх неподвижного постера, под постером — его
  зеркало в размытии, под информацией и разделами — одно живое размытие `frost`: вся страница скользит поверх постера, как на ТВ; оценки одной строкой (есть MDBList — без числа голосов TMDb);
  долгое нажатие на серию — описание целиком (не влезает — шрифт мельче); серии с зеркальным размытием кадра), `Releases/`
  (с 27 октября — системным окном поверх страницы фильма, как на ТВ: `ReleasesSheet` по `ReleasesTarget` из
  `DetailsView.watch`; без автовыбора — список `ReleasesView`, касание раздачи переходом в том же окне открывает
  `WatchPane` — сезон и серия из файлов раздачи (у фильма — файл); с автовыбором «Смотреть», кнопка «Другая раздача» и
  карточка серии подбирают раздачу (`AutoPick`) и открывают окно сразу на `WatchPane`; плеер — после закрытия окна;
  `WatchSheet` — тот же `WatchPane` отдельным листом для «Торрентов» медиатеки; озвучка — только в плеере; карточка —
  название и плашки под ним (качество, HDR, кодек, озвучки, субтитры, размер, сиды); фильтр качества — страницы со
  свайпом; сортировка и качество запоминаются; удержание — «Скачать»; в UI-тестах автовыбор выключен),
  `Browse/` (поиск с недавними, подсказками и поиском по описанию (ИИ), «Смотреть всё», актёр с подпиской, медиатека;
  `DownloadsView` — загрузки и их файлы; `TorrentsView` — «Торренты»: раздачи TorrServer, «Добавить торрент»; в Медиатеке — ряд «История»; `UniversesView` — шары разделов и стена `WallView` с зумом), `Settings/`
  (список разделов со значками, как в «Настройках» iOS; у каждого своя страница: раздачи, TorrServer, плеер и субтитры, подбор, каталог, ИИ, «Вместе», данные). `Details/TrailerView` — трейлер YouTube внутри приложения. `Details/DetailsExtras` — `RecapButton` («Разбор» круглой кнопкой в ряду со «Смотреть», как на ТВ: всей работы; не посмотрели — сначала предупреждение о спойлерах; скрытия спойлеров серий нет), «Разбор», «Духовные родственники», отзывы, «Интересные факты» (видны всегда). Разделы страницы — в порядке ТВ;
  капсулы жанров и студий, «Ещё от студии» (`VodDetails.studios/studioFilms`). На главной — ещё `UpcomingShelf`.
- `Resources/Assets.xcassets` — иконка, акцент, фон запуска.

## Прочее

- `AerialWidgets/` — расширение виджетов: Live Activity загрузки (Dynamic Island, экран блокировки); `Shared/DownloadActivity.swift` —
  атрибуты, общие с приложением. Info.plist расширения — `Config/Widgets-Info.plist` (генерирует XcodeGen).

- `Packages/TorrServerKit` — gomobile-сборка TorrServer MatriX.147.1 с правками `patches/aerial-energy.patch` (полный GC
  при вытеснении кэша — не чаще раза в 30 с; `SetRuntime`, `FreeMemory`). Собирает задача CI `torrserverkit`
  (`.github/workflows/torrserverkit.yml`, запуск вручную) в релиз `torrserverkit-<версия>-aerial<n>` этого репозитория;
  адрес и checksum — в `Package.swift`. Обёртка `TorrServerEngine`: `start`, `stop`, `isRunning`, `setRuntime` (при старте —
  GOGC 200, лимит кэш + 128 МБ, 2 потока), `freeMemory` (после закрытия раздач в фоне).
- MPVKit 1.0.0 (mpv 0.41, LGPL-сборка) — пакет из `project.yml`.
- `AerialTests/` — разбор раздач, файлов серий, адресов, ответов TMDb, подбор (`RecommendationsTests`), подсказки, MDBList, имена загрузок, ответы ИИ, Википедия, комната (`FeaturesTests`), системный плеер — перепаковка тестовых MKV из
  `AerialTests/Media` и их показ через AVPlayer (`NativePlayerTests`) (Swift Testing); `AerialUITests/ScreensTests` —
  снимки экранов и проверка воспроизведения на свободном Big Buck Bunny.
- `docs/port-gaps.md` — сверка с приложением для ТВ: что перенесено и чего нет (с причинами).
- `reports/` и `research_notes/` — исследования (энергопотребление, LiveContainer, mpv, Go TorrServer) и заметки к ним.
- `.claude/skills/` — скиллы Apple (rshankras/claude-code-apple-skills, MIT; см. `SOURCE-apple-skills.txt`).

## Данные на устройстве

- UserDefaults: настройки (`parser.*`, `torrserver.*`, `tmdbProxy`, `taste.history`, `player.autoplayNext`, `player.native`, `mdblist.key`,
  `mdblist.blocked`, `mdblist.shown`, `mdblist.sources`, `episodes.overviews`, `episodes.hideSpoilers`, `app.language`, `ui.posterSize`, `ui.actorPhoto`, `ui.titleLogos`, `releases.sort`, `releases.quality`, `search.recent`, `ai.*`, `opensubs.*`, `reviews.sort`), запуск (`session.state`, `session.background` — для «ПРОШЛЫЙ ЗАПУСК»), медиатека (`library.saved`, `library.entries`,
  `library.marks`, `library.followed`), друзья (`friends.*`), подбор (`taste.related`, `taste.relatedKey`, `taste.forYou.<раздел>`, `taste.ai*`), `feeds.fourK*`.
- Caches: `api-cache/` (TMDb, MDBList, ИИ, Википедия, списки «Вселенных»), `images/` (картинки). Application Support: `downloads.json` — список загрузок.
- Documents (видно в «Файлах» › На iPhone › Aerial): `logs/app.log`, `logs/mpv.log`, `logs/perf.log` (+ `.1` — прошлый запуск), `logs/metrics/` (MetricKit),
  `TorrServer/` (база и журнал встроенного сервера; в LiveContainer — во временной папке, журнал — через
  «Поделиться журналами»), `Downloads/` (скачанные фильмы и серии; без резервной копии iCloud).
