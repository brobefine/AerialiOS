import Foundation
import Observation

/// Что известно о вкусе: отметки, «Мой список», просмотры и соседи TMDb. Ключи — `VodItem.id`.
struct TasteSignals: Sendable {
    var saved: Set<String> = []
    /// Последний просмотр по фильму или сериалу ([Library.progressByItem]).
    var progress: [String: WatchEntry] = [:]
    var rejected: Set<String> = []
    var liked: Set<String> = []
    var loved: Set<String> = []
    /// Соседи по TMDb: id работы → её рекомендации по порядку.
    var related: [String: [VodItem]] = [:]
    var now: Date = .now
    /// Настройка «Учитывать историю просмотра»: выключено — просмотренное не предлагается, но и вкус по нему не считается.
    var useHistory = true
}

/// Ряд «Вам понравится?» — перенос `VodRecommendations` ТВ (там же подробная история весов и проверок на данных TMDb).
///
/// - **Похожесть от TMDb** (`/recommendations`) — главный сигнал: соседи понравившегося поднимаются, отвергнутого — опускаются.
/// - **Жанр** — мягкий сигнал: отказы ослабляют жанр, но не обнуляют, пока в нём есть что-то понравившееся.
/// - **Неявные сигналы**: досмотрел (≥70 %) — плюс, бросил в начале — слабый минус; просмотры со временем забываются.
/// - **Разнообразие** — один жанр подряд штрафуется; **исследование** — каждое восьмое место вне привычного.
/// - **Качество** — слабая поправка на оценку TMDb с учётом числа голосов.
enum Recommendations {
    // Веса отметок. Явные сильнее неявных; отказ — отрицательный.
    static let lovedWeight = 15.0
    static let likedWeight = 5.0
    static let savedWeight = 3.0
    static let finishedWeight = 4.0
    static let watchedWeight = 2.0
    static let abandonedWeight = -1.5
    static let rejectedWeight = -4.0

    /// Просмотр забывается вдвое за этот срок. Явные отметки не стареют.
    static let halfLife: TimeInterval = 75 * 24 * 3600
    /// Доля отрицательного веса, которая доходит до жанра. Остальное — только соседям по TMDb.
    private static let genrePenalty = 0.25
    /// Ниже этой доли положительного веса жанр не опускается, сколько бы отказов ни было.
    private static let genreFloor = 0.3
    private static let genreShare = 0.8
    private static let diversity = 0.15
    /// Каждое восьмое место — вне привычного: за краем первого экрана ряда.
    private static let exploreEvery = 8
    private static let priorRating = 6.5
    private static let priorVotes = 150.0

    private struct Scored {
        var item: VodItem
        var score: Double
        var genre: Double
        var main: String?
        var rating: Double
        var disliked: Bool
    }

    /// Ряд для раздела: вкус считается по всем отметкам, а места делят только работы, которые принимает [accept].
    static func rank(_ items: [VodItem], _ signals: TasteSignals, limit: Int = 40,
                     accept: (VodItem) -> Bool = { _ in true }) -> [VodItem] {
        var byId: [String: VodItem] = [:]
        for item in items + signals.related.values.flatMap({ $0 }) where byId[item.id] == nil { byId[item.id] = item }
        let seeds = seedWeights(signals)
        guard seeds.values.contains(where: { $0 > 0 }) else { return [] }

        // Жанры: плюсы и минусы отдельно, затем минус с ограничением снизу.
        var positive: [String: Double] = [:]
        var negative: [String: Double] = [:]
        for (id, weight) in seeds {
            guard let item = byId[id] else { continue }
            for genre in genres(item) {
                if weight > 0 { positive[genre, default: 0] += weight } else { negative[genre, default: 0] -= weight }
            }
        }
        var genreWeight: [String: Double] = [:]
        for genre in Set(positive.keys).union(negative.keys) {
            let plus = positive[genre] ?? 0
            let net = plus - genrePenalty * (negative[genre] ?? 0)
            genreWeight[genre] = plus > 0 ? max(net, genreFloor * plus) : net
        }
        let topGenre = genreWeight.values.max().flatMap { $0 > 0 ? $0 : nil } ?? 1

        // Соседи по TMDb: чем выше в списке соседа, тем больше вклад.
        var collab: [String: Double] = [:]
        for (id, weight) in seeds {
            for (index, neighbour) in (signals.related[id] ?? []).enumerated() {
                collab[neighbour.id, default: 0] += weight / (1 + 0.15 * Double(index))
            }
        }
        let topCollab = collab.values.filter { $0 > 0 }.max() ?? 1

        let known = Set(seeds.keys).union(signals.saved).union(signals.liked).union(signals.loved).union(signals.rejected)
        let scored = byId.values.filter { item in
            !known.contains(item.id) && (signals.progress[item.id]?.position ?? 0) < 5 && accept(item)
        }.map { item -> Scored in
            let itemGenres = genres(item)
            // Сумма по жанрам — к корню их числа: работа с пятью жанрами не обгоняет точное попадание.
            let genre = itemGenres.reduce(0) { $0 + (genreWeight[$1] ?? 0) } / topGenre / Double(max(1, itemGenres.count)).squareRoot()
            let similar = (collab[item.id] ?? 0) / topCollab
            return Scored(item: item, score: (similar + genreShare * genre) * quality(item), genre: genre, main: itemGenres.first,
                          rating: trustedRating(item), disliked: itemGenres.contains { (genreWeight[$0] ?? 0) < 0 })
        }
        let sorted = scored.filter { $0.score > 0 }.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.rating != b.rating { return a.rating > b.rating }
            return a.item.id < b.item.id
        }
        let ranked = diversify(sorted, limit: limit)
        return explore(ranked, all: scored, now: signals.now, limit: limit, profile: Int64(javaHash(Set(seeds.keys).sorted())))
    }

    /// Какие из отмеченных работ отдать в ограниченный подбор. [ranked] — по важности; первые `limit − limit/5` — как есть,
    /// остальные места — давним по очереди, выбор меняется раз в сутки.
    static func pickSeeds(_ ranked: [String], limit: Int, now: Date) -> [String] {
        var seen = Set<String>()
        let all = ranked.filter { seen.insert($0).inserted }
        guard all.count > limit else { return all }
        let head = Array(all.prefix(limit - limit / 5))
        let day = Int64(now.timeIntervalSince1970 / 86400)
        let rest = all.dropFirst(head.count).sorted { dailyOrder($0, day: day) < dailyOrder($1, day: day) }
        return head + rest.prefix(limit - head.count)
    }

    /// Вес каждого «семени» — работы, по которой что-то известно о вкусе.
    static func seedWeights(_ signals: TasteSignals) -> [String: Double] {
        let progress = signals.useHistory ? signals.progress : [:]
        var out: [String: Double] = [:]
        let ids = signals.saved.union(signals.liked).union(signals.loved).union(signals.rejected).union(progress.keys)
        for id in ids {
            let watched = progress[id].map { watchWeight($0, now: signals.now) } ?? 0
            let weight: Double = if signals.rejected.contains(id) {
                rejectedWeight
            } else if signals.loved.contains(id) {
                lovedWeight + max(watched, 0)
            } else if signals.liked.contains(id) {
                likedWeight + max(watched, 0)
            } else if signals.saved.contains(id) {
                savedWeight + max(watched, 0)
            } else {
                watched
            }
            if weight != 0 { out[id] = weight }
        }
        return out
    }

    /// Неявный сигнал просмотра с забыванием.
    static func watchWeight(_ entry: WatchEntry, now: Date) -> Double {
        guard entry.position >= 5 else { return 0 }
        let known = entry.duration > 0
        let age = max(0, now.timeIntervalSince(entry.updated))
        let base: Double
        if known && entry.fraction >= 0.7 {
            base = finishedWeight
        } else if known && entry.fraction < 0.2 && entry.position < 15 * 60 && age > 86400 {
            // Бросил: меньше 20 % и не больше 15 минут, и сутки не возвращался.
            base = abandonedWeight
        } else {
            base = watchedWeight
        }
        return base * pow(0.5, age / halfLife)
    }

    /// Поправка на качество: 8+ — без потерь, 7 — ×0,85, 6 — ×0,7, 5 и ниже — ×0,55; без единого голоса — ×0,5
    /// (непроверенная новинка, не середина).
    static func quality(_ item: VodItem) -> Double {
        let rating = trustedRating(item)
        if rating > 0 { return min(1, max(0.55, 0.55 + 0.15 * (rating - 5))) }
        return item.votes <= 0 ? 0.5 : 0.85
    }

    /// Байесовское среднее: мало голосов — оценка тянется к средней, много — остаётся как есть.
    static func trustedRating(_ item: VodItem) -> Double {
        guard item.rating > 0, item.votes > 0 else { return item.rating }
        return (Double(item.votes) * item.rating + priorVotes * priorRating) / (Double(item.votes) + priorVotes)
    }

    /// Жанры общими ключами: составные жанры сериалов TMDb («НФ и Фэнтези») и английские имена — к русским жанрам фильмов.
    static func genres(_ item: VodItem) -> [String] {
        var out: [String] = []
        for raw in item.genres {
            let name = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty else { continue }
            for key in genreKeys[name] ?? [name] where !out.contains(key) { out.append(key) }
        }
        return out
    }

    private static let genreKeys: [String: [String]] = [
        "action": ["боевик"], "adventure": ["приключения"], "animation": ["мультфильм"], "анимация": ["мультфильм"],
        "comedy": ["комедия"], "crime": ["криминал"], "documentary": ["документальный"], "drama": ["драма"],
        "family": ["семейный"], "fantasy": ["фэнтези"], "history": ["история"], "horror": ["ужасы"], "music": ["музыка"],
        "mystery": ["детектив"], "romance": ["мелодрама"], "science fiction": ["фантастика"], "tv movie": ["телевизионный фильм"],
        "thriller": ["триллер"], "war": ["военный"], "western": ["вестерн"],
        "action & adventure": ["боевик", "приключения"], "боевик и приключения": ["боевик", "приключения"],
        "sci-fi & fantasy": ["фантастика", "фэнтези"], "нф и фэнтези": ["фантастика", "фэнтези"],
        "war & politics": ["военный"], "война и политика": ["военный"],
        "kids": ["семейный"], "детский": ["семейный"], "soap": ["мелодрама"], "мыльная опера": ["мелодрама"],
    ]

    /// Жадный отбор: каждая уже взятая работа с тем же главным жанром снижает оценку следующей.
    private static func diversify(_ sorted: [Scored], limit: Int) -> [Scored] {
        var left = sorted
        var out: [Scored] = []
        var seen: [String: Int] = [:]
        func adjusted(_ value: Scored) -> Double {
            value.score * max(0.2, 1 - diversity * Double(value.main.flatMap { seen[$0] } ?? 0))
        }
        while !left.isEmpty && out.count < limit {
            var best = 0
            for index in left.indices.dropFirst() where adjusted(left[index]) > adjusted(left[best]) { best = index }
            let pick = left.remove(at: best)
            out.append(pick)
            if let main = pick.main { seen[main, default: 0] += 1 }
        }
        return out
    }

    /// Каждое восьмое место — работа вне привычного: высокая оценка, жанры профиля почти не совпадают, отвергнутые
    /// жанры не берутся. Выбор свой у каждого вкуса и меняется раз в сутки, а не на каждом показе.
    private static func explore(_ ranked: [Scored], all: [Scored], now: Date, limit: Int, profile: Int64) -> [VodItem] {
        guard ranked.count >= exploreEvery - 1 else { return ranked.map(\.item) }
        let taken = Set(ranked.map(\.item.id))
        let day = Int64(now.timeIntervalSince1970 / 86400) ^ profile
        var pool = all.filter { !taken.contains($0.item.id) && $0.genre <= 0.1 && $0.rating >= 7.5 && !$0.disliked }
            .sorted { dailyOrder($0.item.id, day: day) < dailyOrder($1.item.id, day: day) }
            .makeIterator()
        var out: [VodItem] = []
        for value in ranked {
            if out.count >= limit { break }
            if (out.count + 1) % exploreEvery == 0, let extra = pool.next() { out.append(extra.item) }
            if out.count < limit { out.append(value.item) }
        }
        return out
    }

    /// Порядок «на сегодня»: свой для каждого дня (перемешивание splitmix64 — как у ТВ).
    static func dailyOrder(_ id: String, day: Int64) -> Int64 {
        var z = UInt64(bitPattern: Int64(javaHash(id))) ^ (UInt64(bitPattern: day) &* 0x9E37_79B9_7F4A_7C15)
        z = (z ^ (z >> 33)) &* 0xFF51_AFD7_ED55_8CCD
        z = (z ^ (z >> 33)) &* 0xC4CE_B9FE_1A85_EC53
        return Int64(bitPattern: z ^ (z >> 33))
    }

    /// Хэш строки, как `String.hashCode` Java: одинаков между запусками (`hashValue` Swift — нет).
    static func javaHash(_ text: String) -> Int32 {
        text.utf16.reduce(Int32(0)) { $0 &* 31 &+ Int32(truncatingIfNeeded: $1) }
    }

    static func javaHash(_ list: [String]) -> Int32 {
        list.reduce(Int32(1)) { $0 &* 31 &+ javaHash($1) }
    }
}

/// Ряд «Потому что вам понравилось „X“».
struct BecauseRow: Identifiable, Sendable {
    var seed: VodItem
    var items: [VodItem]
    var id: String { seed.id }
}

/// Подбор кинотеки: соседи TMDb для «Вам понравится?» и ряды «Потому что вам понравилось…».
/// Соседи хранятся на диске (UserDefaults), чтобы первый показ главной после запуска не ждал их сбора.
@MainActor @Observable
final class Taste {
    /// Подборка ИИ по ощущению, атмосфере или механике сюжета — ряд под «Вам понравится?».
    struct AiShelf: Codable, Identifiable, Sendable {
        var title: String
        var why: String
        var items: [VodItem]
        var id: String { title }
    }

    private(set) var related: [String: [VodItem]] = [:]
    /// Подбор ИИ для «Вам понравится?» — вперемешку с подбором по жанрам и соседям.
    private(set) var aiPicks: [VodItem] = []
    private(set) var aiShelves: [AiShelf] = []
    /// Почему ИИ не ответил — для настроек.
    private(set) var aiError: String?

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var relatedKey: String
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var again = false
    @ObservationIgnored private var aiJob: Task<Void, Never>?

    init() {
        relatedKey = defaults.string(forKey: "taste.relatedKey") ?? ""
        if let data = defaults.data(forKey: "taste.related"),
           let value = try? JSONDecoder().decode([String: [VodItem]].self, from: data) {
            related = value
        }
        if let data = defaults.data(forKey: "taste.aiPicks"), let value = try? JSONDecoder().decode([VodItem].self, from: data) {
            aiPicks = value
        }
        if let data = defaults.data(forKey: "taste.aiShelves"), let value = try? JSONDecoder().decode([AiShelf].self, from: data) {
            aiShelves = value
        }
    }

    /// Сброс подбора ИИ (оценки сброшены, ИИ выключен).
    func clearAI() {
        aiPicks = []
        aiShelves = []
        defaults.removeObject(forKey: "taste.aiPicks")
        defaults.removeObject(forKey: "taste.aiShelves")
        defaults.removeObject(forKey: "taste.aiAt")
    }

    /// Подбор ИИ — перенос `refreshAiRecommendations` ТВ: по «Обожаю», «Нравится», списку и досмотренному (с завязкой
    /// сюжета в [скобках]), отказам и брошенному. Раз в 12 часов или когда меняется любимое, но не чаще раза в 20 минут.
    func refreshAI(_ library: Library, useHistory: Bool, moods: Bool) {
        guard AI.enabled, aiJob == nil else { return }
        let now = Date.now
        let known = knownItems(library)
        let loved = library.loved
        let likedIds = library.liked
        let rejected = library.rejected
        let progress = library.progressByItem
        func label(_ item: VodItem) -> String {
            (item.originalTitle.isEmpty ? item.title : item.originalTitle) + (item.year.isEmpty ? "" : " (\(item.year))")
                + (loved.contains(item.id) ? " — любимое" : "")
        }
        let liked = Recommendations.pickSeeds(tasteOrder(library, useHistory: useHistory, now: now).filter { known[$0] != nil }, limit: 25, now: now)
            .compactMap { known[$0] }
        guard liked.count >= 2 else { return }
        let disliked = library.marks.values.filter { $0.level == -1 }.sorted { $0.marked > $1.marked }.prefix(15).map(\.item)
        let finished = useHistory ? Set(progress.filter { $0.value.duration > 0 && $0.value.fraction >= 0.7 }.keys) : []
        let abandoned = useHistory ? known.values.filter { item in
            !likedIds.contains(item.id) && !rejected.contains(item.id)
                && progress[item.id].map { Recommendations.watchWeight($0, now: now) < 0 } == true
        }.sorted { (progress[$0.id]?.updated ?? .distantPast) > (progress[$1.id]?.updated ?? .distantPast) }.prefix(10).map { $0 } : []
        // Завязка сюжета к любимому: по одному названию модель путает свежий фильм с одноимённым.
        func hint(_ item: VodItem) -> String {
            var plot = item.overview.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !plot.isEmpty else { return "" }
            if plot.count > 260 { plot = String(plot.prefix(260)).components(separatedBy: " ").dropLast().joined(separator: " ") + "…" }
            let genres = item.genres.joined(separator: " / ").prefix(60)
            return " [" + (genres.isEmpty ? "" : "\(genres): ") + plot + "]"
        }
        func seed(_ item: VodItem) -> String { label(item) + (finished.contains(item.id) ? " — досмотрел" : "") + hint(item) }
        let seedKey = (liked.map { (loved.contains($0.id) ? "*" : "") + (likedIds.contains($0.id) ? "+" : "") + $0.id }
            + disliked.map { "-" + $0.id } + abandoned.map { "~" + $0.id }).sorted().joined(separator: ",")
        let age = now.timeIntervalSince(Date(timeIntervalSince1970: defaults.double(forKey: "taste.aiAt")))
        if age < 12 * 3600 && defaults.string(forKey: "taste.aiKey") == seedKey && (!moods || !aiShelves.isEmpty) { return }
        // Оценки меняют семя на каждое нажатие — ИИ не чаще раза в 20 минут.
        if age >= 0 && age < 20 * 60 && !aiPicks.isEmpty { return }
        let exclude = known.values.filter { progress[$0.id] != nil || library.isSaved($0) }.prefix(60).map(label)
        let saved = Set(library.saved.map(\.id))
        aiJob = Task { [weak self] in
            defer { self?.aiJob = nil }
            do {
                let picks = try await AI.recommend(liked: liked.map(seed), disliked: disliked.map(label), exclude: Array(exclude),
                                                   abandoned: abandoned.map(label))
                let films = await Self.resolve(picks).filter { !saved.contains($0.id) && !rejected.contains($0.id) && progress[$0.id] == nil }
                guard let self else { return }
                aiPicks = films
                aiError = nil
                if let data = try? JSONEncoder().encode(films) { defaults.set(data, forKey: "taste.aiPicks") }
                defaults.set(seedKey, forKey: "taste.aiKey")
                defaults.set(Date.now.timeIntervalSince1970, forKey: "taste.aiAt")
                Log.note("ИИ", "подбор: \(picks.count) назв. → \(films.count) в TMDb")
                guard moods else { return }
                let rows = try await AI.collections(liked: liked.map(seed), disliked: disliked.map(label), exclude: Array(exclude),
                                                    abandoned: abandoned.map(label))
                var shelves: [AiShelf] = []
                for row in rows {
                    let items = await Self.resolve(row.items).filter {
                        !saved.contains($0.id) && !likedIds.contains($0.id) && !rejected.contains($0.id) && progress[$0.id] == nil
                    }
                    if items.count >= 3 { shelves.append(AiShelf(title: row.title, why: row.why, items: items)) }
                }
                aiShelves = shelves
                if let data = try? JSONEncoder().encode(shelves) { defaults.set(data, forKey: "taste.aiShelves") }
            } catch {
                if HTTP.isCancellation(error) { return }
                self?.aiError = AI.failure(error)
                Log.note("ИИ", "подбор: \(error.localizedDescription.prefix(200))")
            }
        }
    }

    /// Названия ИИ → работы TMDb (по шесть запросов сразу), без повторов, в порядке ответа.
    static func resolve(_ titles: [AiTitle]) async -> [VodItem] {
        var found: [Int: VodItem] = [:]
        await withTaskGroup(of: (Int, VodItem?).self) { group in
            for (index, title) in titles.enumerated() {
                group.addTask { (index, await Catalogue.shared.resolve(title)) }
            }
            for await (index, item) in group { if let item { found[index] = item } }
        }
        var seen = Set<String>()
        return titles.indices.compactMap { found[$0] }.filter { seen.insert($0.id).inserted }
    }

    func signals(_ library: Library, useHistory: Bool) -> TasteSignals {
        TasteSignals(saved: Set(library.saved.map(\.id)), progress: library.progressByItem, rejected: library.rejected,
                     liked: library.liked, loved: library.loved, related: related, useHistory: useHistory)
    }

    /// Работы вкуса по важности: «Обожаю», «Нравится», затем «Мой список» и просмотренное; внутри — свежее первым.
    private func tasteOrder(_ library: Library, useHistory: Bool, now: Date) -> [String] {
        let progress = library.progressByItem
        func fresh(_ id: String) -> Date { max(library.marks[id]?.marked ?? .distantPast, progress[id]?.updated ?? .distantPast) }
        func byFresh(_ ids: Set<String>) -> [String] { ids.sorted { fresh($0) > fresh($1) } }
        let liked = library.liked
        let loved = library.loved
        // Брошенное без оценки — не вкус.
        let history = useHistory ? Set(progress.filter { $0.value.position >= 5 && Recommendations.watchWeight($0.value, now: now) >= 0 }.keys) : []
        let rejected = library.rejected
        var seen = Set<String>()
        return (byFresh(loved) + byFresh(liked.subtracting(loved)) + byFresh(Set(library.saved.map(\.id)).union(history).subtracting(liked)))
            .filter { !rejected.contains($0) && seen.insert($0).inserted }
    }

    private func knownItems(_ library: Library) -> [String: VodItem] {
        var known: [String: VodItem] = [:]
        for entry in library.entries.values { known[entry.item.id] = entry.item }
        for item in library.saved { known[item.id] = item }
        for mark in library.marks.values { known[mark.item.id] = mark.item }
        return known
    }

    /// Собрать соседей заново. Сбор не привязан к экрану (уход с главной его не обрывает); пришли новые оценки, пока
    /// идёт прежний, — после него ещё один.
    func refresh(_ library: Library, useHistory: Bool) {
        guard job == nil else {
            again = true
            return
        }
        job = Task { [weak self] in
            await self?.collect(library, useHistory: useHistory)
            guard let self else { return }
            job = nil
            if again {
                again = false
                refresh(library, useHistory: useHistory)
            }
        }
    }

    /// Соседи по TMDb: 20 работ вкуса (свежее первым, давнее по очереди) и 4 места отказам. Ответы TMDb в дисковом кэше —
    /// повторный сбор почти бесплатен.
    private func collect(_ library: Library, useHistory: Bool) async {
        let now = Date.now
        let known = knownItems(library)
        let taste = Recommendations.pickSeeds(tasteOrder(library, useHistory: useHistory, now: now).filter { known[$0] != nil },
                                              limit: 20, now: now)
        let refusals = library.rejected.filter { known[$0] != nil }
            .sorted { (library.marks[$0]?.marked ?? .distantPast) > (library.marks[$1]?.marked ?? .distantPast) }.prefix(4)
        let seeds = (taste + refusals).compactMap { known[$0] }
        let key = seeds.map(\.id).joined(separator: ",")
        guard !seeds.isEmpty, key != relatedKey else { return }
        var found: [String: [VodItem]] = [:]
        // По четыре запроса сразу.
        for chunk in stride(from: 0, to: seeds.count, by: 4).map({ Array(seeds[$0..<min($0 + 4, seeds.count)]) }) {
            await withTaskGroup(of: (String, [VodItem]).self) { group in
                for seed in chunk {
                    group.addTask { (seed.id, Array(((try? await Catalogue.shared.recommendations(seed)) ?? []).prefix(30))) }
                }
                for await (id, films) in group where !films.isEmpty { found[id] = films }
            }
        }
        // Все запросы упали (нет сети) — ключ не запоминаем и прежних соседей не стираем.
        guard !found.isEmpty else { return }
        // Соседи прошлых дней остаются, пока их работа ещё в оценках: до 60 семян.
        let still = Set(tasteOrder(library, useHistory: useHistory, now: now)).union(library.rejected)
        var merged = found
        for (id, films) in related where merged.count < 60 && merged[id] == nil && still.contains(id) { merged[id] = films }
        related = merged
        relatedKey = key
        if let data = try? JSONEncoder().encode(merged) { defaults.set(data, forKey: "taste.related") }
        defaults.set(key, forKey: "taste.relatedKey")
        Log.note("ПОДБОР", "соседи TMDb: семян=\(seeds.count) с ответом=\(found.count)")
    }

    /// «Вам понравится?» для раздела. Пока сигналы вкуса те же, показанный порядок держится: ушедшее выпадает, новое —
    /// в конец (каталог приходит порциями — иначе верх ряда менялся на глазах). Новая оценка или соседи — пересчёт.
    func forYou(_ shelf: VodShelf, pool: [VodItem], library: Library, useHistory: Bool) -> [VodItem] {
        let signals = signals(library, useHistory: useHistory)
        let byGenre = Recommendations.rank(pool, signals, limit: 60, accept: shelf.accepts)
        // Подбор ИИ — только то, чего нет в подборе по жанрам, вперемешку через один (как у ТВ).
        let taken = Set(byGenre.map(\.id))
        let fromAi = aiPicks.filter {
            shelf.accepts($0) && !taken.contains($0.id) && !signals.saved.contains($0.id) && !signals.liked.contains($0.id)
                && !signals.rejected.contains($0.id) && signals.progress[$0.id] == nil
        }
        var mixed: [VodItem] = []
        for index in 0..<max(byGenre.count, fromAi.count) {
            if index < byGenre.count { mixed.append(byGenre[index]) }
            if index < fromAi.count { mixed.append(fromAi[index]) }
        }
        let fresh = Array(mixed.prefix(60))
        let signal = String(Recommendations.javaHash([
            signals.saved.sorted(), signals.liked.sorted(), signals.loved.sorted(), signals.rejected.sorted(),
            signals.progress.keys.sorted(), related.keys.sorted(), [String(useHistory)], aiPicks.map(\.id),
        ].map { $0.joined(separator: ",") }))
        let key = "taste.forYou.\(shelf.rawValue)"
        let stored = defaults.string(forKey: key)?.split(separator: "\n", maxSplits: 1).map(String.init)
        var result = fresh
        if let stored, stored.count == 2, stored[0] == signal {
            var byId: [String: VodItem] = [:]
            for item in pool + aiPicks + related.values.flatMap({ $0 }) where byId[item.id] == nil { byId[item.id] = item }
            for item in fresh { byId[item.id] = item }
            let allowed = Set(fresh.map(\.id))
            let kept = stored[1].split(separator: ",").map(String.init).compactMap { id -> VodItem? in
                guard let item = byId[id] else { return nil }
                if allowed.contains(id) { return item }
                let gone = signals.saved.contains(id) || signals.liked.contains(id) || signals.rejected.contains(id)
                    || signals.progress[id] != nil
                return gone ? nil : item
            }
            var seen = Set<String>()
            result = Array((kept + fresh).filter { seen.insert($0.id).inserted }.prefix(max(fresh.count, kept.count)))
        }
        // Каталог ещё не пришёл — запомненный порядок пустым не затирается.
        guard !result.isEmpty else { return result }
        let value = signal + "\n" + result.map(\.id).joined(separator: ",")
        if defaults.string(forKey: key) != value { defaults.set(value, forKey: key) }
        return result
    }

    /// Ряды «Потому что вам понравилось „X“» (как «Because you watched» у Netflix): к самым свежим «Обожаю», «Нравится»
    /// и досмотренному — их соседи TMDb без уже известного.
    func because(_ library: Library, max count: Int = 2) -> [BecauseRow] {
        let known = knownItems(library)
        let progress = library.progressByItem
        let rejected = library.rejected
        let liked = library.liked
        let saved = Set(library.saved.map(\.id))
        let finished = progress.filter { $0.value.duration > 0 && $0.value.fraction >= 0.7 }.keys
        let strong = liked.union(finished).filter { !rejected.contains($0) }
        func fresh(_ id: String) -> Date { max(library.marks[id]?.marked ?? .distantPast, progress[id]?.updated ?? .distantPast) }
        var out: [BecauseRow] = []
        for id in strong.sorted(by: { fresh($0) > fresh($1) }) {
            guard out.count < count, let seed = known[id] else { continue }
            let films = (related[id] ?? []).filter {
                !saved.contains($0.id) && !liked.contains($0.id) && !rejected.contains($0.id) && (progress[$0.id]?.position ?? 0) < 5
            }
            if films.count >= 6 { out.append(BecauseRow(seed: seed, items: films)) }
        }
        return out
    }
}
