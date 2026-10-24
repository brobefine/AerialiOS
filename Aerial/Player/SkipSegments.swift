import Foundation

/// Отрезок серии, который можно пропустить: заставка, «ранее в сериале», титры. Время — секунды от начала серии.
struct SkipSegment: Hashable, Sendable {
    enum Kind: Sendable { case intro, recap, outro }

    var start: Double
    var end: Double
    var kind: Kind
}

/// Где в серии заставка и титры — перенос `SkipSegments` ТВ: IntroDB — общая база отметок зрителей по IMDb-номеру
/// сериала, сезону и серии; нет там заставки — AniSkip (аниме, номер MyAnimeList через ARM). Ключи не нужны.
/// Ответы держатся в памяти до конца запуска.
actor SkipSegments {
    static let shared = SkipSegments()

    private static let introDB = "https://api.introdb.app"
    private static let arm = "https://arm.haglund.dev/api/v2/themoviedb"
    private static let aniSkip = "https://api.aniskip.com/v2/skip-times"

    private var cache: [String: [SkipSegment]] = [:]

    /// [tmdbId] — номер сериала в TMDb, [imdbId] — его номер IMDb (tt…), если известен.
    func load(tmdbId: Int, imdbId: String?, season: Int, episode: Int) async -> [SkipSegment] {
        guard season >= 0, episode > 0 else { return [] }
        let key = "\(tmdbId):\(season):\(episode)"
        if let cached = cache[key] { return cached }
        var found: [SkipSegment] = []
        if let imdbId, imdbId.hasPrefix("tt") { found = await Self.introDB(imdbId, season, episode) }
        if !found.contains(where: { $0.kind == .intro }) {
            let anime = await Self.aniSkip(tmdbId, season, episode)
            found += anime.filter { segment in !found.contains { $0.kind == segment.kind } }
        }
        cache[key] = found
        return found
    }

    private static func introDB(_ imdbId: String, _ season: Int, _ episode: Int) async -> [SkipSegment] {
        guard let json = await object("\(introDB)/segments?imdb_id=\(imdbId)&season=\(season)&episode=\(episode)") as? [String: Any] else {
            return []
        }
        func part(_ name: String, _ kind: SkipSegment.Kind) -> SkipSegment? {
            guard let value = json[name] as? [String: Any] else { return nil }
            func seconds(_ ms: String, _ sec: String) -> Double {
                if let number = value[ms] as? NSNumber { return number.doubleValue / 1000 }
                return (value[sec] as? NSNumber)?.doubleValue ?? -1
            }
            let start = seconds("start_ms", "start_sec")
            let end = seconds("end_ms", "end_sec")
            return start >= 0 && end > start ? SkipSegment(start: start, end: end, kind: kind) : nil
        }
        return [part("recap", .recap), part("intro", .intro), part("outro", .outro)].compactMap { $0 }
    }

    /// Аниме: ARM сопоставляет сериал TMDb с записями MyAnimeList по сезонам. Если сезон в MAL разбит на части, серия
    /// ищется в первой части (дальше счёт свой, его не угадать).
    private static func aniSkip(_ tmdbId: Int, _ season: Int, _ episode: Int) async -> [SkipSegment] {
        guard let map = await object("\(arm)?id=\(tmdbId)") as? [[String: Any]] else { return [] }
        let entry = map.first { row in
            row["media"] as? String == "TV" && (row["themoviedb-season"] as? NSNumber)?.intValue == season
                && (row["myanimelist"] as? NSNumber) != nil
        }
        guard let mal = (entry?["myanimelist"] as? NSNumber)?.intValue, mal > 0,
              let json = await object("\(aniSkip)/\(mal)/\(episode)?types=op&types=ed&types=recap&episodeLength=0") as? [String: Any],
              json["found"] as? Bool == true, let results = json["results"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        return results.compactMap { row -> SkipSegment? in
            guard let interval = row["interval"] as? [String: Any], let type = row["skipType"] as? String else { return nil }
            let kind: SkipSegment.Kind
            switch type {
            case "op": kind = .intro
            case "ed": kind = .outro
            case "recap": kind = .recap
            default: return nil
            }
            let start = (interval["startTime"] as? NSNumber)?.doubleValue ?? -1
            let end = (interval["endTime"] as? NSNumber)?.doubleValue ?? -1
            guard start >= 0, end > start, seen.insert(type).inserted else { return nil }
            return SkipSegment(start: start, end: end, kind: kind)
        }
    }

    private static func object(_ address: String) async -> Any? {
        guard let url = URL(string: address), let data = try? await HTTP.get(url, timeout: 12) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
