import Foundation
import Observation

/// Настройки приложения поверх UserDefaults: меняются из экрана настроек, сохраняются сразу.
@MainActor @Observable
final class AppSettings {
    enum ServerMode: String, CaseIterable, Identifiable {
        case embedded, external
        var id: String { rawValue }
        var title: String { self == .embedded ? L("Встроенный") : L("Внешний") }
    }

    struct ParserServer: Identifiable, Sendable {
        var name: String
        var address: String
        var key: String = ""
        var id: String { address }
    }

    /// Публичные серверы JacRed — каталог, как у ТВ (`ParserState.catalog`): имя, адрес, ключ.
    static let parserCatalog: [ParserServer] = [
        ParserServer(name: "Jac.red", address: "https://jac.red"),
        ParserServer(name: "JacRed.su", address: "https://jacred.su"),
        ParserServer(name: "jac-red.ru", address: "https://jac-red.ru"),
        ParserServer(name: "Lampa.app", address: "https://lampa.app"),
        ParserServer(name: "jr.maxvol.pro", address: "https://jr.maxvol.pro"),
        ParserServer(name: "Jacred.my.to", address: "https://jacred.my.to"),
        ParserServer(name: "Viewbox", address: "https://jacred.viewbox.dev", key: "viewbox"),
    ]

    private let defaults = UserDefaults.standard

    var parserAddress: String { didSet { defaults.set(parserAddress, forKey: "parser.address") } }
    var parserKey: String { didSet { defaults.set(parserKey, forKey: "parser.key") } }
    /// Torrentio — раздачи по номеру IMDb (в основном зарубежные), без ключа.
    var torrentio: Bool { didSet { defaults.set(torrentio, forKey: "parser.torrentio") } }
    /// Автовыбор раздачи, как на ТВ (27 октября): «Смотреть» сразу открывает окно фильма или серий подобранной раздачи
    /// (`AutoPick`), списка раздач нет. Выключен — сначала окно со списком раздач.
    var autoRelease: Bool { didSet { defaults.set(autoRelease, forKey: "releases.auto") } }
    /// Качество для автовыбора: `AutoPick.Quality` — "best", "1080", "light".
    var releaseQuality: String { didSet { defaults.set(releaseQuality, forKey: "releases.autoQuality") } }
    /// Звук для автовыбора: true — озвучка, false — оригинал.
    var releaseVoice: Bool { didSet { defaults.set(releaseVoice, forKey: "releases.autoVoice") } }
    var serverMode: ServerMode { didSet { defaults.set(serverMode.rawValue, forKey: "torrserver.mode") } }
    var externalAddress: String { didSet { defaults.set(externalAddress, forKey: "torrserver.address") } }
    /// Кэш встроенного TorrServer в памяти, МБ.
    var cacheMB: Int { didSet { defaults.set(cacheMB, forKey: "torrserver.cacheMB") } }
    var tmdbProxy: String { didSet { defaults.set(tmdbProxy, forKey: TMDb.proxyKey) } }
    /// Ключ MDBList: оценки IMDb, Rotten Tomatoes и Metacritic на странице фильма. Пусто — не спрашиваем.
    var mdblistKey: String { didSet { defaults.set(mdblistKey, forKey: "mdblist.key"); MdbList.unblock() } }
    /// «Учитывать историю просмотра» в подборе «Вам понравится?».
    var tasteHistory: Bool { didSet { defaults.set(tasteHistory, forKey: "taste.history") } }
    /// Следующая серия — сама через 10 с после конца серии.
    var autoplayNext: Bool { didSet { defaults.set(autoplayNext, forKey: "player.autoplayNext") } }
    /// Системный плеер (AVPlayer, MKV — перепаковкой в HLS) вместо mpv: экономнее, настоящий HDR и Dolby Vision.
    var nativePlayer: Bool { didSet { defaults.set(nativePlayer, forKey: "player.native") } }
    /// Оценки MDBList на странице фильма (как «Показывать оценки MDBList» ТВ) и какие источники показывать.
    var mdblistShown: Bool { didSet { defaults.set(mdblistShown, forKey: "mdblist.shown") } }
    var ratingSources: Set<String> { didSet { defaults.set(ratingSources.sorted(), forKey: "mdblist.sources") } }
    /// Описания серий под названием в карточках серий.
    var episodeOverviews: Bool { didSet { defaults.set(episodeOverviews, forKey: "episodes.overviews") } }

    /// Источники MDBList: ключ настройки, название, пояснение — как на ТВ.
    struct RatingSource: Sendable {
        var key: String
        var title: String
        var about: String
    }

    static let ratingCatalog: [RatingSource] = [
        RatingSource(key: "imdb", title: "IMDb", about: L("Народный выбор. Взвешенная оценка зрителей со всего мира по 10-балльной шкале.")),
        RatingSource(key: "tomatoes", title: "Rotten Tomatoes", about: L("Процент положительных оценок: 🍅 — кинокритики, 🍿 — обычные зрители.")),
        RatingSource(key: "metacritic", title: "Metacritic", about: L("Оценка критиков: средневзвешенное рецензий ведущих изданий из 100.")),
        RatingSource(key: "letterboxd", title: "Letterboxd", about: L("Выбор синефилов. Оценка сообщества любителей кино по 5-балльной шкале.")),
    ]

    // MARK: ИИ и сервисы

    /// ИИ включён; ключи хранятся и при выключенном. Читает их [AI] прямо из UserDefaults.
    var aiOn: Bool { didSet { defaults.set(aiOn, forKey: "ai.on") } }
    var geminiKey: String { didSet { defaults.set(geminiKey.trimmingCharacters(in: .whitespaces), forKey: "ai.gemini") } }
    var groqKey: String { didSet { defaults.set(groqKey.trimmingCharacters(in: .whitespaces), forKey: "ai.groq") } }
    /// Подборки ИИ по настроению — ряды под «Вам понравится?».
    var aiMoodShelves: Bool { didSet { defaults.set(aiMoodShelves, forKey: "ai.moodShelves") } }
    /// Над отзывами — коротко, что думают зрители (от трёх отзывов).
    var summarizeReviews: Bool { didSet { defaults.set(summarizeReviews, forKey: "ai.summarizeReviews") } }
    /// Открытый отзыв сразу переводится на русский.
    var translateReviews: Bool { didSet { defaults.set(translateReviews, forKey: "ai.translateReviews") } }
    /// Ключ OpenSubtitles: поиск субтитров прямо в плеере.
    var openSubsKey: String { didSet { defaults.set(openSubsKey.trimmingCharacters(in: .whitespaces), forKey: "opensubs.key") } }
    /// Языки субтитров для поиска, через запятую (коды ISO 639-1).
    var subsLanguages: String { didSet { defaults.set(subsLanguages, forKey: "opensubs.languages") } }
    var aiEnabled: Bool { aiOn && (!geminiKey.trimmingCharacters(in: .whitespaces).isEmpty || !groqKey.trimmingCharacters(in: .whitespaces).isEmpty) }

    init() {
        aiOn = defaults.object(forKey: "ai.on") as? Bool ?? true
        geminiKey = defaults.string(forKey: "ai.gemini") ?? ""
        groqKey = defaults.string(forKey: "ai.groq") ?? ""
        aiMoodShelves = defaults.object(forKey: "ai.moodShelves") as? Bool ?? true
        summarizeReviews = defaults.object(forKey: "ai.summarizeReviews") as? Bool ?? true
        translateReviews = defaults.object(forKey: "ai.translateReviews") as? Bool ?? true
        openSubsKey = defaults.string(forKey: "opensubs.key") ?? ""
        subsLanguages = defaults.string(forKey: "opensubs.languages") ?? "ru,en"
        parserAddress = defaults.string(forKey: "parser.address") ?? Self.parserCatalog[0].address
        parserKey = defaults.string(forKey: "parser.key") ?? ""
        torrentio = defaults.object(forKey: "parser.torrentio") as? Bool ?? true
        // В UI-тестах — список раздач: сеть раздач на CI непредсказуема, снимки нужны одинаковые.
        autoRelease = defaults.object(forKey: "releases.auto") as? Bool ?? !UITestHooks.active
        releaseQuality = defaults.string(forKey: "releases.autoQuality") ?? "1080"
        releaseVoice = defaults.object(forKey: "releases.autoVoice") as? Bool ?? true
        serverMode = ServerMode(rawValue: defaults.string(forKey: "torrserver.mode") ?? "") ?? .embedded
        externalAddress = defaults.string(forKey: "torrserver.address") ?? ""
        cacheMB = defaults.object(forKey: "torrserver.cacheMB") as? Int ?? 256
        tmdbProxy = defaults.string(forKey: TMDb.proxyKey) ?? TMDb.defaultProxy
        mdblistKey = defaults.string(forKey: "mdblist.key") ?? ""
        tasteHistory = defaults.object(forKey: "taste.history") as? Bool ?? true
        autoplayNext = defaults.object(forKey: "player.autoplayNext") as? Bool ?? true
        nativePlayer = defaults.object(forKey: "player.native") as? Bool ?? true
        mdblistShown = defaults.object(forKey: "mdblist.shown") as? Bool ?? true
        ratingSources = Set(defaults.stringArray(forKey: "mdblist.sources") ?? ["imdb", "tomatoes", "metacritic", "letterboxd"])
        episodeOverviews = defaults.object(forKey: "episodes.overviews") as? Bool ?? true
    }
}
