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
    @State private var playback = Playback()

    init() {
        // Пока приложение спит, iOS закрывает его сокеты (TorrServer, mpv); запись в закрытый сокет шлёт SIGPIPE,
        // а он по умолчанию завершает процесс — так выглядел вылет после возврата в приложение. Ошибка записи
        // и так приходит коду как EPIPE.
        signal(SIGPIPE, SIG_IGN)
        Log.startSession()
        // UI-тесты ждут конца каждой анимации — без них прогон на CI заметно короче.
        if UITestHooks.active { UIView.setAnimationsEnabled(false) }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(library)
                .environment(taste)
                .environment(playback)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task { await Torrents.warmUp(settings) }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                Log.note("ЖИЗНЬ", "в фоне\(playback.request == nil ? "" : ", идёт фильм")")
                // Без фильма сервер в фоне не нужен: iOS всё равно усыпит его, а сокеты после сна мёртвые.
                if playback.request == nil { EmbeddedTorrServer.shared.suspend() }
            case .active:
                Log.note("ЖИЗНЬ", "на экране")
                Task { await Torrents.warmUp(settings) }
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
            Tab("Главная", systemImage: "play.tv", value: AppTab.home) { HomeView() }
            Tab("Медиатека", systemImage: "rectangle.stack", value: AppTab.library) { LibraryView() }
            Tab("Настройки", systemImage: "gearshape", value: AppTab.settings) { SettingsView() }
            Tab("Поиск", systemImage: "magnifyingglass", value: AppTab.search, role: .search) { SearchView() }
        }
        .tabViewStyle(.sidebarAdaptable)
        .transaction { if UITestHooks.active { $0.disablesAnimations = true } }
        .onAppear {
            playback.attach(settings: settings, library: library)
            UITestHooks.start(playback)
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
        let item = VodItem(id: "smoke", remoteId: 0, kind: .movie, title: "Проверка воспроизведения")
        // Плеер показывается поверх корневого контроллера — ждём, пока окно соберётся.
        Task {
            try? await Task.sleep(for: .seconds(1))
            playback.play(PlaybackRequest(item: item, link: link, releaseTitle: "smoke", record: false))
        }
    }
}
