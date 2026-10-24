import Foundation

struct TorrentFile: Hashable, Identifiable, Sendable {
    var index: Int
    var path: String
    var bytes: Int64

    var id: Int { index }
    var name: String { path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path }
}

struct TorrentInfo: Sendable {
    var hash: String
    var title: String
    var files: [TorrentFile]
    var peers: Int
    var speed: Int64
    var metadataReady: Bool
}

enum TorrServerError: LocalizedError {
    case invalidAddress, invalidLink, noVideo, metadataTimeout, notRunning(String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "Некорректный адрес TorrServer"
        case .invalidLink: "Некорректная ссылка на раздачу"
        case .noVideo: "В раздаче нет видеофайлов"
        case .metadataTimeout: "Раздача не ответила: нет сидов или трекеры недоступны"
        case .notRunning(let reason): "TorrServer не запущен: \(reason)"
        }
    }
}

/// HTTP-API TorrServer — перенос `TorrServerClient` ТВ. Встроенный сервер и внешний говорят одинаково.
struct TorrServerClient: Sendable {
    static let videoExtensions: Set<String> = ["mkv", "mp4", "avi", "mov", "m4v", "webm", "ts", "m2ts", "mpg", "mpeg"]

    let base: URL
    private let headers: [String: String]

    init(address: String, username: String = "", password: String = "") throws {
        guard let base = Self.normalize(address) else { throw TorrServerError.invalidAddress }
        self.base = base
        if username.isEmpty {
            headers = [:]
        } else {
            headers = ["Authorization": "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()]
        }
    }

    /// Адрес без схемы — http; путь всегда со слешем в конце; логин в адресе, запрос и якорь не допускаются.
    static func normalize(_ address: String) -> URL? {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: \.isWhitespace), !value.hasPrefix("//") else { return nil }
        guard var components = URLComponents(string: value.contains("://") ? value : "http://\(value)"),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.host?.isEmpty == false,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil
        else { return nil }
        if !components.path.hasSuffix("/") { components.path += "/" }
        return components.url
    }

    static func validLink(_ link: String) -> Bool {
        let value = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("magnet:?") {
            return Rx("(?i)[?&]xt=urn:btih:([a-f0-9]{40}|[a-z2-7]{32})(?:&|$)").matches(value)
        }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https"].contains(scheme) && url.user == nil
    }

    /// Хэш из magnet-ссылки (40 hex), чтобы склеивать одну раздачу из разных источников.
    static func infoHash(_ link: String) -> String? {
        Rx("(?i)xt=urn:btih:([a-f0-9]{40})").groups(link)?[1].lowercased()
    }

    // MARK: Запросы

    func echo() async -> String? {
        guard let data = try? await HTTP.get(base.appending(path: "echo"), timeout: 3, headers: headers) else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func add(link: String, title: String = "", poster: String = "") async throws -> TorrentInfo {
        guard Self.validLink(link) else { throw TorrServerError.invalidLink }
        let data = try await HTTP.postJSON(base.appending(path: "torrents"), body: [
            "action": "add", "link": link.trimmingCharacters(in: .whitespacesAndNewlines),
            "title": title, "poster": poster, "save_to_db": true,
        ], timeout: 65, headers: headers)
        return try Self.parse(HTTP.json(data))
    }

    /// `/stream?stat` будит раздачи, сохранённые в базе сервера; `/torrents get` вернул бы только текущее состояние.
    func get(_ hash: String, timeout: TimeInterval = 15) async throws -> TorrentInfo {
        try await Self.parse(stat(hash, timeout: timeout))
    }

    func stat(_ hash: String, timeout: TimeInterval = 4) async throws -> [String: Any] {
        let url = base.appending(path: "stream").with(query: [("link", hash), ("stat", nil)])
        return try await HTTP.json(HTTP.get(url, timeout: timeout, headers: headers))
    }

    /// Ждёт метаданные раздачи (список файлов) до 65 с, как ТВ.
    func awaitFiles(_ initial: TorrentInfo) async throws -> TorrentInfo {
        var info = initial
        let deadline = Date().addingTimeInterval(65)
        while info.files.isEmpty {
            if info.metadataReady { throw TorrServerError.noVideo }
            guard Date() < deadline else { throw TorrServerError.metadataTimeout }
            try await Task.sleep(for: .milliseconds(300))
            info = (try? await get(info.hash)) ?? info
        }
        return info
    }

    func streamURL(hash: String, file: TorrentFile) -> URL {
        base.appending(path: "stream").appending(path: file.name)
            .with(query: [("link", hash), ("index", String(file.index)), ("play", nil)])
    }

    /// Подкачка начала файла перед просмотром: `/stream?…&preload` держит соединение, пока сервер набирает буфер,
    /// а `stat` отдаёт `preloaded_bytes` из `preload_size`. На телефоне стартуем, как только набрано начало (~15 с видео,
    /// не меньше 8 МБ) — дальше докачивает mpv; через 20 с хватает и 4 МБ. Срок — 60 с, затем просто играем.
    func preload(hash: String, file: TorrentFile, duration: Double, progress: @escaping @Sendable (Double, [String: Any]?) -> Void) async {
        let bitrate = Self.estimatedBitrate(fileBytes: file.bytes, duration: duration)
        let url = base.appending(path: "stream").appending(path: file.name)
            .with(query: [("link", hash), ("index", String(file.index)), ("preload", nil)])
        let finished = Flag()
        let auth = self.headers
        let starter = Task.detached {
            var request = URLRequest(url: url, timeoutInterval: 125)
            auth.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            _ = try? await HTTP.data(request)
            finished.set()
        }
        defer { starter.cancel() }
        let started = Date()
        let deadline = started.addingTimeInterval(60)
        while Date() < deadline, !Task.isCancelled {
            let state = try? await stat(hash)
            let done = (state?["preloaded_bytes"] as? NSNumber)?.int64Value ?? 0
            let total = (state?["preload_size"] as? NSNumber)?.int64Value ?? 0
            let goal = total > 0 ? min(total, Self.earlyStartBytes(bitrate)) : Self.earlyStartBytes(bitrate)
            progress(min(1, Double(done) / Double(goal)), state)
            if done >= goal || finished.value { break }
            if Date().timeIntervalSince(started) > 20 && done >= 4 << 20 { break }
            try? await Task.sleep(for: .milliseconds(400))
        }
        progress(1, nil)
    }

    // MARK: Настройки сервера

    func settings() async throws -> [String: Any] {
        try await HTTP.json(HTTP.postJSON(base.appending(path: "settings"), body: ["action": "get"], headers: headers))
    }

    func setSettings(_ sets: [String: Any]) async throws {
        _ = try await HTTP.postJSON(base.appending(path: "settings"), body: ["action": "set", "sets": sets], headers: headers)
    }

    // MARK: Разбор

    /// Битрейт байт/с с запасом: длительность известна — по ней +15 %, нет — как у 45-минутной серии.
    static func estimatedBitrate(fileBytes: Int64, duration: Double) -> Int64 {
        let value = duration >= 20 * 60 ? Int64(Double(fileBytes) / duration * 1.15) : fileBytes / 2700
        return max(250_000, value)
    }

    /// Запас для старта: ~15 с видео, но не меньше 8 МиБ.
    static func earlyStartBytes(_ bitrate: Int64) -> Int64 { max(8 << 20, bitrate * 15) }

    static func parse(_ row: [String: Any]) throws -> TorrentInfo {
        let hash = (row["hash"] as? String ?? "").lowercased()
        guard Rx("^[a-f0-9]{40}$").matches(hash) else { throw HTTPError.invalidResponse }
        let stats = row["file_stats"] as? [[String: Any]] ?? []
        let files: [TorrentFile] = stats.compactMap { file in
            let path = file["path"] as? String ?? ""
            let id = (file["id"] as? NSNumber)?.intValue ?? 0
            let ext = (path as NSString).pathExtension.lowercased()
            guard id > 0, videoExtensions.contains(ext) else { return nil }
            return TorrentFile(index: id, path: path, bytes: (file["length"] as? NSNumber)?.int64Value ?? 0)
        }
        let title = [row["title"] as? String, row["name"] as? String].compactMap { $0 }.first { !$0.isEmpty } ?? hash
        return TorrentInfo(hash: hash, title: title, files: files, peers: (row["active_peers"] as? NSNumber)?.intValue ?? 0,
                           speed: Int64((row["download_speed"] as? NSNumber)?.doubleValue ?? 0), metadataReady: !stats.isEmpty)
    }
}

/// Флаг между задачами.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var value: Bool { lock.withLock { raised } }
    func set() { lock.withLock { raised = true } }
    func lower() { lock.withLock { raised = false } }
}
