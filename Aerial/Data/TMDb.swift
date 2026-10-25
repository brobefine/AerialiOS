import Foundation

/// TMDb: прямой API, при сбое — Worker-прокси (как `TmdbClient` ТВ). Маршрут, ответивший последним, идёт первым:
/// когда прямой API заблокирован, каждый запрос иначе сначала ждал бы свой срок и лишь потом шёл через Worker.
final class TMDb: @unchecked Sendable {
    static let shared = TMDb()
    static let defaultProxy = "tmdb.newtony2003.workers.dev"
    static let proxyKey = "tmdbProxy"

    private let official = "api.themoviedb.org"
    private let apiKey: String
    private let readToken: String
    private let lock = NSLock()
    private var viaWorker = false

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        apiKey = (info["TMDBApiKey"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        readToken = (info["TMDBReadToken"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if apiKey.isEmpty && readToken.isEmpty { Log.note("TMDB", "ключей нет — каталог пуст (Secrets.xcconfig)") }
    }

    var configured: Bool { !apiKey.isEmpty || !readToken.isEmpty }

    static var proxyHost: String {
        let value = UserDefaults.standard.string(forKey: proxyKey) ?? defaultProxy
        return value.replacingOccurrences(of: "https://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// Ответ `path` с параметрами; повтор — из [DiskCache] в пределах `ttl`, сеть упала — прежний ответ.
    func request(_ path: String, _ params: [String: String] = [:], localize: Bool = true, ttl: TimeInterval) async throws -> Data {
        var all = ["include_adult": "false"]
        if localize { all["language"] = AppLanguage.tmdb }
        all.merge(params) { $1 }
        let key = "tmdb:\(path)?" + all.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        if let cached = DiskCache.api.get(key, ttl: ttl) { return cached }
        do {
            let data = try await fetch(path, all)
            DiskCache.api.put(key, data)
            return data
        } catch {
            if !HTTP.isCancellation(error), let stale = DiskCache.api.stale(key) { return stale }
            throw error
        }
    }

    func decode<T: Decodable>(_ type: T.Type, _ path: String, _ params: [String: String] = [:],
                              localize: Bool = true, ttl: TimeInterval) async throws -> T {
        let data = try await request(path, params, localize: localize, ttl: ttl)
        return try Self.decoder.decode(T.self, from: data)
    }

    private func fetch(_ path: String, _ params: [String: String]) async throws -> Data {
        guard configured else { throw HTTPError.status(401) }
        var components = URLComponents()
        components.scheme = "https"
        components.host = official
        components.path = "/3/\(path)"
        var query = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        if !apiKey.isEmpty { query.append(URLQueryItem(name: "api_key", value: apiKey)) }
        components.queryItems = query
        guard let direct = components.url else { throw HTTPError.invalidResponse }
        components.host = Self.proxyHost
        let worker = components.url ?? direct

        let preferWorker = lock.withLock { viaWorker }
        let order = worker == direct ? [direct] : (preferWorker ? [worker, direct] : [direct, worker])
        var last: Error = HTTPError.invalidResponse
        for url in order {
            var request = URLRequest(url: url, timeoutInterval: url == direct ? 6 : 12)
            if apiKey.isEmpty { request.setValue("Bearer \(readToken)", forHTTPHeaderField: "Authorization") }
            let started = Date()
            do {
                let data = try await HTTP.data(request)
                // Прокси может вернуть свою страницу с кодом 200 — ответ API всегда объект JSON.
                guard data.first == UInt8(ascii: "{") else { throw HTTPError.invalidResponse }
                lock.withLock { viaWorker = url != direct }
                return data
            } catch {
                if HTTP.isCancellation(error) { throw error }
                last = error
                Log.note("TMDB", "\(url.host ?? "?")/\(path): \(type(of: error)) \(error.localizedDescription), \(Int(Date().timeIntervalSince(started) * 1000)) мс")
            }
        }
        throw last
    }
}

/// Адреса картинок TMDb: официальный CDN, запасной — тот же путь через Worker.
enum TMDbImage {
    static func urls(_ path: String, _ size: String) -> [URL] {
        guard path.hasPrefix("/"), path.count > 1 else { return [] }
        return [
            URL(string: "https://image.tmdb.org/t/p/\(size)\(path)"),
            URL(string: "https://\(TMDb.proxyHost)/t/p/\(size)\(path)"),
        ].compactMap { $0 }
    }
}

// MARK: - Ответы TMDb

struct TMDbPage: Decodable, Sendable {
    var page: Int?
    var totalPages: Int?
    var results: [TMDbTitle]
}

struct TMDbTitle: Decodable, Sendable {
    var id: Int
    var mediaType: String?
    var title: String?
    var name: String?
    var originalTitle: String?
    var originalName: String?
    var overview: String?
    var posterPath: String?
    var backdropPath: String?
    var releaseDate: String?
    var firstAirDate: String?
    var voteAverage: Double?
    var voteCount: Int?
    var popularity: Double?
    var genreIds: [Int]?
    var adult: Bool?
    var job: String?

    func item(kind forced: VodKind?, genres: [Int: String]) -> VodItem? {
        if adult == true { return nil }
        let kind: VodKind
        if let forced {
            kind = forced
        } else {
            switch mediaType {
            case "movie": kind = .movie
            case "tv": kind = .series
            default: return nil
            }
        }
        let title = (kind == .movie ? title : name) ?? ""
        guard id > 0, !title.isEmpty else { return nil }
        let ids = genreIds ?? []
        return VodItem(
            id: "tmdb:\(kind == .movie ? "movie" : "series"):\(id)", remoteId: id, kind: kind, title: title,
            originalTitle: (kind == .movie ? originalTitle : originalName) ?? "",
            overview: overview ?? "", poster: posterPath ?? "", backdrop: backdropPath ?? "",
            releaseDate: (kind == .movie ? releaseDate : firstAirDate) ?? "",
            genres: ids.compactMap { genres[$0] }, genreIds: ids,
            rating: voteAverage ?? 0, votes: max(0, voteCount ?? 0))
    }
}

struct TMDbNamed: Decodable, Sendable {
    var id: Int?
    var name: String?
}

struct TMDbDetails: Decodable, Sendable {
    struct Country: Decodable, Sendable { var iso31661: String? }
    struct Company: Decodable, Sendable { var id: Int?; var name: String?; var logoPath: String? }
    struct Season: Decodable, Sendable { var seasonNumber: Int?; var episodeCount: Int? }
    struct Person: Decodable, Sendable {
        var id: Int?
        var name: String?
        var character: String?
        var job: String?
        var profilePath: String?
    }
    struct Credits: Decodable, Sendable { var cast: [Person]?; var crew: [Person]? }
    struct Image: Decodable, Sendable {
        var filePath: String?
        var iso6391: String?
        var width: Int?
        var height: Int?
        var voteAverage: Double?
    }
    struct Images: Decodable, Sendable { var logos: [Image]?; var backdrops: [Image]? }
    struct Video: Decodable, Sendable {
        var key: String?
        var site: String?
        var type: String?
        var official: Bool?
        var iso6391: String?
    }
    struct Videos: Decodable, Sendable { var results: [Video]? }
    struct ExternalIds: Decodable, Sendable { var imdbId: String? }
    struct ReleaseDate: Decodable, Sendable { var certification: String? }
    struct CountryReleases: Decodable, Sendable { var iso31661: String?; var releaseDates: [ReleaseDate]? }
    struct ReleaseDates: Decodable, Sendable { var results: [CountryReleases]? }
    struct ContentRating: Decodable, Sendable { var iso31661: String?; var rating: String? }
    struct ContentRatings: Decodable, Sendable { var results: [ContentRating]? }

    var id: Int
    var title: String?
    var name: String?
    var originalTitle: String?
    var originalName: String?
    var overview: String?
    var tagline: String?
    var posterPath: String?
    var backdropPath: String?
    var releaseDate: String?
    var firstAirDate: String?
    var lastAirDate: String?
    var status: String?
    var voteAverage: Double?
    var voteCount: Int?
    var runtime: Int?
    var episodeRunTime: [Int]?
    var budget: Int?
    var revenue: Int?
    var numberOfSeasons: Int?
    var numberOfEpisodes: Int?
    var genres: [TMDbNamed]?
    var productionCountries: [Country]?
    var originCountry: [String]?
    var productionCompanies: [Company]?
    var seasons: [Season]?
    var createdBy: [Person]?
    var credits: Credits?
    var recommendations: TMDbPage?
    var images: Images?
    var videos: Videos?
    var externalIds: ExternalIds?
    var releaseDates: ReleaseDates?
    var contentRatings: ContentRatings?
    var belongsToCollection: TMDbNamed?
}

struct TMDbSeason: Decodable, Sendable {
    struct Episode: Decodable, Sendable {
        var episodeNumber: Int?
        var seasonNumber: Int?
        var name: String?
        var overview: String?
        var stillPath: String?
        var airDate: String?
        var runtime: Int?
    }
    var episodes: [Episode]?
}

struct TMDbCollection: Decodable, Sendable {
    var name: String?
    var parts: [TMDbTitle]?
}

struct TMDbPerson: Decodable, Sendable {
    var id: Int
    var name: String?
    var biography: String?
    var birthday: String?
    var placeOfBirth: String?
    var profilePath: String?
    var knownForDepartment: String?
}

struct TMDbCredits: Decodable, Sendable {
    var cast: [TMDbTitle]?
    var crew: [TMDbTitle]?
}

struct TMDbGenres: Decodable, Sendable {
    var genres: [TMDbNamed]
}
