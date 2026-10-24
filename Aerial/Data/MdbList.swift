import Foundation

/// Оценки IMDb, Rotten Tomatoes, Metacritic и Letterboxd из MDBList — перенос `MdbListRatings` ТВ. Нужен свой ключ
/// (бесплатный, mdblist.com/preferences). Ответ живёт сутки в [DiskCache]; отказ ключа (401/403) — до смены ключа,
/// лимит (429) — до сброса лимита.
enum MdbList {
    private static let blockedKey = "mdblist.blocked"

    static func ratings(_ item: VodItem, key: String) async -> String {
        // Свой ключ пользователя главнее; нет — ключ приложения из сборки (как режим «app» у ТВ).
        let own = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = own.isEmpty ? BuildKeys.mdblist : own
        guard !token.isEmpty, item.remoteId > 0 else { return "" }
        let blocked = UserDefaults.standard.dictionary(forKey: blockedKey) as? [String: Double] ?? [:]
        let authId = stableId(token)
        if let until = blocked[authId], until > Date().timeIntervalSince1970 { return "" }
        let type = item.kind == .series ? "show" : "movie"
        let cacheKey = "mdblist:\(authId):\(type):\(item.remoteId)"
        if let cached = DiskCache.api.get(cacheKey, ttl: DiskCache.day) { return format(cached) }
        var components = URLComponents(string: "https://api.mdblist.com/tmdb/\(type)/\(item.remoteId)/")
        components?.queryItems = [URLQueryItem(name: "apikey", value: token)]
        guard let url = components?.url else { return "" }
        do {
            let (data, response) = try await HTTP.session.data(for: URLRequest(url: url, timeoutInterval: 4))
            guard let http = response as? HTTPURLResponse else { return "" }
            if [401, 403, 429].contains(http.statusCode) {
                let now = Date().timeIntervalSince1970
                let until: Double
                if http.statusCode != 429 {
                    until = .greatestFiniteMagnitude
                } else if http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0",
                          let reset = Double(http.value(forHTTPHeaderField: "X-RateLimit-Reset") ?? ""), reset > now {
                    until = reset
                } else {
                    until = now + max(1, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 300)
                }
                var updated = blocked
                updated[authId] = until
                UserDefaults.standard.set(updated, forKey: blockedKey)
                Log.note("MDBLIST", "HTTP \(http.statusCode): пауза запросов")
                return ""
            }
            guard (200..<300).contains(http.statusCode),
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ids = body["ids"] as? [String: Any], (ids["tmdb"] as? NSNumber)?.intValue == item.remoteId else { return "" }
            DiskCache.api.put(cacheKey, data)
            return format(data)
        } catch {
            return ""
        }
    }

    /// Новый ключ — снять паузу запросов.
    static func unblock() {
        UserDefaults.standard.removeObject(forKey: blockedKey)
    }

    static func format(_ data: Data) -> String {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = body["ratings"] as? [[String: Any]] else { return "" }
        var values: [String: Double] = [:]
        for row in rows {
            if let source = row["source"] as? String, let value = (row["value"] as? NSNumber)?.doubleValue { values[source] = value }
        }
        return format(values)
    }

    static func format(_ values: [String: Double]) -> String {
        ["imdb", "tomatoes", "popcorn", "metacritic", "letterboxd"].compactMap { source -> String? in
            guard let value = values[source], value.isFinite else { return nil }
            switch source {
            case "imdb": return (0...10).contains(value) ? String(format: "IMDb %.1f", value) : nil
            case "tomatoes": return (0...100).contains(value) ? "🍅 \(Int(value))%" : nil
            case "popcorn": return (0...100).contains(value) ? "🍿 \(Int(value))%" : nil
            case "metacritic": return (0...100).contains(value) ? "Metacritic \(Int(value))" : nil
            default: return (0...5).contains(value) ? String(format: "Letterboxd %.1f", value) : nil
            }
        }.joined(separator: " · ")
    }

    /// Короткий отпечаток ключа — сам ключ в кэш и настройки не пишется.
    private static func stableId(_ token: String) -> String {
        String(format: "%08x", UInt32(bitPattern: Recommendations.javaHash(token)))
    }
}
