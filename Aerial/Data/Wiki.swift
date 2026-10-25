import Foundation

/// Раздел статьи Википедии о работе.
struct WikiStory: Hashable, Sendable {
    var heading: String
    var text: String
    var source: URL
}

/// История создания и сюжет из Википедии — перенос `WikiStories` ТВ. Статья находится по номеру TMDb в Wikidata (P4947 —
/// фильм, P4983 — сериал), а не по угаданному названию; раздел — по заголовку ([WikiPolicy]). Ответ живёт неделю.
enum Wiki {
    /// «История создания» — по-русски, иначе по-английски.
    static func story(_ item: VodItem) async -> WikiStory? {
        await section(item, languages: AppLanguage.english ? ["en", "ru"] : ["ru", "en"], tag: "story", priority: WikiPolicy.storyPriority)
    }

    /// Раздел «Сюжет» — опора для «Разбора фильма»: сначала английская статья, сюжет там обычно подробнее.
    static func plot(_ item: VodItem) async -> WikiStory? {
        await section(item, languages: ["en", "ru"], tag: "plot", priority: WikiPolicy.plotPriority)
    }

    private struct Cached: Codable {
        var heading: String
        var text: String
        var source: String
    }

    private static func section(_ item: VodItem, languages: [String], tag: String, priority: (String) -> Int?) async -> WikiStory? {
        guard item.remoteId > 0 else { return nil }
        let cacheKey = "wiki2:\(tag):\(item.id):\(languages.joined(separator: ","))"
        if let data = DiskCache.api.get(cacheKey, ttl: 7 * DiskCache.day),
           let cached = try? JSONDecoder().decode(Cached.self, from: data), let url = URL(string: cached.source) {
            return WikiStory(heading: cached.heading, text: cached.text, source: url)
        }
        do {
            let property = item.kind == .movie ? "P4947" : "P4983"
            let sites = languages.map { "<https://\($0).wikipedia.org/>" }.joined(separator: " ")
            let query = """
            SELECT ?entity ?article WHERE {
              ?entity <http://www.wikidata.org/prop/direct/\(property)> "\(item.remoteId)" .
              VALUES ?site { \(sites) }
              ?article <http://schema.org/about> ?entity ; <http://schema.org/isPartOf> ?site .
            } LIMIT 4
            """
            let matches = try await json("https://query.wikidata.org/sparql", ["query": query, "format": "json"])
            let rows = ((matches["results"] as? [String: Any])?["bindings"] as? [[String: Any]]) ?? []
            func value(_ row: [String: Any], _ key: String) -> String? { (row[key] as? [String: Any])?["value"] as? String }
            let entities = Set(rows.compactMap { value($0, "entity") })
            guard entities.count == 1 else { return nil }
            let articles = rows.compactMap { value($0, "article") }
            guard let article = languages.lazy.compactMap({ language in articles.first { $0.hasPrefix("https://\(language).wikipedia.org/wiki/") } }).first,
                  let url = URL(string: article), let host = url.host else { return nil }
            let page = url.path.replacingOccurrences(of: "/wiki/", with: "").removingPercentEncoding ?? ""
            let endpoint = "https://\(host)/w/api.php"
            let list = try await json(endpoint, ["action": "parse", "page": page, "prop": "sections", "format": "json"])
            let sections = ((list["parse"] as? [String: Any])?["sections"] as? [[String: Any]]) ?? []
            guard let chosen = sections.filter({ priority($0["line"] as? String ?? "") != nil })
                .min(by: { priority($0["line"] as? String ?? "")! < priority($1["line"] as? String ?? "")! }),
                  let index = chosen["index"] as? String else { return nil }
            let parsed = try await json(endpoint, ["action": "parse", "page": page, "section": index, "prop": "text", "format": "json",
                                                   "disableeditsection": "1"])
            let html = ((parsed["parse"] as? [String: Any])?["text"] as? [String: Any])?["*"] as? String ?? ""
            let plain = WikiPolicy.plainText(html)
            guard plain.count >= 120 else { return nil }
            let limit = 6000
            let text = plain.count > limit ? String(plain.prefix(limit)).components(separatedBy: " ").dropLast().joined(separator: " ") + "…" : plain
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.fragment = chosen["anchor"] as? String
            let source = components?.url ?? url
            let heading = WikiPolicy.stripTags(chosen["line"] as? String ?? "")
            if let data = try? JSONEncoder().encode(Cached(heading: heading, text: text, source: source.absoluteString)) {
                DiskCache.api.put(cacheKey, data)
            }
            return WikiStory(heading: heading, text: text, source: source)
        } catch {
            if !HTTP.isCancellation(error) { Log.note("WIKI", error.localizedDescription) }
            return nil
        }
    }

    private static func json(_ endpoint: String, _ params: [String: String]) async throws -> [String: Any] {
        guard var components = URLComponents(string: endpoint) else { throw HTTPError.invalidResponse }
        components.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw HTTPError.invalidResponse }
        let data = try await HTTP.get(url, timeout: 15, headers: ["User-Agent": "AerialiOS/1.0 (read-only film production stories)",
                                                                   "Accept": "application/json"])
        return try HTTP.json(data)
    }
}

/// Какие разделы брать и как чистить HTML статьи — как `WikiStoryPolicy` ТВ.
enum WikiPolicy {
    static func storyPriority(_ title: String) -> Int? {
        switch stripTags(title).lowercased() {
        case "production", "создание", "производство", "история создания": 0
        case "filming", "съёмки", "съемки", "съёмочный процесс": 1
        case "development", "разработка", "подготовка к съёмкам": 2
        case "casting", "подбор актёров", "подбор актеров": 3
        default: nil
        }
    }

    static func plotPriority(_ title: String) -> Int? {
        switch stripTags(title).lowercased() {
        case "plot", "сюжет": 0
        case "plot summary", "synopsis", "storyline", "описание сюжета", "содержание", "синопсис": 1
        case "premise", "summary", "завязка": 2
        default: nil
        }
    }

    static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// Служебные блоки (плашки для редакторов, навигация, сноски, картинки, таблицы) — вон; абзацы — пустой строкой.
    static func plainText(_ html: String) -> String {
        var text = stripServiceBlocks(html)
        for pattern in ["(?is)<(sup|table|style|script|h[1-6]|figure)\\b[^>]*>.*?</\\1>", "(?i)<img\\b[^>]*>"] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "(?i)</p>|<br\\s*/?>|</li>|</dd>", with: "\n\n", options: .regularExpression)
        text = stripTags(text)
        // Неразрывный пробел (&#160;) — обычным: иначе текст рвётся и сравнивается не так.
        text = decodeEntities(text).replacingOccurrences(of: "\u{00A0}", with: " ")
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let serviceClass = Rx("\\b(ambox|mbox|tmbox|ombox|cmbox|fmbox|ts-|hatnote|dablink|metadata|noprint|navbox|shortdescription|reference|mw-editsection|mw-empty-elt|plainlinks|sistersitebox|side-box|infobox|thumb|gallery)")

    /// Блоки со служебным классом вырезаются целиком, с учётом вложенности одноимённых тегов.
    static func stripServiceBlocks(_ html: String) -> String {
        guard let open = try? NSRegularExpression(pattern: "<(div|table|span|ul|ol|p|figure|aside)\\b[^>]*\\bclass\\s*=\\s*\"([^\"]*)\"[^>]*>",
                                                  options: [.caseInsensitive]) else { return html }
        let source = html as NSString
        var out = ""
        var position = 0
        while position < source.length,
              let match = open.firstMatch(in: html, range: NSRange(location: position, length: source.length - position)) {
            let classes = source.substring(with: match.range(at: 2))
            let end = match.range.location + match.range.length
            if !serviceClass.matches(classes) {
                out += source.substring(with: NSRange(location: position, length: end - position))
                position = end
                continue
            }
            out += source.substring(with: NSRange(location: position, length: match.range.location - position))
            let tag = source.substring(with: match.range(at: 1)).lowercased()
            guard let any = try? NSRegularExpression(pattern: "<(/?)\(tag)\\b[^>]*>", options: [.caseInsensitive]) else { break }
            var depth = 1
            var index = end
            while depth > 0, let next = any.firstMatch(in: html, range: NSRange(location: index, length: source.length - index)) {
                depth += source.substring(with: next.range(at: 1)) == "/" ? -1 : 1
                index = next.range.location + next.range.length
            }
            position = depth > 0 ? source.length : index
        }
        if position < source.length { out += source.substring(from: position) }
        return out
    }

    static func decodeEntities(_ text: String) -> String {
        var out = text
        for (entity, value) in [("&nbsp;", " "), ("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"),
                                ("&laquo;", "«"), ("&raquo;", "»"), ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…")] {
            out = out.replacingOccurrences(of: entity, with: value)
        }
        guard let numeric = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") else { return out }
        let source = out as NSString
        var result = ""
        var last = 0
        for match in numeric.matches(in: out, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: last, length: match.range.location - last))
            let hex = source.substring(with: match.range(at: 1)) == "x"
            let digits = source.substring(with: match.range(at: 2))
            if let code = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                result += String(Character(scalar))
            }
            last = match.range.location + match.range.length
        }
        result += source.substring(from: last)
        return result
    }
}
