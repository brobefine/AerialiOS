# LiveContainer и SideStore: батарея, фон и выгрузка гостевого приложения (Aerial)

Состояние на 25.10.2026. Исходники LiveContainer (LC) — `main` @ `9108ae6` (17.10.2026, версия в Info.plist 3.8.11; последний стабильный релиз — 3.8.0 от 17.07.2026, nightly — 17.10.2026). Ссылки на файлы ведут на `main`.
Сокращения: LC = LiveContainer, SS = SideStore, RB = RunningBoard (`runningboardd`), LP = LiveProcess (расширение для многозадачного режима).

## 1. Как многозадачный режим запускает гостя и что гость получает, когда LC уходит в фон

### Takeaway
В многозадачном режиме гость — отдельный процесс-**расширение** `LiveProcess.appex` (точка `com.apple.ar.viewer`, `_ProcessType App`), его сцену LC показывает у себя через `_UISceneHostingController` (iOS 18+) или FBScene (ниже). На iOS 18+ уведомления «хост ушёл в фон» больше не приходят через NSExtension — гость получает обычный `UIApplicationDidEnterBackgroundNotification` от FBSSceneObserver; а `Dead10ccFix` в `main` слушает в LiveProcess только `NSExtensionHostDidEnterBackgroundNotification`. Это и есть регрессия 0xdead10cc (#1491): исправлена в ветке `multitask-experimental`, но **в `main` и в релизы не попала**.

### Cited Findings
- LC создаёт процесс через `[NSExtension extensionWithIdentifier:LCUtils.liveProcessBundleIdentifier]` и `beginExtensionRequestWithInputItems:`; в `userInfo` — bundle id гостя, UUID контейнера, `lcHomePath`, security-scoped bookmarks (на папку приложения, контейнер данных, Tweaks или на весь Documents LC). PID берётся из `pidForRequestIdentifier:`. Выход процесса отслеживают `setRequestInterruptionBlock`/`setRequestCancellationBlock` → `appTerminationCleanUp` (сцена удаляется, окно показывает «App terminated») — [AppSceneViewController.m](https://github.com/LiveContainer/LiveContainer/blob/main/MultitaskSupport/AppSceneViewController.m)
- Сцена: `RBSProcessHandle handleForPredicate:` по PID → `FBProcessManager registerProcessForAuditToken:`; на iOS 18+ — `_UISceneHostingControllerAdvancedConfiguration initWithProcessIdentity:` + `_UISceneHostingController`, настройки сцены `foreground = YES`, `level = 1`, `persistenceIdentifier = dataUUID`; ниже iOS 18 — `FBSceneManager createSceneWithDefinition:` и `uiPresentationManager createPresenterWithIdentifier:` — [AppSceneViewController.m](https://github.com/LiveContainer/LiveContainer/blob/main/MultitaskSupport/AppSceneViewController.m)
- Новый API сцены поднят до iOS 18+ коммитом `87794c6` «Fix #1477: raise new multitask scene API to iOS 18» (26.07.2026) — [commit list](https://github.com/LiveContainer/LiveContainer/commits/main)
- На пути iOS 18+ LC явно снимает NSExtension с наблюдения `UIApplicationDidBecomeActive/WillResignActive/DidEnterBackground/WillEnterForeground` хоста с комментарием «For new API, let FBSSceneObserver send host scene events instead of NSExtensionContext» — то есть `NSExtensionHostDidEnterBackgroundNotification` в гостя не форвардится — [AppSceneViewController.m](https://github.com/LiveContainer/LiveContainer/blob/main/MultitaskSupport/AppSceneViewController.m)
- `Info.plist` расширения: `NSExtensionPointIdentifier = com.apple.ar.viewer`, `NSExtensionActivationRule = FALSEPREDICATE`, `XPCService { ServiceType = Application, _MultipleInstances = true, _ProcessType = App }`, `UIBackgroundModes` = audio, bluetooth-central, external-accessory, fetch, location, nearby-interaction, remote-notification, voip — [LiveProcess/Info.plist](https://github.com/LiveContainer/LiveContainer/blob/main/LiveProcess/Info.plist)
- `main.m` расширения: перехватывает `NSExtensionMain`, подменяет `dlopen` UIKit, свой `UIApplicationMain` ждёт `beginRequestWithExtensionContext:` (через `CFRunLoopRun/Stop`), затем `LiveContainerMain` — гость стартует как обычное приложение внутри процесса расширения — [LiveProcess/main.m](https://github.com/LiveContainer/LiveContainer/blob/main/LiveProcess/main.m)
- В процессе LP: `HOME`/`CFFIXED_USER_HOME` = контейнер гостя (в App Group у общих приложений — `…/Data/Application/<uuid>` в группе; у приватных — в Documents LC через bookmark), а `TMPDIR` **не меняется** (остаётся tmp самого расширения); `<home>/tmp` — симлинк на него — [LCBootstrap.m](https://github.com/LiveContainer/LiveContainer/blob/main/LiveContainer/LCBootstrap.m)
- Документация: многозадачный режим требует «Convert the target app to Shared App» и установку с «Keep App Extensions»; режимы Virtual Window (плавающие окна, док, PiP) и Native Window (iPadOS 16.1+); есть «Restart Terminated App» и «Skip Terminated Screen» — [LC docs: Multitask](https://livecontainer.github.io/docs/guides/multitask)
- Журнал RB из #1329 показывает гостевой процесс как `xpcservice<com.kdt.livecontainer.<TEAM>.LiveProcess([app<com.kdt.livecontainer…>:6343])>` с `definition:…LiveProcess[extension][client]` и состоянием `running-active-NotVisible` — то есть RB видит гостя как XPC-сервис, принадлежащий процессу LC — [issue #1329](https://github.com/LiveContainer/LiveContainer/issues/1329)
- Исправление #1491 (коммит `e98699a`, 30.07.2026, «Fix #1491: 0xdead10cc regression») регистрирует `Dead10ccFix` на **оба** уведомления с комментарием «depending on Scene API, it could invoke either of these, so just register both» и включает его для всех гостей; коммит лежит в `multitask-experimental`. Сравнение веток на 25.10.2026: `main...multitask-experimental` — diverged, ahead 11 / behind 37; в `main` (9108ae6) `initDead10ccFix` по-прежнему старый — [commit e98699a](https://github.com/LiveContainer/LiveContainer/commit/e98699a), [Dead10ccFix.m в main](https://github.com/LiveContainer/LiveContainer/blob/main/LiveContainer/Tweaks/Dead10ccFix.m), [issue #1491](https://github.com/LiveContainer/LiveContainer/issues/1491)
- В #1491 мейнтейнер: «Should be fixed now», затем участник: «You may have pushed to `multitask-experimental` instead of `main`», ответ: «Mb yeah I forgot the regressed commit was in main branch, might aswell merge it soon» — [issue #1491](https://github.com/LiveContainer/LiveContainer/issues/1491)

### Inferences
- На iOS 26–27 в `main`/nightly/3.8.0 автоматическая защита LC от 0xdead10cc в многозадачном режиме фактически **не срабатывает**: гость получает `UIApplicationDidEnterBackgroundNotification`, а LP-ветка `Dead10ccFix` ждёт `NSExtensionHostDidEnterBackgroundNotification`. Тогда единственная защита — то, что ставит само приложение (Aerial уже ставит xattr в `Storage.allowSuspendLocked`).
- «Другие гостевые приложения живут» объяснимо: у большинства нет постоянного `flock` на файл вне собственного контейнера процесса, а у Aerial он есть (bbolt TorrServer).
- Гость получает обычные UIKit-уведомления жизненного цикла сцены (resign active → enter background), т. к. LC пробрасывает состояние сцены хоста; во время PiP LC держит сцену гостя `foreground = YES` (см. раздел 4).

### Gaps
- Не найдено точное правило, по которому RB приостанавливает процесс LP, когда LC ушёл в фон (наследует ли LP приоритет/ассершены хоста). Видно только `running-active-NotVisible` в журнале.
- Неизвестно, войдёт ли `e98699a` в следующий релиз.

## 2. Известные проблемы с выгрузкой гостей в фоне (0xdead10cc, jetsam, утечка FD) и их исправления

### Takeaway
Главная причина «закрылся в фоне» внутри LC — **0xdead10cc** (RB убивает приостановленный процесс, держащий замок на файле вне разрешённых папок). У LC есть обход `Dead10ccFix` (ставит xattr `com.apple.runningboard.can-suspend-locked=1` на заблокированные файлы), но у него была история регрессий, а до 17.10.2026 — утечка дескрипторов при каждом опросе (каждые 2 с в фоне).

### Cited Findings
- Apple: 0xdead10cc — «The operating system terminated the app because it held on to a file lock or SQLite database lock during suspension… In an app extension, use `ProcessInfo.beginActivity(options:reason:)` to manage this work»; namespace RUNNINGBOARD. Там же 0x2182bad2 — «background task failing to complete in time» — [Apple: SIGKILL](https://developer.apple.com/documentation/xcode/sigkill)
- Quinn (Apple DTS): «It's _always_ unsafe for an app to hold a file lock while it's suspended»; до iOS 14 проверка срабатывала не всегда, в iOS 14 её починили, с 14.0b7 сделали «more forgiving». Воспроизведение в треде — `flock()` на файле в общем контейнере; в консоли RB: «was suspended with locked system files:/var/mobile/Containers/Shared/AppGroup/…/default.realm.lock not in allowed directories:/var/mobile/Containers/Data/Application/…» (строка — из поста разработчика, не Quinn) — [Apple Forums 655225](https://developer.apple.com/forums/thread/655225)
- Алгоритм RB, повторённый в LC по гисту JJTech: перебор FD процесса (`proc_pidinfo PROC_PIDLISTFDS`) → только обычные файлы → пропуск `-shm/-wal/-journal` → пропуск файлов с xattr `com.apple.runningboard.can-suspend-locked` ≠ 0 → SQLite проверяется `_sqlite3_lockstate`, прочее — `fcntl(F_GETLKPID)` — [Dead10ccFix.m](https://github.com/LiveContainer/LiveContainer/blob/main/LiveContainer/Tweaks/Dead10ccFix.m)
- История `Dead10ccFix.m`: `a57aadb` (23.05.2025) «Fix 0xdead10cc» — первая версия, раз при уходе в фон; `547eff5` (24.05.2025); `85ca272` (31.07.2025, вошло в 3.6.0) «Potentially fix app crash in the background» — сканирование перенесено на момент, когда число фоновых задач дошло до нуля (ворует `-[UIApplication _handleTaskCompletionAndTerminate:]`), и повторяется каждые 2 с, пока приложение не активно; `bdc07ed` (17.10.2026) «Fix mem leak in Dead10ccFix #1653» — добавлены `close(fd)` и `free(pidinfo)` — [история файла](https://github.com/LiveContainer/LiveContainer/commits/main/LiveContainer/Tweaks/Dead10ccFix.m), [bdc07ed](https://github.com/LiveContainer/LiveContainer/commit/bdc07ed)
- В `main` Dead10ccFix включается только в LP (по `NSExtensionHostDidEnterBackgroundNotification`) и для общих приложений в обычном режиме (по `UIApplicationDidEnterBackgroundNotification`); для SideStore — нет — [Dead10ccFix.m](https://github.com/LiveContainer/LiveContainer/blob/main/LiveContainer/Tweaks/Dead10ccFix.m), [LCBootstrap.m](https://github.com/LiveContainer/LiveContainer/blob/main/LiveContainer/LCBootstrap.m)
- #1653 (BiliMusic, iOS 18.5, nightly 3.8.10): в фоне ~56–58 новых FD в минуту на одни и те же системные файлы (metallib, шрифт PingFang), рост останавливается при возврате на передний план; в длинном прогоне достигнут мягкий лимит процесса 2560 FD — после этого ломаются обложки и кэш. Закрыт 17.10.2026 — [issue #1653](https://github.com/LiveContainer/LiveContainer/issues/1653)
- #858: «opening lock fifo for writing failed: Too many open files» (Realm) после ~5 мин музыки в фоне, в режиме Shared App; в приватном режиме — нормально — [issue #858](https://github.com/LiveContainer/LiveContainer/issues/858)
- #1186 (открыт): Duolingo в LC 3.7.0 (обычный режим, iOS 17.6) выгружается через 10–30 с фона, в 3.6.1 жил >10 мин; в отчёте `Namespace RUNNINGBOARD, Code 3735883980` = 0xDEAD10CC, процесс `LiveContainer` — [issue #1186](https://github.com/LiveContainer/LiveContainer/issues/1186)
- #1491 (закрыт 30.07.2026): iOS 26.5.2, nightly 3.8.2: гость закрывается при каждом уходе из LC; отчёт — процесс `LiveProcess`, `bundleID com.kdt.livecontainer.<TEAM>.LiveProcess`, `termination {namespace: RUNNINGBOARD, code: 3735883980}` (0xdead10cc), гость — YouTube из `/var/mobile/Containers/Data/Application/<LC>/Documents/Applications/…` (проверено по вложению log.3.txt) — [issue #1491](https://github.com/LiveContainer/LiveContainer/issues/1491)
- #1096: X выгружался в фоне; причина — твик, блокировавший HTTP, RB: `code:0x2182BAD2 explanation:Timed-out waiting for process … to invalidate assertion … 'Shared Background Assertion 39 for com.atebits.Tweetie2'` — фоновая задача не завершилась вовремя — [issue #1096](https://github.com/LiveContainer/LiveContainer/issues/1096)
- #1595 (iOS 27.0 beta, 3.8.10): «I also noticed apps gets terminated much quicker in multitask mode»; #1596 (открытый PR) — окно после выгрузки «jetsammed» гостя — [issue #1595](https://github.com/LiveContainer/LiveContainer/issues/1595), [PR #1596](https://github.com/LiveContainer/LiveContainer/pull/1596)
- #1329: тяжёлая игра в многозадачном режиме — мейнтейнер: «very memory and cpu/gpu intensive… killed by iOS when entering background»; реальной причиной падения оказалось переполнение стека в коде LC — [issue #1329](https://github.com/LiveContainer/LiveContainer/issues/1329)
- Где искать: Настройки → Конфиденциальность → Аналитика → Данные аналитики, файлы `LiveProcess-*.ips` (многозадачный режим) или `LiveContainer-*.ips` (обычный); jetsam — `JetsamEvent-*.ips` — [issue #1491](https://github.com/LiveContainer/LiveContainer/issues/1491), [issue #1186](https://github.com/LiveContainer/LiveContainer/issues/1186)

### Inferences
- «Разрешённые папки» для RB — собственный контейнер данных процесса. У LP это `…/Data/PluginKitPlugin/<uuid>/` (включая его tmp), а данные гостя лежат в контейнере LC или в App Group → любой замок там = 0xdead10cc. Подтверждается #1491 (приватный гость в контейнере LC тоже убит). Поэтому перенос базы TorrServer в `confstr(_CS_DARWIN_USER_TEMP_DIR)` в Aerial — верный шаг.
- Утечка из #1653 срабатывала на **каждый** открытый обычный не-SQLite файл без xattr при каждом опросе (раз в 2 с): `open()` без `close()`. До `bdc07ed` (то есть в 3.8.0 и nightly до 17.10.2026) у Aerial с открытыми журналами (`app.log`, `mpv.log`, `perf.log`), шрифтами, файлами mpv/TorrServer и `.part` загрузок это десятки FD в минуту на каждый файл → до лимита 2560 — минуты. Для Go-рантайма (TorrServer) и mpv исчерпание FD = ошибки `EMFILE` и возможное падение. Это стоит проверить в `perf.log` (число FD) как вторую гипотезу после 0xdead10cc.
- Сам опрос Dead10ccFix раз в 2 с всё время, пока процесс не приостановлен (перебор всех FD, `stat`, `open`, `fcntl`), — небольшая, но постоянная нагрузка на ЦП в фоне.
- Поскольку сканирование ждёт «счётчик фоновых задач = 0», открытые `beginBackgroundTask` (у Aerial — `perf-heartbeat` 20 с и `downloads`) откладывают и проверку, и приостановку; если задача не закрыта вовремя — риск уже 0x2182BAD2.
- Тайминг «~1 минута» у Aerial согласуется с: 20 с пульса + до ~30 с фоновой задачи → приостановка → проверка RB → 0xdead10cc. Это вывод, не измерение.

### Gaps
- Не проверено, видит ли `fcntl(F_GETLKPID)` замки `flock()` (bbolt на Darwin использует `flock`). Если не видит, Dead10ccFix LC не поставит xattr на базу bbolt даже там, где он срабатывает, а RB (по треду 655225) `flock` ловит. Источника на внутреннюю проверку RB для `flock` против `fcntl` не нашёл.
- Код причины выгрузки Aerial неизвестен: нужен `LiveProcess-*.ips` (0xdead10cc / 0x2182bad2 / jetsam).

## 3. Лимиты памяти и полосы jetsam у расширений и приложений; действует ли increased-memory-limit в LiveProcess

### Takeaway
Официальной таблицы лимитов памяти для расширений нет; у каждой точки расширения свой лимит, и по словам Apple DTS он **перекрывает** `increased-memory-limit`. LP объявляет точку `com.apple.ar.viewer`, но запускается как `_ProcessType App`; фактический лимит нужно мерить `os_proc_available_memory()`.

### Cited Findings
- `LiveProcess.entitlements` содержит `com.apple.developer.kernel.increased-memory-limit = true`, `get-task-allow`, HealthKit, общие App Group SideStore/AltStore и 128 групп связки ключей — [LiveProcess.entitlements](https://github.com/LiveContainer/LiveContainer/blob/main/LiveProcess/LiveProcess.entitlements)
- Apple DTS (тред про Quick Look-расширение, упиравшееся в 100 МБ): каждая точка расширения задаёт свой лимит памяти, и он перекрывает значение, которое меняет «Increased Memory Limit» — [Apple Forums 779756](https://developer.apple.com/forums/thread/779756)
- Apple: entitlement повышает лимит только на части моделей и не обещает конкретной величины — [Apple docs: increased-memory-limit](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit)
- Сообщения разработчиков: `os_proc_available_memory()` не менялся после включения entitlement — [Apple Forums 770868](https://developer.apple.com/forums/thread/770868), [Apple Forums 740831](https://developer.apple.com/forums/thread/740831)
- Отчёты jetsam — `JetsamEvent-*.ips`, поле `reason` (`per-process-limit` = превышен лимит процесса); jetsam выбирает процессы с низким приоритетом (idle, suspended) — [Esri KB](https://support.esri.com/en-us/knowledge-base/analyst-knowledge-field-maps-application-crashes-when-v-000041358), [Tencent Cloud article](https://cloud.tencent.com/developer/article/1662232)
- Вспомогательный процесс ReplayKit `replayd` убивается jetsam с причиной `highwater`; на форуме спрашивают, есть ли фиксированный лимит, и официального ответа нет — [Apple Forums 706972](https://developer.apple.com/forums/thread/706972)

### Inferences
- Раз LP запускается с `_ProcessType App` и получает сцену, вероятно, RB даёт ему приложенческую полосу, пока сцена видима; в фоне — фоновую. Но это не подтверждено.
- Для Aerial (libmpv + Go TorrServer с кэшем в памяти) в фоне многозадачного режима нужно уменьшать память: при уходе в фон сбрасывать кэш изображений, урезать кэш TorrServer — иначе в суммарной памяти (LC-хост + LP) вероятнее jetsam.

### Gaps
- Нет первоисточника о полосе jetsam (JETSAM_PRIORITY_*) для процесса LP и о лимите точки `com.apple.ar.viewer`.

## 4. Работают ли UIBackgroundModes (audio) гостя в LiveProcess; как в многозадачном режиме играют звук и PiP

### Takeaway
Фоновые режимы гостя не берутся из его Info.plist: действуют те, что объявлены в Info.plist самого LiveProcess (audio, fetch, location, voip и др. — есть). Фоновое воспроизведение «как у YouTube» в многозадачном режиме LC делает через **собственный PiP хоста**: окно гостя переносится в `AVPictureInPictureVideoCallViewController`, хост держит активную сессию `Playback`, а сцена гостя принудительно остаётся `foreground`.

### Cited Findings
- LP Info.plist: `UIBackgroundModes` = audio, bluetooth-central, external-accessory, fetch, location, nearby-interaction, remote-notification, voip; у основного приложения LC — тот же набор — [LiveProcess/Info.plist](https://github.com/LiveContainer/LiveContainer/blob/main/LiveProcess/Info.plist), [LiveContainer/Info.plist](https://github.com/LiveContainer/LiveContainer/blob/main/LiveContainer/Info.plist)
- `PiPManager init`: `AVAudioSession setCategory:Playback` и `setActive:YES` в хосте; при старте PiP вид гостя кладётся в `AVPictureInPictureVideoCallViewController`, вызывается `setBackgroundNotificationEnabled:false` и `shouldIgnoreSceneUpdates = YES` — [PiPManager.m](https://github.com/LiveContainer/LiveContainer/blob/main/MultitaskSupport/PiPManager.m)
- `setBackgroundNotificationEnabled:` на новом API ставит сцене `foreground = YES, deactivationReasons = 0`; на старом — снимает форвардинг `DidEnterBackground` с комментарием «so apps like YouTube can continue playing video» — [AppSceneViewController.m](https://github.com/LiveContainer/LiveContainer/blob/main/MultitaskSupport/AppSceneViewController.m)
- Настройки «Auto End PiP» и отдельный переключатель PiP по приложению (#1607/#1608) — [LC docs: Multitask](https://livecontainer.github.io/docs/guides/multitask), [issue #1607](https://github.com/LiveContainer/LiveContainer/issues/1607)
- #870: в многозадачном режиме на iOS 17/18 видео и звук во многих браузерах не играли (на iOS 16 работало); закрыт 20.06.2026 — [issue #870](https://github.com/LiveContainer/LiveContainer/issues/870)
- #1653: BiliMusic продолжает играть звук в фоне внутри LC (с утечкой FD) — фоновый звук гостя в принципе работает — [issue #1653](https://github.com/LiveContainer/LiveContainer/issues/1653)

### Inferences
- Беззвучный звук Aerial (`DownloadKeepAlive`) внутри LP должен работать как фоновое аудио, раз `audio` объявлен в LP. Но 0xdead10cc проверяется только при приостановке: пока звук держит процесс активным, замок безопасен; когда звук остановлен — процесс приостанавливается, и всё решает xattr/отсутствие замков.
- PiP «как в LC» (весь вид гостя в окно видеозвонка) держит гостя на переднем плане и, значит, тратит заряд как работающее приложение: рендер сцены, GPU, сеть.

### Gaps
- Не найдено, получает ли процесс LP собственный ассершен RB за активную аудиосессию, если хост LC при этом приостановлен.

## 5. SideStore: подпись бесплатным Apple ID, 7 дней, LocalDevVPN/StosVPN/minimuxer, JIT — и влияние на батарею и гостей

### Takeaway
SS переподписывает приложения сертификатом бесплатного Apple ID (7 дней, 3 приложения, 10 App ID в неделю) и обновляет подпись в фоне через петлевой «VPN» на устройстве (LocalDevVPN; раньше StosVPN/WireGuard), через который `minimuxer` говорит с lockdownd самого телефона. По FAQ SS, VPN не тратит батарею, потому что не ходит на внешние серверы; прямых измерений расхода не найдено. На гостей LC он влияет только через истечение подписи и через перезапуск LC.

### Cited Findings
- FAQ SS: стандартный 7-дневный срок разработчика, SS «will periodically "refresh" your apps in the background»; с бесплатным аккаунтом — только 3 приложения (включая сам SS) и не больше 10 App ID за неделю; платный аккаунт — срок 365 дней — [SideStore FAQ](https://docs.sidestore.io/docs/faq)
- FAQ SS: VPN нужен, чтобы «trick iOS into installing»; не тратит батарею, потому что «it's only connecting to your own device. No remote servers are used»; JIT на iOS 17.4+ — через SS 0.6.2 или StikDebug; автоматического включения JIT нет, «and if we did you would need LocalDevVPN on» — [SideStore FAQ](https://docs.sidestore.io/docs/faq)
- minimuxer — lockdown-мультиплексор SS: установка, монтирование DDI, AFC, сопряжение «over local loopback VPN»; в составе `HeartbeatService` (keep-alive), `NetworkObserverService` (NWPathMonitor), `UsbmuxdProxyServer`; EMProxy — «WireGuard loopback server» — [minimuxer README](https://github.com/SideStore/minimuxer)
- LocalDevVPN: локальный туннель, «all traffic stays on-device», без внешних соединений — [LocalDevVPN GitHub](https://github.com/seomin0610/LocalDevVPN), [App Store](https://apps.apple.com/vn/app/localdevvpn/id6755608044)
- StosVPN (команда SS) не упирается в ограничение WireGuard на сотовой сети, но часто отключается в фоне и, как любой VPN iOS, не даёт работать другим VPN; туннель — TUN `sidestore`, адрес 10.7.0.1 — [sspai](https://sspai.com/post/103368), [StosVPN GitHub](https://github.com/Alz97/StosVPN)
- LC: одно приложение и один App ID на любое число гостей («3 app/10 app id free developer account limit does not apply here»); ниже iOS 26 при JIT подпись обходится, иначе гости подписываются сертификатом LC — [LC README](https://github.com/LiveContainer/LiveContainer/blob/main/README.md)
- JIT в LC: на iOS 26+ работает только StikDebug (или StikDebug в другом LC); на A15+/M2+ с iOS 26+ нужен ещё JIT-скрипт для приложения; для многозадачного режима нужен JIT-инструмент с подключением по PID — [LC docs: JIT](https://livecontainer.github.io/docs/guides/jit-support), [LC README](https://github.com/LiveContainer/LiveContainer/blob/main/README.md)
- JIT-less: «In JIT-less mode, all executables are signed» — исполняемые файлы гостя подписываются сертификатом LC, обход библиотечной проверки не нужен — [LC README](https://github.com/LiveContainer/LiveContainer/blob/main/README.md)
- LC+SS: при неверной установке фоновое обновление падает («Cannot prompt for credentials because presentingViewController is nil»), и все приложения в многозадачном режиме делят одну связку ключей — [issue #1629](https://github.com/LiveContainer/LiveContainer/issues/1629)
- LP встроенного SS: `SideStoreLiveProcessHandler` и XPC `RefreshServer` — встроенный SS может работать в процессе LiveProcess — [LiveProcess/main.m](https://github.com/LiveContainer/LiveContainer/blob/main/LiveProcess/main.m)

### Inferences
- Петлевой VPN, пока он включён, держит `NEPacketTunnelProvider`-процесс и keep-alive minimuxer; заметный расход вероятен только при постоянно включённом VPN и активном трафике через туннель (iOS направляет туннель только на 10.7.0.x — split-tunnel). Цифр нет.
- Для Aerial: JIT не нужен (Swift + Go через gomobile — AOT); JIT-less работает. Истечение 7-дневной подписи LC ломает запуск всех гостей сразу; это не «выгрузка в фоне».

### Gaps
- Нет независимых измерений расхода батареи LocalDevVPN/StosVPN или фонового обновления SS.

## 6. Что сделать гостевому приложению, чтобы пережить фон в многозадачном режиме LC (конкретно для Aerial)

### Takeaway
Не держать замков на файлах вне собственного контейнера процесса в момент приостановки; ставить xattr самому (не надеяться на LC); быстро закрывать фоновые задачи; убедиться по `LiveProcess-*.ips`, какой код у выгрузки.

### Cited Findings
- Apple: отпустить замок до приостановки; в расширении — `ProcessInfo.beginActivity(options:reason:)` на время работы с файлом — [Apple: SIGKILL](https://developer.apple.com/documentation/xcode/sigkill)
- Quinn: «If you must use a file lock, make sure to release it before you become eligible for suspension»; советует журналировать открытые файлы в момент, когда процесс может быть приостановлен — [Apple Forums 655225](https://developer.apple.com/forums/thread/655225)
- RB не трогает файлы с xattr `com.apple.runningboard.can-suspend-locked` ≠ 0, файлы SQLite `-wal/-shm/-journal` и незаблокированные SQLite-базы — [Dead10ccFix.m](https://github.com/LiveContainer/LiveContainer/blob/main/LiveContainer/Tweaks/Dead10ccFix.m)
- Совет сообщества: не держать SQLite в общем контейнере группы — [Michael Tsai, 15.05.2025](https://mjtsai.com/blog/2025/05/15/sqlite-databases-in-app-group-containers-dont/)

### Inferences (рекомендации)
1. Сначала выяснить код: `LiveProcess-*.ips` из «Данных аналитики». 0xdead10cc → замки; 0x2182bad2 → незакрытая фоновая задача; `JetsamEvent` → память; нет отчёта → проверить журнал на «Too many open files».
2. База bbolt TorrServer — только в `confstr(_CS_DARWIN_USER_TEMP_DIR)` (tmp расширения) — уже сделано. Проверить, что **все** прочие файлы с замками (кэш TorrServer на диске, `.lock`-файлы, SQLite `URLCache` в `Library/Caches` под HOME гостя) тоже вне контейнера LC/App Group или под xattr.
3. Ставить xattr **на каждом** `UIApplicationDidEnterBackgroundNotification` и `NSExtensionHostDidEnterBackgroundNotification` (оба — как в `e98699a`), а также на каждый новый файл с замком сразу при открытии. Xattr лежит на файле и переживает перезапуск; новый файл bbolt — нет.
4. Надёжнее всего — при уходе в фон, если не идёт загрузка/воспроизведение, **останавливать** bbolt (закрывать базу = снимать `flock`), открывать заново при возврате. Если движок Go нельзя останавливать, хотя бы закрывать базу через API TorrServer.
5. Закрывать `beginBackgroundTask` как можно раньше (пульс 20 с — ок), чтобы не было 0x2182bad2; в процессе LP не опираться на `backgroundTimeRemaining`.
6. Следить за числом открытых FD в `perf.log` в фоне — на версиях LC до `bdc07ed` (17.10.2026), включая 3.8.0, `Dead10ccFix` теряет FD каждые 2 с на каждый открытый обычный файл без xattr. Меньше постоянно открытых файлов (журналы — открывать на запись и закрывать) = меньше утечка.
7. В фоне снижать память (кэш картинок, кэш TorrServer), чтобы не попасть под jetsam в суммарной памяти LC + LP.
8. Пользователю: для фонового просмотра в многозадачном режиме — PiP окна LC (держит гостя на переднем плане, но тратит заряд), или запускать Aerial в обычном режиме LC (там Dead10ccFix для приватного приложения не нужен — данные в контейнере самого процесса).

### Gaps
- Не проверено на устройстве, что xattr, поставленный самим гостем на файл в контейнере LC, снимает 0xdead10cc в процессе LP (логика RB это подразумевает, но первоисточника нет).
