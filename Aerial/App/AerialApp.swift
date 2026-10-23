import SwiftUI

@main
struct AerialApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings = AppSettings()
    @State private var library = Library()
    @State private var playback = Playback()

    init() {
        Log.startSession()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(library)
                .environment(playback)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task { await Torrents.warmUp(settings) }
        }
    }
}

enum AppTab: Hashable {
    case home, library, search
}

/// Вкладки: «Главная», «Медиатека», «Поиск» (на iOS 26 — отдельной кнопкой справа); плеер — поверх всего.
struct RootView: View {
    @Environment(Playback.self) private var playback
    @State private var tab: AppTab = .home

    var body: some View {
        @Bindable var playback = playback
        TabView(selection: $tab) {
            Tab("Главная", systemImage: "play.tv", value: AppTab.home) { HomeView() }
            Tab("Медиатека", systemImage: "rectangle.stack", value: AppTab.library) { LibraryView() }
            Tab("Поиск", systemImage: "magnifyingglass", value: AppTab.search, role: .search) { SearchView() }
        }
        .tabViewStyle(.sidebarAdaptable)
        .fullScreenCover(item: $playback.request) { request in
            PlayerView(request: request)
        }
        .onAppear { UITestHooks.start(playback) }
    }
}

/// Пуски из UI-тестов: `-uiTest` — без автолистания карусели; `-smokeLink <ссылка>` — сразу плеер с этой раздачей
/// (проверка встроенного TorrServer и mpv на CI).
@MainActor
enum UITestHooks {
    static var active: Bool { ProcessInfo.processInfo.arguments.contains("-uiTest") }

    static func start(_ playback: Playback) {
        guard active, let link = UserDefaults.standard.string(forKey: "smokeLink"), !link.isEmpty else { return }
        let item = VodItem(id: "smoke", remoteId: 0, kind: .movie, title: "Проверка воспроизведения")
        playback.play(PlaybackRequest(item: item, link: link, releaseTitle: "smoke", record: false))
    }
}
