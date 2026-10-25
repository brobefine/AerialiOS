import CryptoKit
import Foundation

/// Название, которое назвал ИИ; в каталог попадает только после проверки поиском TMDb ([Catalogue.resolve]).
struct AiTitle: Hashable, Sendable {
    var title: String
    var original: String
    var year: Int
    var tv: Bool
    var why = ""
}

/// Подборка по ощущению или механике сюжета.
struct AiCollection: Sendable {
    var title: String
    var why: String
    var items: [AiTitle]
}

struct AiSection: Hashable, Sendable {
    var title: String
    var text: String
}

enum AiError: LocalizedError {
    case noKey, empty, http(String), regionBlocked, bad

    var errorDescription: String? {
        switch self {
        case .noKey: "Нет ключа ИИ"
        case .empty: "ИИ ничего не ответил"
        case .http(let text): text
        case .regionBlocked: "Google и Groq не обслуживают вашу страну"
        case .bad: "ИИ ответил непонятно"
        }
    }
}

/// ИИ кинотеки — перенос `AiClient` ТВ: напрямую в Gemini (основной) и Groq (запасной) с ключом пользователя. В странах,
/// которые Google и Groq не обслуживают (Россия, Беларусь…), работает только через VPN — настройки говорят об этом
/// прямо ([regionBlocked]). Ответы — в [DiskCache] со сроком по смыслу: тот же запрос к модели повторно не идёт.
/// Тексты запросов — те же, что у ТВ.
enum AI {
    /// Ключи живут в UserDefaults (их пишет [AppSettings]): так ИИ читает их из любого потока.
    static var on: Bool { UserDefaults.standard.object(forKey: "ai.on") as? Bool ?? true }
    static var geminiKey: String { (UserDefaults.standard.string(forKey: "ai.gemini") ?? "").trimmingCharacters(in: .whitespaces) }
    static var groqKey: String { (UserDefaults.standard.string(forKey: "ai.groq") ?? "").trimmingCharacters(in: .whitespaces) }
    static var enabled: Bool { on && (!geminiKey.isEmpty || !groqKey.isEmpty) }

    private static let blocked = Flag()
    /// Google или Groq ответили, что страна не поддерживается.
    static var regionBlocked: Bool { blocked.value }

    private static let hour: TimeInterval = 3600
    private static let day: TimeInterval = 86400

    // MARK: Запросы

    /// Фильм или сериал по описанию своими словами.
    static func find(_ query: String) async throws -> [AiTitle] {
        let q = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        guard q.count >= 3 else { return [] }
        let text = try await cached("find2", [AppLanguage.english ? "en" : "ru", q.lowercased()], ttl: 7 * day) {
            try await generate("A viewer is trying to remember a movie or TV series and describes it from memory: \"\(q)\".\n" +
                "Memory is unreliable: ANY detail in the description may be distorted, exaggerated, merged from another film or simply wrong " +
                "(objects, body parts, numbers, names, places, order of events, genre). Do not require literal matches. " +
                "Reason about the core of what they remember — the situation, who the characters are to each other, the turning point, " +
                "the mood and genre feel — and find titles whose actual scenes or plot match that core best, even if several details differ. " +
                "Never discard a candidate because one detail does not match. Prefer well-known titles only when they genuinely fit.\n" +
                "Return up to 8 candidates, best match first, as a JSON array of objects {\"title\": title in \(AppLanguage.ai) if it exists, else original, " +
                "\"original\": original title, \"year\": release year as number, \"type\": \"movie\" or \"tv\"}. Only real, existing titles. " +
                "If nothing plausible fits, return []. Output only the JSON array.", json: true)
        }
        return titles(text)
    }

    /// Коротко о чём отзывы: 2–3 предложения.
    static func summary(title: String, reviews: [String]) async throws -> String {
        let rows = reviews.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1500)) }.filter { !$0.isEmpty }.prefix(15)
        guard rows.count >= 2 else { throw AiError.empty }
        let name = String(title.prefix(200))
        return try await cached("summary2", [AppLanguage.english ? "en" : "ru", name] + rows, ttl: 30 * day) {
            try await generate("Here are viewer reviews of \"\(name)\". Summarize what viewers think in \(AppLanguage.ai): 2–3 short sentences — " +
                "the overall verdict, what they praise, what they criticise. No spoilers, no quotes, no list markers, no intro phrase, " +
                "no filler or generic phrases — only concrete points viewers actually make.\n\n" +
                rows.enumerated().map { "Review \($0.offset + 1):\n\($0.element)" }.joined(separator: "\n\n"))
        }
    }

    /// Что ещё может понравиться: по любимым (с завязкой сюжета в [скобках]) и отвергнутым, без уже известного.
    static func recommend(liked: [String], disliked: [String], exclude: [String], abandoned: [String] = [], count: Int = 24) async throws -> [AiTitle] {
        let like = liked.map { String($0.prefix(400)) }.prefix(25)
        guard !like.isEmpty else { return [] }
        let dis = disliked.map { String($0.prefix(120)) }.prefix(25)
        let ex = exclude.map { String($0.prefix(120)) }.prefix(60)
        let drop = abandoned.map { String($0.prefix(120)) }.prefix(10)
        let text = try await cached("recommend4", [AppLanguage.english ? "en" : "ru", "movies or TV series", like.joined(separator: "|"), dis.joined(separator: "|"),
                                                   drop.joined(separator: "|"), ex.joined(separator: "|")], ttl: 12 * hour) {
            try await generate("A viewer liked: \(like.joined(separator: "; "))." +
                (dis.isEmpty ? "" : " They did not like: \(dis.joined(separator: "; "))." ) + dropped(Array(drop)) + " \(plotHints)" +
                " Suggest \(min(30, max(6, count))) movies or TV series they would probably enjoy, varied, not obvious sequels of the liked ones, " +
                "and not in this list: \(ex.isEmpty ? "—" : ex.joined(separator: "; ")). " +
                "Return a JSON array of objects {\"title\": title in \(AppLanguage.ai) if it exists, else original, \"original\": original title, " +
                "\"year\": release year as number, \"type\": \"movie\" or \"tv\"}. Only real, existing titles.", json: true, temperature: 0.7)
        }
        return titles(text)
    }

    /// Подборки по ощущениям, атмосфере и механике сюжета — по любимым.
    static func collections(liked: [String], disliked: [String], exclude: [String], abandoned: [String] = []) async throws -> [AiCollection] {
        let like = liked.map { String($0.prefix(400)) }.prefix(25)
        guard like.count >= 2 else { return [] }
        let dis = disliked.map { String($0.prefix(120)) }.prefix(25)
        let ex = exclude.map { String($0.prefix(120)) }.prefix(60)
        let drop = abandoned.map { String($0.prefix(120)) }.prefix(10)
        let text = try await cached("collections6", [AppLanguage.english ? "en" : "ru", like.joined(separator: "|"), dis.joined(separator: "|"), drop.joined(separator: "|")],
                                    ttl: 24 * hour) {
            try await generate("A viewer liked: \(like.joined(separator: "; "))." +
                (dis.isEmpty ? "" : " They did not like: \(dis.joined(separator: "; "))." ) + dropped(Array(drop)) + " \(plotHints)" +
                " Invent 5 personal collections for them, each grouping films or TV series by a FEELING, ATMOSPHERE, PLOT MECHANISM or UNUSUAL " +
                "COINCIDENCE rather than by genre (e.g. \"quiet existential dread\", \"a time loop without science fiction\", \"one location, one night\", " +
                "\"strangers who become family\"). Base 3 collections on what their liked titles have in common. " +
                "Build the other 2 around the concrete plot mechanism or premise of ONE specific liked title each (prefer all-time favourites " +
                "and titles with a plot hint), and name it so the link is visible, e.g. \"A wish with a catch — like Obsession\". These 2 must " +
                "deliberately cross genres and tones: horror next to family comedy, drama or fantasy, as long as the mechanism matches literally " +
                "(illustration only: for a horror about a wish that comes true with a terrible price — 16 Wishes, Bruce Almighty, Click, Bedazzled; " +
                "do not reuse this example unless such a liked title is really there). " +
                "Each collection: 10 real titles they probably have not seen, not in this list: \(ex.isEmpty ? "—" : ex.joined(separator: "; ")).\n" +
                "Pick the titles a well-read film critic would name FIRST for each collection: the most iconic, beloved and best-rated ones, " +
                "then less obvious gems. When a collection is about a country, era or culture, include that country's own films and TV series " +
                "(for Soviet or Russian life — Russian productions such as series by STS, TNT, Channel One, Russia-1, KinoPoisk), not only foreign ones. " +
                "Every title must fit the collection's time period and setting literally (a story set today does not belong to \"the 1970s\").\n" +
                "STRICT: every title must match EVERY concrete detail of its collection name (setting, situation, mechanism). " +
                "If a detail like a place (\"island\", \"space station\") is in the name, every film must actually have it; if you cannot find " +
                "8 titles that fit exactly, make the name broader (e.g. \"an isolated group fighting to survive\") or return fewer titles. " +
                "Do not add a title that only matches the mood.\n" +
                "Return a JSON array [{\"title\": collection name in \(AppLanguage.ai) (max 55 chars), \"why\": one short sentence in \(AppLanguage.ai), " +
                "\"items\": [{\"title\": title in \(AppLanguage.ai) if it exists, else original, \"original\": original title, \"year\": number, \"type\": \"movie\" or \"tv\"}]}].",
                json: true, temperature: 0.7, strong: true)
        }
        let parsed = parseJSON(text)
        let rows = parsed as? [[String: Any]] ?? (parsed as? [String: Any])?["collections"] as? [[String: Any]] ?? []
        return rows.prefix(6).map { row in
            AiCollection(title: String((row["title"] as? String ?? "").prefix(60)), why: String((row["why"] as? String ?? "").prefix(160)),
                         items: titles(row["items"] as? [[String: Any]] ?? []))
        }.filter { !$0.title.isEmpty && !$0.items.isEmpty }
    }

    /// Перевод на русский (длинный — частями по ~4000 символов, параллельно): отзыв или, `what`, биография.
    static func translate(_ text: String, what: String = "movie review") async throws -> String {
        let parts = split(text, limit: 4000)
        return try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (index, part) in parts.enumerated() {
                group.addTask {
                    let out = try await cached("translate", [AppLanguage.english ? "en" : "ru", part], ttl: 30 * day) {
                        try await generate("Translate the following \(what) into \(AppLanguage.ai). Keep the meaning, tone and paragraph breaks. " +
                            "Output only the translation, without comments or quotes.\n\n\(part)")
                    }
                    return (index, out.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            var done: [Int: String] = [:]
            for try await (index, out) in group { done[index] = out }
            return parts.indices.compactMap { done[$0] }.joined(separator: "\n")
        }
    }

    /// Нужен ли перевод на русский: кириллицы меньше трети букв.
    static func needsTranslation(_ text: String) -> Bool {
        let letters = text.filter(\.isLetter)
        guard !letters.isEmpty else { return false }
        let cyrillic = letters.filter { ("а"..."я").contains(String($0).lowercased()) || $0 == "ё" || $0 == "Ё" }
        return Double(cyrillic.count) / Double(letters.count) < 0.3
    }

    /// Опознавательные данные работы: режиссёр, актёры, жанры, описание — чтобы модель говорила именно о ней.
    private static func identity(_ details: VodDetails) -> String {
        let item = details.item
        var parts: [String] = []
        let directors = details.directors.map(\.name).joined(separator: ", ")
        if !directors.isEmpty { parts.append("Directed by \(directors.prefix(120)).") }
        let cast = details.cast.prefix(4).map(\.name).joined(separator: ", ")
        if !cast.isEmpty { parts.append("Starring \(cast.prefix(200)).") }
        if !item.genres.isEmpty { parts.append("Genres: \(item.genres.joined(separator: " / ").prefix(120)).") }
        if !item.overview.isEmpty { parts.append("Plot summary: \(item.overview.prefix(900))") }
        return parts.isEmpty ? "" : " " + parts.joined(separator: " ")
    }

    private static func titleOf(_ details: VodDetails) -> String {
        String((details.item.originalTitle.isEmpty ? details.item.title : details.item.originalTitle).prefix(200))
    }

    /// «Духовные родственники»: связанные темами этой работы, а не жанром; `why` — общая тема.
    static func relatives(_ details: VodDetails, avoid: [String] = []) async throws -> [AiTitle] {
        let title = titleOf(details)
        let year = Int(details.item.year) ?? 0
        let tv = details.item.kind == .series
        let kind = tv ? "TV series" : "film"
        let about = identity(details)
        let av = avoid.map { String($0.prefix(80)) }.filter { !$0.isEmpty }.prefix(40)
        let franchise = details.collection.filter { $0.id != details.item.id }
            .map { "\(($0.originalTitle.isEmpty ? $0.title : $0.originalTitle).prefix(80)) (\($0.year))" }.prefix(15)
        // Ключ кэша сменён: прежние ответы могли содержать спойлеры.
        let text = try await cached("relatives7", [AppLanguage.english ? "en" : "ru", title, String(year), kind, about, av.joined(separator: "|"), franchise.joined(separator: "|")],
                                    ttl: 30 * day) {
            try await generate("\(kind) \"\(title)\"\(year > 0 ? " (\(year))" : "").\(about)\n" +
                "Step 1: name the 3–4 central themes, emotional experiences or questions of THIS specific work (from its plot above, not from the title alone).\n" +
                "Step 2: list 10 \"spiritual relatives\" — films or TV series that share those themes or that emotional experience, " +
                "NOT simply the same genre, setting or franchise. They may be from completely different genres and eras. " +
                "Each one must connect to at least one of the themes from step 1 through something CONCRETE in this work's plot or situation, " +
                "not through generic notions like \"loss\", \"meaning\" or \"faith\" alone. Avoid go-to picks you would suggest for almost any thoughtful film " +
                "(the usual acclaimed prestige TV series about grief and mystery) unless the connection to THIS plot is specific and strong. " +
                (tv ? "" : "Since this is a film, include at most 2 TV series. ") + "No sequels, prequels, remakes or other parts of its franchise" +
                (franchise.isEmpty ? "" : " (its franchise: \(franchise.joined(separator: "; ")))") + ".\n" +
                "Work like a film critic curating a festival sidebar: privately brainstorm about 25 candidates, then keep the 10 whose link to THIS " +
                "plot is the most specific and surprising. Diversity rules: at most 3 titles from the same decade, at least 2 not in English, " +
                "at most 2 titles that are on everyone's \"best of\" lists. The \"default canon\" (e.g. The Leftovers, Lost, Dark, Twin Peaks, Arrival, " +
                "Interstellar, Eternal Sunshine of the Spotless Mind, Black Mirror, The Truman Show, Donnie Darko, Westworld) is allowed only if " +
                "the plot connection is literal and obvious — never as a mood filler.\n" +
                (av.isEmpty ? "" : "Do NOT suggest any of these — they were already suggested for many other titles: \(av.joined(separator: "; ")). " +
                    "Dig deeper: lesser-known but fitting works, other countries and decades.\n") +
                "Return a JSON object {\"themes\": [short theme names in \(AppLanguage.ai)], \"items\": [{\"title\": title in \(AppLanguage.ai) if it exists, else original, " +
                "\"original\": original title, \"year\": release year as number, \"type\": \"movie\" or \"tv\", " +
                "\"why\": the shared theme in \(AppLanguage.ai), one short phrase (max 70 chars)}]}. Only real, existing titles.\n" +
                SpoilerGuard.rules,
                json: true, temperature: 0.6, strong: true)
        }
        return titles(text, withWhy: true)
    }

    /// «Чем связан» без спойлеров — по смыслу: проверка, переписывание отмеченных, повторная проверка ([SpoilerGuard]).
    /// Отдельно от подбора: фильмы показываются сразу, а описания — когда проверка закончится.
    static func safeWhys(_ details: VodDetails, _ picks: [AiTitle]) async -> [AiTitle] {
        let title = titleOf(details)
        let year = Int(details.item.year) ?? 0
        let started = Date()
        let seed = "\(title)\(year > 0 ? " (\(year))" : "")"
        let pairs = picks.map { (title: $0.original.isEmpty ? $0.title : $0.original, why: $0.why) }
        let checked = try? await cached("spoilers2", [AppLanguage.english ? "en" : "ru", seed] + pairs.map { "\($0.title)|\($0.why)" }, ttl: 30 * day) {
            try await generate(SpoilerGuard.checkPrompt(seed: seed, items: pairs), json: true, temperature: 0, strong: true)
        }
        let verdict = SpoilerGuard.parseVerdict(checked)
        var rewrites: [Int: String] = [:]
        var recheck: Set<Int>?
        if let verdict, !verdict.isEmpty {
            let flagged = verdict.sorted().filter { $0 < pairs.count }.map { (index: $0, title: pairs[$0].title, why: pairs[$0].why) }
            let rewritten = try? await cached("spoilerfix1", [AppLanguage.english ? "en" : "ru", seed] + flagged.map { "\($0.index)|\($0.title)|\($0.why)" }, ttl: 30 * day) {
                try await generate(SpoilerGuard.rewritePrompt(seed: seed, items: flagged), json: true, temperature: 0.3, strong: true)
            }
            rewrites = SpoilerGuard.parseRewrites(rewritten)
            // Повторная проверка переписанного; номера — исходные.
            let fixed = rewrites.keys.sorted()
            let fixedPairs = fixed.map { (title: pairs[$0].title, why: rewrites[$0] ?? "") }
            let rechecked = try? await cached("spoilers2", [AppLanguage.english ? "en" : "ru", seed] + fixedPairs.map { "\($0.title)|\($0.why)" }, ttl: 30 * day) {
                try await generate(SpoilerGuard.checkPrompt(seed: seed, items: fixedPairs), json: true, temperature: 0, strong: true)
            }
            let again = SpoilerGuard.parseVerdict(rechecked)
            recheck = again.map { Set($0.compactMap { $0 < fixed.count ? fixed[$0] : nil }) }
        }
        let safe = SpoilerGuard.merge(picks, verdict: verdict, rewrites: rewrites, recheck: recheck)
        let changed = zip(picks, safe).filter { $0.0.why != $0.1.why }.count
        Log.note("ИИ", String(format: "родственники «%@»: проверка спойлеров %.1f с, переписано %d", title,
                              Date().timeIntervalSince(started), changed))
        return safe
    }

    /// Разбор после просмотра. Сериал — до сезона/серии включительно. [plot] — раздел «Сюжет» Википедии: модель разбирает
    /// по нему, а не по памяти. nil — модель не знает именно эту работу.
    static func recap(_ details: VodDetails, season: Int = 0, episode: Int = 0, plot: String = "") async throws -> [AiSection]? {
        let title = titleOf(details)
        let year = Int(details.item.year) ?? 0
        let tv = details.item.kind == .series
        let kind = tv ? "TV series" : "feature film"
        let about = identity(details)
        let upTo = tv && season > 0 ? " up to and including season \(season)\(episode > 0 ? ", episode \(episode)" : "")" : ""
        let story = String(plot.trimmingCharacters(in: .whitespacesAndNewlines).prefix(6000))
        let text = try await cached("recap5", [AppLanguage.english ? "en" : "ru", title, String(year), kind, about, upTo, String(story.count), String(story.prefix(200))],
                                    ttl: 30 * day) {
            try await generate("The \(kind) \"\(title)\"\(year > 0 ? " (\(year))" : "")\(upTo).\(about)\n" +
                "Make sure you are describing THIS exact work identified above — not another work with the same or a similar name " +
                "(a web series, a short, a book, a game, an older film or a remake). " +
                (story.isEmpty
                    ? "If you do not know this exact work well enough to describe its actual plot, return {\"unknown\": true} and nothing else — " +
                      "do not guess and do not substitute another work.\n"
                    : "Here is its plot from Wikipedia — treat it as the source of truth for events and names, do not contradict it, " +
                      "and do not add events that are not in it; use your own knowledge only for interpretation, motives and context:\n\"\"\"\n\(story)\n\"\"\"\n") +
                "Write a post-viewing breakdown in \(AppLanguage.ai) for someone who has just finished watching it. Spoilers are expected. " +
                "Leave out details you are not sure about.\n" +
                "Style: concise and specific, no filler. Every sentence must carry a concrete event, motive, detail or insight. " +
                "No generic praise or evaluation (\"masterpiece\", \"brilliantly shows\"), no introductions or conclusions, no restating the same idea in other words, " +
                "no listing what the section is about. Short paragraphs; the plot section may be longer, other sections 1–2 short paragraphs each.\n" +
                "Return a JSON object {\"sections\": [{\"title\": section title, \"text\": several paragraphs}]} with these sections, in this order:\n" +
                "1) the full plot, clearly and in order; 2) characters' motives — why the main characters act as they do; " +
                "3) relationships between the characters and how they change; 4) hidden details, foreshadowing and symbols that are easy to miss; " +
                "5) mysteries and open questions — what the ending means and the main interpretations.", json: true, temperature: 0.2)
        }
        guard let object = parseJSON(text) as? [String: Any] else { throw AiError.bad }
        if object["unknown"] as? Bool == true { return nil }
        guard let rows = object["sections"] as? [[String: Any]] else { throw AiError.bad }
        // Абзацы модель иногда отдаёт массивом — склеиваем пустой строкой.
        func paragraphs(_ value: Any?) -> String {
            if let list = value as? [Any] { return list.map { "\($0)" }.joined(separator: "\n\n") }
            return value.map { "\($0)" } ?? ""
        }
        return rows.prefix(8).map { AiSection(title: String((($0["title"] as? String) ?? "").prefix(80)), text: String(paragraphs($0["text"]).prefix(4500))) }
    }

    /// Понятная причина сбоя: страна, лимит, остальное.
    static func failure(_ error: Error) -> String {
        if regionBlocked { return "ИИ недоступен: Google и Groq не обслуживают вашу страну — нужен VPN." }
        if "\(error)".contains("429") { return "Исчерпан лимит запросов к ИИ. Попробуйте позже." }
        return "ИИ сейчас не ответил. Попробуйте позже."
    }

    // MARK: Общее

    private static let plotHints = "Liked titles carry a short plot hint in [brackets]: trust it over your memory — a title you do not know " +
        "or that shares its name with another work is identified by that hint (often a recent release), and its plot matters for the picks."

    private static func dropped(_ abandoned: [String]) -> String {
        abandoned.isEmpty ? "" : " They started but dropped within the first minutes (a weak negative — maybe just not the mood): " +
            "\(abandoned.joined(separator: "; ")). Titles marked \"watched to the end\" (or \"досмотрел\") were finished — a strong positive."
    }

    /// Ответ ИИ — сначала с устройства; модель не ответила — отдаётся и устаревший ответ.
    private static func cached(_ name: String, _ parts: [String], ttl: TimeInterval, _ compute: () async throws -> String) async throws -> String {
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\n\u{0}").utf8)).map { String(format: "%02x", $0) }.joined()
        let key = "ai2:\(name):\(digest)"
        if let data = DiskCache.api.get(key, ttl: ttl), let text = String(data: data, encoding: .utf8) { return text }
        do {
            let text = try await compute()
            DiskCache.api.put(key, Data(text.utf8))
            return text
        } catch {
            if !HTTP.isCancellation(error), let data = DiskCache.api.stale(key), let text = String(data: data, encoding: .utf8) { return text }
            throw error
        }
    }

    /// Сначала Gemini (перебор моделей: 404/429/500/503 — следующая), не вышло и есть ключ Groq — тот же запрос в Groq.
    /// [strong] — сначала полноценная flash (подборки, «родственники»).
    private static func generate(_ prompt: String, json: Bool = false, temperature: Double = 0.2, strong: Bool = false) async throws -> String {
        var last: Error = AiError.noKey
        if !geminiKey.isEmpty {
            do { return try await gemini(prompt, json: json, temperature: temperature, strong: strong) } catch {
                if HTTP.isCancellation(error) { throw error }
                last = error
            }
        }
        if !groqKey.isEmpty {
            do { return try await groq(prompt, json: json, temperature: temperature) } catch {
                if HTTP.isCancellation(error) { throw error }
                last = error
            }
        }
        Log.note("ИИ", "сбой: \(last.localizedDescription.prefix(200))")
        throw last
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 90
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    private static func post(_ url: URL, _ body: [String: Any], headers: [String: String]) async throws -> (Int, Data) {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    private static func gemini(_ prompt: String, json: Bool, temperature: Double, strong: Bool) async throws -> String {
        let models = strong ? ["gemini-flash-latest", "gemini-flash-lite-latest"] : ["gemini-flash-lite-latest", "gemini-flash-latest"]
        var config: [String: Any] = ["temperature": temperature]
        if json { config["responseMimeType"] = "application/json" }
        let body: [String: Any] = ["contents": [["role": "user", "parts": [["text": prompt]]]], "generationConfig": config]
        var last = "no model"
        for model in models {
            guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent") else { continue }
            let (code, data) = try await post(url, body, headers: ["x-goog-api-key": geminiKey])
            let text = String(data: data, encoding: .utf8) ?? ""
            if (200..<300).contains(code) {
                blocked.lower()
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let candidate = (object?["candidates"] as? [[String: Any]])?.first
                let parts = (candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
                let out = parts.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                if !out.isEmpty { return out }
                last = "empty answer"
            } else {
                last = "gemini \(code) \(text.prefix(200))"
                if text.contains("location is not supported") || text.contains("not available in your country") {
                    blocked.set()
                    throw AiError.regionBlocked
                }
                if ![404, 429, 500, 503].contains(code) { throw AiError.http(last) }
            }
        }
        throw AiError.http(last)
    }

    private static let groqCache = GroqModels()

    private static func groq(_ prompt: String, json: Bool, temperature: Double) async throws -> String {
        var last = "no groq model"
        for model in try await groqCache.list(key: groqKey).prefix(3) {
            var messages: [[String: String]] = []
            if json { messages.append(["role": "system", "content": "Answer with valid JSON only, no markdown fences, no commentary."]) }
            messages.append(["role": "user", "content": prompt])
            let body: [String: Any] = ["model": model, "temperature": temperature, "messages": messages]
            guard let url = URL(string: "https://api.groq.com/openai/v1/chat/completions") else { break }
            let (code, data) = try await post(url, body, headers: ["Authorization": "Bearer \(groqKey)"])
            if (200..<300).contains(code) {
                blocked.lower()
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let message = ((object?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String ?? ""
                let out = message.trimmingCharacters(in: .whitespacesAndNewlines)
                if !out.isEmpty { return json ? stripFences(out) : out }
                last = "empty answer"
            } else {
                last = "groq \(code) \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")"
                if code == 403 {
                    blocked.set()
                    throw AiError.regionBlocked
                }
                if ![404, 429, 500, 503].contains(code) { throw AiError.http(last) }
            }
        }
        throw AiError.http(last)
    }

    /// Модели Groq — раз в 6 часов; крупные выше: они лучше знают фильмы.
    private actor GroqModels {
        private var models: [String] = []
        private var at = Date.distantPast

        func list(key: String) async throws -> [String] {
            if !models.isEmpty && Date().timeIntervalSince(at) < 6 * 3600 { return models }
            guard let url = URL(string: "https://api.groq.com/openai/v1/models") else { return [] }
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 403 { AI.blocked.set() }
            guard (200..<300).contains(code) else { throw AiError.http("groq models \(code)") }
            let rows = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]] ?? []
            let skip = Rx("(?i)whisper|guard|tts|orpheus|distil|compound|vision|prompt")
            let ids = rows.compactMap { $0["id"] as? String }.filter { !skip.matches($0) }
            let ranks = ["gpt-oss-120b", "kimi", "llama.*(70b|maverick)", "qwen.*(235b|32b)", "gpt-oss", "llama", "qwen"].map { Rx("(?i)" + $0) }
            func rank(_ id: String) -> Int { ranks.firstIndex { $0.matches(id) } ?? 100 }
            models = ids.sorted { rank($0) < rank($1) }
            at = .now
            return models
        }
    }

    /// JSON из ответа модели — без обёртки ```json … ```.
    static func stripFences(_ text: String) -> String {
        if let groups = Rx("(?i)```(?:json)?\\s*([\\s\\S]*?)```").groups(text) { return groups[1].trimmingCharacters(in: .whitespacesAndNewlines) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseJSON(_ text: String) -> Any? {
        let clean = stripFences(text)
        if let value = try? JSONSerialization.jsonObject(with: Data(clean.utf8), options: [.fragmentsAllowed]) { return value }
        // Массив внутри текста.
        if let start = clean.firstIndex(of: "["), let end = clean.lastIndex(of: "]"), start < end {
            return try? JSONSerialization.jsonObject(with: Data(clean[start...end].utf8))
        }
        return nil
    }

    /// Список названий из ответа модели (массив или объект с `items`); мусор отбрасывается.
    static func titles(_ text: String, withWhy: Bool = false) -> [AiTitle] {
        let parsed = parseJSON(text)
        let rows = parsed as? [[String: Any]] ?? (parsed as? [String: Any])?["items"] as? [[String: Any]] ?? []
        return titles(rows, withWhy: withWhy)
    }

    static func titles(_ rows: [[String: Any]], withWhy: Bool = false) -> [AiTitle] {
        rows.compactMap { row -> AiTitle? in
            let title = (row["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let original = (row["original"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let name = title.isEmpty ? original : title
            guard !name.isEmpty else { return nil }
            let year = (row["year"] as? NSNumber)?.intValue ?? Int(row["year"] as? String ?? "") ?? 0
            return AiTitle(title: String(name.prefix(150)), original: String((original.isEmpty ? name : original).prefix(150)), year: year,
                           tv: row["type"] as? String == "tv", why: withWhy ? String((row["why"] as? String ?? "").prefix(100)) : "")
        }.prefix(30).map { $0 }
    }

    /// По абзацам; слишком длинный абзац — по границам слов.
    static func split(_ text: String, limit: Int) -> [String] {
        var pieces: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
            var rest = paragraph
            while rest.count > limit {
                let head = String(rest.prefix(limit))
                let cut = head.lastIndex(of: " ").map { head.distance(from: head.startIndex, to: $0) }.flatMap { $0 > limit / 2 ? $0 : nil } ?? limit
                pieces.append(String(rest.prefix(cut)))
                rest = String(rest.dropFirst(cut)).trimmingCharacters(in: .whitespaces)
            }
            pieces.append(rest)
        }
        var chunks: [String] = []
        var current = ""
        for piece in pieces {
            if !current.isEmpty && current.count + piece.count + 1 > limit {
                chunks.append(current)
                current = ""
            }
            current += current.isEmpty ? piece : "\n" + piece
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
