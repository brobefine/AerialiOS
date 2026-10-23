import Foundation

/// Поиск раздач — перенос `ParserState`/`Torrentio` ТВ. Сначала точный поиск JacRed (по русскому и оригинальному
/// названию, год ±1 — как у Lampa), не нашёл или сервер не JacRed — обычный поиск Jackett по строке; плюс Torrentio
/// по номеру IMDb. Повторы одной раздачи из разных источников склеиваются по хэшу.
enum ReleaseSearch {
    struct Parser: Sendable {
        var address: String
        var key: String
        var torrentio: Bool
    }

    static func search(item: VodItem, episode: VodEpisode?, imdbId: String?, parser: Parser) async -> [Release] {
        let year = item.kind == .movie ? Int(item.year) ?? 0 : 0
        async let exact = self.exact(parser, title: item.title, original: item.originalTitle, year: year)
        // Без номера IMDb или с выключенным Torrentio запрос сразу вернёт пусто.
        async let torrentio = Torrentio.streams(parser.torrentio ? imdbId ?? "" : "",
                                                season: episode?.season ?? 0, episode: episode?.number ?? 0)
        var found = await exact ?? []
        if found.isEmpty {
            let query = [item.title, item.kind == .movie ? item.year : ""].filter { !$0.isEmpty }.joined(separator: " ")
            found = (try? await jackett(parser, query: query)) ?? []
        }
        found += await torrentio
        var seen = Set<String>()
        return found.filter { seen.insert($0.hash ?? $0.link).inserted }.sorted { $0.seeds > $1.seeds }
    }

    /// Точный поиск JacRed: `api/v1.0/torrents?search=&altname=&exact=true`. nil — сервер не JacRed или не ответил.
    static func exact(_ parser: Parser, title: String, original: String, year: Int) async -> [Release]? {
        guard let base = TorrServerClient.normalize(parser.address) else { return nil }
        var query: [(String, String?)] = [("search", title.trimmingCharacters(in: .whitespaces))]
        if !original.isEmpty, original.caseInsensitiveCompare(title) != .orderedSame {
            query.append(("altname", original.trimmingCharacters(in: .whitespaces)))
        }
        query.append(("exact", "true"))
        if !parser.key.isEmpty { query.append(("apikey", parser.key)) }
        let url = base.appending(path: "api/v1.0/torrents").with(query: query)
        guard let data = try? await HTTP.get(url, timeout: 30),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            Log.note("РАЗДАЧИ", "JacRed \(base.host ?? "?"): нет ответа")
            return nil
        }
        let releases = rows.compactMap { row -> Release? in
            let released = (row["relased"] as? NSNumber)?.intValue ?? 0
            if year > 0 && released > 0 && abs(released - year) > 1 { return nil }
            guard let link = row["magnet"] as? String, TorrServerClient.validLink(link) else { return nil }
            let voices = (row["voices"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return Release(title: row["title"] as? String ?? "", link: link, tracker: row["tracker"] as? String ?? "",
                           bytes: max(0, (row["size"] as? NSNumber)?.int64Value ?? 0),
                           seeds: max(0, (row["sid"] as? NSNumber)?.intValue ?? 0),
                           leechers: max(0, (row["pir"] as? NSNumber)?.intValue ?? 0),
                           published: row["createTime"] as? String ?? "",
                           height: max(0, (row["quality"] as? NSNumber)?.intValue ?? 0),
                           hdr: (row["videotype"] as? String)?.lowercased() == "hdr", voices: voices)
        }
        Log.note("РАЗДАЧИ", "JacRed «\(title)»: \(releases.count)")
        return Array(releases.prefix(200))
    }

    /// Общий поиск Jackett/Prowlarr: `api/v2.0/indexers/all/results?Query=`.
    static func jackett(_ parser: Parser, query: String) async throws -> [Release] {
        guard let base = TorrServerClient.normalize(parser.address) else { throw TorrServerError.invalidAddress }
        let url = base.appending(path: "api/v2.0/indexers/all/results")
            .with(query: [("apikey", parser.key), ("Query", query.trimmingCharacters(in: .whitespaces))])
        return try parseJackett(HTTP.json(await HTTP.get(url, timeout: 30)))
    }

    static func parseJackett(_ body: [String: Any]) -> [Release] {
        let rows = body["Results"] as? [[String: Any]] ?? []
        let releases = rows.compactMap { row -> Release? in
            let link = [row["MagnetUri"] as? String, row["Link"] as? String].compactMap { $0 }.first(where: TorrServerClient.validLink)
            guard let link, let title = row["Title"] as? String, !title.isEmpty else { return nil }
            let info = (row["info"] ?? row["Info"]) as? [String: Any]
            // Широкоэкранный 1920×800 — это 1080p: класс по ширине, приведённой к 16:9.
            let video = (row["ffprobe"] as? [[String: Any]])?.first { $0["codec_type"] as? String == "video" }
            let probed = video.map { max(($0["height"] as? NSNumber)?.intValue ?? 0, (($0["width"] as? NSNumber)?.intValue ?? 0) * 9 / 16) } ?? 0
            let seeders = max(0, (row["Seeders"] as? NSNumber)?.intValue ?? 0)
            let leechers = (row["Leechers"] as? NSNumber)?.intValue ?? (row["Peers"] as? NSNumber).map { max(0, $0.intValue - seeders) }
            return Release(title: title, link: link, tracker: row["Tracker"] as? String ?? "",
                           bytes: max(0, (row["Size"] as? NSNumber)?.int64Value ?? 0), seeds: seeders, leechers: leechers,
                           published: row["PublishDate"] as? String ?? "",
                           height: probed > 0 ? probed : max(0, (info?["quality"] as? NSNumber)?.intValue ?? 0),
                           hdr: (info?["videotype"] as? String)?.lowercased() == "hdr",
                           voices: (info?["voices"] as? [String] ?? []).filter { !$0.isEmpty })
        }
        var seen = Set<String>()
        return Array(releases.filter { seen.insert($0.link).inserted }.prefix(200))
    }

    /// Доступен ли сервер JacRed: отвечает ли `api/v1.0/conf` за 8 с.
    static func probe(_ address: String) async -> Bool {
        guard let base = TorrServerClient.normalize(address),
              let data = try? await HTTP.get(base.appending(path: "api/v1.0/conf"), timeout: 8) else { return false }
        return data.first == UInt8(ascii: "{")
    }
}

/// Torrentio (Stremio): раздачи по номеру IMDb, а не по названию — путаницы с названиями нет. В основном зарубежные
/// релизы, русских озвучек мало. Фильм — `movie/tt…`, серия — `series/tt…:сезон:серия`.
enum Torrentio {
    private static let base = "https://torrentio.strem.fun"
    private static let seeds = Rx("👤\\s*(\\d+)")
    private static let size = Rx("(?i)💾\\s*([\\d.]+)\\s*(GB|MB|TB)")
    private static let source = Rx("⚙️\\s*(.+)")

    static func streams(_ imdbId: String, season: Int = 0, episode: Int = 0) async -> [Release] {
        guard imdbId.hasPrefix("tt") else { return [] }
        let path = season > 0 && episode > 0 ? "series/\(imdbId):\(season):\(episode)" : "movie/\(imdbId)"
        guard let url = URL(string: "\(base)/stream/\(path).json"),
              let body = try? HTTP.json(await HTTP.get(url, timeout: 20)),
              let streams = body["streams"] as? [[String: Any]] else { return [] }
        let releases = streams.compactMap { stream -> Release? in
            guard let hash = stream["infoHash"] as? String, hash.count == 40 else { return nil }
            let text = stream["title"] as? String ?? ""
            let name = text.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard !name.isEmpty else { return nil }
            var bytes: Int64 = 0
            if let match = size.groups(text), let value = Double(match[1]) {
                let unit: Double
                switch match[2].uppercased() {
                case "TB": unit = 1e12
                case "GB": unit = 1e9
                default: unit = 1e6
                }
                bytes = Int64(value * unit)
            }
            let trackers = (stream["sources"] as? [String] ?? []).filter { $0.hasPrefix("tracker:") }.map { String($0.dropFirst(8)) }
            let encode = { (value: String) in value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value }
            let magnet = "magnet:?xt=urn:btih:\(hash.lowercased())&dn=\(encode(name))" + trackers.prefix(8).map { "&tr=\(encode($0))" }.joined()
            let tag = stream["name"] as? String ?? ""
            let height = tag.localizedCaseInsensitiveContains("4k") || tag.contains("2160") ? 2160 : tag.contains("1080") ? 1080
                : tag.contains("720") ? 720 : tag.contains("480") ? 480 : 0
            let origin = source.groups(text)?[1].trimmingCharacters(in: .whitespaces) ?? "?"
            return Release(title: name, link: magnet, tracker: "Torrentio · \(origin)", bytes: bytes,
                           seeds: Int(seeds.groups(text)?[1] ?? "") ?? 0, height: height,
                           hdr: tag.localizedCaseInsensitiveContains("HDR") || tag.contains("DV"))
        }
        Log.note("РАЗДАЧИ", "Torrentio \(path): \(releases.count)")
        return releases
    }
}
