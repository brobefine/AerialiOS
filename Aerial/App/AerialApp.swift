import Darwin
import SwiftUI
import UIKit

@main
struct AerialApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var settings = AppSettings()
    @State private var library = Library()
    @State private var taste = Taste()
    @State private var feeds = Feeds()
    @State private var playback = Playback()

    init() {
        // Пока приложение спит, iOS закрывает его сокеты (TorrServer, mpv); запись в закрытый сокет шлёт SIGPIPE,
        // а он по умолчанию завершает процесс — так выглядел вылет после возврата в приложение. Ошибка записи
        // и так приходит коду как EPIPE.
        signal(SIGPIPE, SIG_IGN)
        Log.startSession()
        AerialFont.applyToNavigationBars()
        CrashGuard.start()
        Storage.logPlacement()
        // UI-тесты ждут конца каждой анимации — без них прогон на CI заметно короче.
        if UITestHooks.active { UIView.setAnimationsEnabled(false) }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(library)
                .environment(taste)
                .environment(feeds)
                .environment(playback)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                // Commissioner, как на ТВ, — для всего, где шрифт не задан явно (списки, формы, подписи).
                .font(.aerial(.body))
                .task { await Torrents.warmUp(settings) }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                CrashGuard.mark("background")
                PerfMonitor.shared.pause()
                // Без фильма и загрузки раздачи закрываются; фоновое время — только на это.
                let release = !Downloads.shared.busy && playback.request == nil
                ImageLoader.shared.trimMemory()
                PerfMonitor.shared.backgroundHeartbeat { if release { await Torrents.releaseForBackground() } }
                Friends.shared.setForeground(false)
                Log.note("ЖИЗНЬ", "в фоне\(playback.request == nil ? "" : ", идёт фильм")")
                // Сервер не останавливаем: повторный запуск движка Go в том же процессе обрывал приложение при
                // возврате — и открытая страница терялась. iOS сама усыпит его вместе с приложением.
                if Downloads.shared.busy { Downloads.shared.enterBackground() }
                DownloadKeepAlive.shared.enterBackground()
            case .active:
                Log.note("ЖИЗНЬ", "на экране")
                CrashGuard.mark("active")
                PerfMonitor.shared.resume()
                DownloadKeepAlive.shared.enterForeground()
                Friends.shared.setForeground(true)
                Task {
                    await Torrents.warmUp(settings)
                    Downloads.shared.resume()
                }
            default:
                break
            }
        }
    }
}

enum AppTab: Hashable {
    case home, library, settings, search
}

/// Вкладки в нижней пилюле: «Главная», «Медиатека», «Настройки» и «Поиск» (на iOS 26 — отдельной кнопкой справа);
/// плеер показывает [Playback].
struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Library.self) private var library
    @Environment(Playback.self) private var playback
    @State private var tab: AppTab = .home

    var body: some View {
        TabView(selection: $tab) {
            Tab(L("Главная"), systemImage: "play.tv", value: AppTab.home) { HomeView() }
            Tab(L("Медиатека"), systemImage: "rectangle.stack", value: AppTab.library) { LibraryView() }
            Tab(L("Настройки"), systemImage: "gearshape", value: AppTab.settings) { SettingsView() }
            Tab(L("Поиск"), systemImage: "magnifyingglass", value: AppTab.search, role: .search) { SearchView() }
        }
        .tabViewStyle(.sidebarAdaptable)
        // Вошли в комнату не из плеера (код, комната друга) — фильм комнаты открывается сам.
        .onChange(of: WatchParty.shared.media) { _, media in
            guard let media, playback.request == nil else { return }
            playback.play(.party(media, at: WatchParty.shared.room?.target() ?? 0))
        }
        .transaction { if UITestHooks.active { $0.disablesAnimations = true } }
        .onAppear {
            playback.attach(settings: settings, library: library)
            Downloads.shared.attach(settings)
            Friends.shared.setForeground(true)
            UITestHooks.start(playback)
            PerfMonitor.shared.start()
        }
    }
}

/// Пуски из UI-тестов: `-uiTest` — без анимаций и без автоскрытия панели плеера; `-smokeLink <ссылка>` — сразу плеер
/// с этой раздачей (проверка встроенного TorrServer и mpv на CI).
@MainActor
enum UITestHooks {
    static var active: Bool { ProcessInfo.processInfo.arguments.contains("-uiTest") }

    static func start(_ playback: Playback) {
        guard active, let link = UserDefaults.standard.string(forKey: "smokeLink"), !link.isEmpty else { return }
        let item = VodItem(id: "smoke", remoteId: 0, kind: .movie, title: L("Проверка воспроизведения"))
        // Плеер показывается поверх корневого контроллера — ждём, пока окно соберётся.
        Task {
            try? await Task.sleep(for: .seconds(1))
            playback.play(PlaybackRequest(item: item, link: link, releaseTitle: "smoke", record: false))
        }
    }
}
