import Foundation

enum HTTPError: LocalizedError {
    case status(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .status(let code): "HTTP \(code)"
        case .invalidResponse: "Некорректный ответ сервера"
        }
    }
}

/// Сеть приложения. Кэш URLSession выключен: ответы API кэширует [DiskCache], картинки — [ImageLoader].
enum HTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 120
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()

    static func data(_ request: URLRequest, session: URLSession = session) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HTTPError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw HTTPError.status(http.statusCode) }
        return data
    }

    static func get(_ url: URL, timeout: TimeInterval = 15, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        return try await data(request)
    }

    static func postJSON(_ url: URL, body: [String: Any], timeout: TimeInterval = 15,
                         headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        return try await data(request)
    }

    static func json(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HTTPError.invalidResponse
        }
        return object
    }

    /// Отмена задачи — не ошибка сети: её не пишем в журнал и не показываем.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }
}

extension URL {
    /// Адрес с параметрами запроса; пустые значения дают параметр без `=` (`?play`), как ждёт TorrServer.
    func with(query items: [(String, String?)]) -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
        var query = components.queryItems ?? []
        query += items.map { URLQueryItem(name: $0.0, value: $0.1) }
        components.queryItems = query
        // `+` в значении URLComponents оставляет как есть, а серверы читают его как пробел.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url ?? self
    }
}
