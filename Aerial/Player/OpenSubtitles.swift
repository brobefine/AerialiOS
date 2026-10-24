import Foundation

/// Поиск субтитров на OpenSubtitles.com прямо из плеера — перенос `OpenSubtitles` ПК (как VLsub в VLC). REST API v1:
/// поиск по TMDb (точнее всего), у сериала — по сезону и серии; скачивание файла по номеру. Ключ — свой, бесплатный
/// (opensubtitles.com/consumers).
enum OpenSubtitles {
    struct Result: Identifiable, Hashable, Sendable {
        var fileId: Int
        var language: String
        var release: String
        var downloads: Int
        var id: Int { fileId }
    }

    enum Failure: LocalizedError {
        case status(Int), limit, noLink

        var errorDescription: String? {
            switch self {
            case .status(let code): "OpenSubtitles ответил \(code)"
            case .limit: "Лимит скачиваний OpenSubtitles на сегодня исчерпан"
            case .noLink: "OpenSubtitles не дал ссылку на файл"
            }
        }
    }

    private static let api = "https://api.opensubtitles.com/api/v1"

    private static func request(_ url: URL, key: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(key, forHTTPHeaderField: "Api-Key")
        request.setValue("Aerial v1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func search(key: String, item: VodItem, episode: VodEpisode?, languages: String) async throws -> [Result] {
        guard var components = URLComponents(string: "\(api)/subtitles") else { return [] }
        var query: [URLQueryItem] = []
        if item.remoteId > 0 {
            query.append(URLQueryItem(name: episode != nil ? "parent_tmdb_id" : "tmdb_id", value: String(item.remoteId)))
        } else {
            query.append(URLQueryItem(name: "query", value: item.title))
        }
        if let episode {
            query.append(URLQueryItem(name: "season_number", value: String(episode.season)))
            query.append(URLQueryItem(name: "episode_number", value: String(episode.number)))
        }
        query.append(URLQueryItem(name: "languages", value: languages.replacingOccurrences(of: " ", with: "")))
        query.append(URLQueryItem(name: "order_by", value: "download_count"))
        components.queryItems = query
        guard let url = components.url else { return [] }
        let (data, response) = try await HTTP.session.data(for: request(url, key: key))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw Failure.status(code) }
        let rows = (try HTTP.json(data)["data"] as? [[String: Any]]) ?? []
        return rows.compactMap { row -> Result? in
            guard let attributes = row["attributes"] as? [String: Any],
                  let file = (attributes["files"] as? [[String: Any]])?.first,
                  let id = (file["file_id"] as? NSNumber)?.intValue, id > 0 else { return nil }
            let release = attributes["release"] as? String ?? ""
            return Result(fileId: id, language: attributes["language"] as? String ?? "",
                          release: release.isEmpty ? file["file_name"] as? String ?? "" : release,
                          downloads: (attributes["download_count"] as? NSNumber)?.intValue ?? 0)
        }.prefix(30).map { $0 }
    }

    /// Скачать файл субтитров во временную папку; путь к файлу.
    static func download(key: String, _ result: Result) async throws -> URL {
        guard let url = URL(string: "\(api)/download") else { throw Failure.noLink }
        var post = request(url, key: key)
        post.httpMethod = "POST"
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.httpBody = try JSONSerialization.data(withJSONObject: ["file_id": result.fileId])
        let (data, response) = try await HTTP.session.data(for: post)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 406 || code == 429 { throw Failure.limit }
        guard code == 200 else { throw Failure.status(code) }
        let json = try HTTP.json(data)
        guard let link = (json["link"] as? String).flatMap(URL.init(string:)) else { throw Failure.noLink }
        let name = Downloads.safe((json["file_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "sub-\(result.fileId).srt")
        let bytes = try await HTTP.get(link, timeout: 30)
        let directory = FileManager.default.temporaryDirectory.appending(path: "subs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: name)
        try bytes.write(to: file, options: .atomic)
        return file
    }
}
