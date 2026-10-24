import Foundation

enum VodKind: String, Codable, Hashable, Sendable {
    case movie, series
}

/// Разделы кинотеки. Правило принадлежности — как `VodShelf.accepts` ТВ: «Фильмы» без мультфильмов,
/// «Сериалы» без мультсериалов, «Мультфильмы» — только фильмы, «Мультсериалы» — только сериалы.
enum VodShelf: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all, movies, series, cartoons, cartoonSeries

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "Всё"
        case .movies: "Фильмы"
        case .series: "Сериалы"
        case .cartoons: "Мультфильмы"
        case .cartoonSeries: "Мультсериалы"
        }
    }

    func accepts(_ item: VodItem) -> Bool {
        switch self {
        case .all: true
        case .movies: item.kind == .movie && !item.isCartoon
        case .series: item.kind == .series && !item.isCartoon
        case .cartoons: item.kind == .movie && item.isCartoon
        case .cartoonSeries: item.kind == .series && item.isCartoon
        }
    }
}

/// Фильм или сериал TMDb. Картинки — пути TMDb (`/abc.jpg`): размер выбирает место показа ([TMDbImage]).
struct VodItem: Codable, Hashable, Identifiable, Sendable {
    /// `tmdb:movie:603`, `tmdb:series:1399` — как у ТВ.
    var id: String
    var remoteId: Int
    var kind: VodKind
    var title: String
    var originalTitle: String = ""
    var overview: String = ""
    var poster: String = ""
    var backdrop: String = ""
    /// Дата выхода «ГГГГ-ММ-ДД», пусто — неизвестна.
    var releaseDate: String = ""
    var genres: [String] = []
    var genreIds: [Int] = []
    var rating: Double = 0
    var votes: Int = 0

    var year: String { String(releaseDate.prefix(4)) }
    var tmdbType: String { kind == .movie ? "movie" : "tv" }
    /// Мультфильм — жанр «Анимация» TMDb (16).
    var isCartoon: Bool { genreIds.contains(16) || genres.contains { $0.localizedCaseInsensitiveContains("мульт") || $0.localizedCaseInsensitiveContains("анимац") } }
    var isUpcoming: Bool {
        guard releaseDate.count >= 10 else { return false }
        return releaseDate > ISO8601DateFormatter.day.string(from: .now)
    }
    var kindLabel: String {
        switch (kind, isCartoon) {
        case (.movie, false): "Фильм"
        case (.movie, true): "Мультфильм"
        case (.series, false): "Сериал"
        case (.series, true): "Мультсериал"
        }
    }
}

struct VodEpisode: Codable, Hashable, Identifiable, Sendable {
    var season: Int
    var number: Int
    var title: String
    var overview: String = ""
    var still: String = ""
    var airDate: String = ""
    var runtimeMinutes: Int = 0

    var id: String { "\(season):\(number)" }
    var code: String { "\(season)x\(number)" }
}

struct VodPerson: Codable, Hashable, Identifiable, Sendable {
    var id: Int
    var name: String
    var role: String
    var photo: String = ""
}

struct VodFact: Hashable, Sendable {
    var label: String
    var value: String
}

struct VodDetails: Sendable {
    var item: VodItem
    var tagline: String = ""
    var runtimeMinutes: Int = 0
    var certification: String = ""
    var countries: [String] = []
    /// Статус сериала: «Продолжается», «Завершён»…; у фильма пусто.
    var status: String = ""
    var endYear: String = ""
    var seasons: [Int] = []
    var logo: String = ""
    var trailerKey: String = ""
    var imdbId: String = ""
    var cast: [VodPerson] = []
    var directors: [VodPerson] = []
    var related: [VodItem] = []
    var collectionTitle: String = ""
    var collection: [VodItem] = []
    var facts: [VodFact] = []
    /// Студии TMDb (до четырёх) — капсулами рядом с жанрами; работы первой — ряд «Ещё от студии».
    var studios: [VodStudio] = []
    var studioFilms: [VodItem] = []
}

/// Студия TMDb: капсула открывает её работы того же вида.
struct VodStudio: Hashable, Sendable {
    var id: Int
    var name: String

    func section(_ kind: VodKind) -> CinemaSection {
        CinemaSection(id: "studio-\(id)-\(kind)", title: name, path: kind == .series ? "discover/tv" : "discover/movie", kind: kind,
                      params: ["with_companies": String(id), "sort_by": "popularity.desc", "vote_count.gte": "20"])
    }
}

/// Отзыв зрителя TMDb.
struct VodReview: Hashable, Identifiable, Sendable {
    var author: String
    var rating: Double
    var text: String
    var date: String

    var id: String { "\(author)|\(date)" }
}

struct VodPersonInfo: Sendable {
    var id: Int
    var name: String
    var photo: String
    var department: String
    var birthday: String
    var place: String
    var biography: String
    var works: [VodItem]
}

/// Ряд каталога: запрос TMDb и вид работ в нём.
struct CinemaSection: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var path: String
    var kind: VodKind
    var params: [String: String] = [:]
    /// «Топ-10 сегодня»: у первых десяти — номера, как в ряду «В тренде сегодня» ТВ.
    var ranked = false
}

extension ISO8601DateFormatter {
    static let day: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        f.timeZone = .current
        return f
    }()
}
