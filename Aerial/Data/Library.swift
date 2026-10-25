import Foundation
import Observation

/// Откуда играли: раздача и файл в ней — «Продолжить» запускает их сразу, без нового поиска.
struct WatchSource: Codable, Hashable, Sendable {
    var link: String
    var hash: String
    var fileIndex: Int
    var fileName: String
    var releaseTitle: String
}

/// Просмотр фильма или серии: позиция, длительность и раздача.
struct WatchEntry: Codable, Hashable, Identifiable, Sendable {
    var key: String
    var item: VodItem
    var episode: VodEpisode?
    var position: Double
    var duration: Double
    var updated: Date
    var source: WatchSource?

    var id: String { key }
    var fraction: Double { duration > 0 ? min(1, max(0, position / duration)) : 0 }
    /// Как `VodProgress.resumable` ТВ: просмотрено хотя бы 5 с и не досмотрено (до конца больше 10 с и меньше 95 %).
    var resumable: Bool { position >= 5 && (duration <= 0 || position < duration - 10 && fraction < 0.95) }
    var remaining: String {
        guard duration > 0 else { return "" }
        let minutes = Int((duration - position) / 60)
        return minutes > 0 ? L("Осталось %@", Format.runtime(minutes: minutes)) : L("Почти досмотрено")
    }
}

/// Оценка фильма, как `VodState.rate` ТВ: −1 «Не моё», 1 «Нравится», 2 «Обожаю». Карточка хранится вместе с оценкой —
/// подбору нужны её жанры; дата — свежие отметки идут в ограниченный подбор первыми ([Recommendations.pickSeeds]).
struct TasteMark: Codable, Hashable, Sendable {
    var item: VodItem
    var level: Int
    var marked: Date
}

/// Медиатека: «Мой список», оценки, прогресс просмотра и последняя серия сериала. Хранение — UserDefaults (JSON).
@MainActor @Observable
final class Library {
    private(set) var saved: [VodItem] = []
    private(set) var entries: [String: WatchEntry] = [:]
    private(set) var marks: [String: TasteMark] = [:]
    /// Подписки на актёров и режиссёров: их новые работы — рядом на главной.
    private(set) var followed: [VodPerson] = []
    /// Растёт, когда меняется то, из чего считается подбор: список, оценки, новый или досмотренный просмотр.
    /// Ход позиции во время фильма его не трогает — главная не пересчитывает ряды каждые 5 с.
    private(set) var tasteRevision = 0

    private let defaults = UserDefaults.standard

    init() {
        reload()
    }

    /// Перечитать медиатеку из UserDefaults (после восстановления копии).
    func reload() {
        let decoder = JSONDecoder()
        if let data = defaults.data(forKey: "library.saved"), let value = try? decoder.decode([VodItem].self, from: data) {
            saved = value
        }
        if let data = defaults.data(forKey: "library.entries"), let value = try? decoder.decode([String: WatchEntry].self, from: data) {
            entries = value
        }
        if let data = defaults.data(forKey: "library.marks"), let value = try? decoder.decode([String: TasteMark].self, from: data) {
            marks = value
        }
        if let data = defaults.data(forKey: "library.followed"), let value = try? decoder.decode([VodPerson].self, from: data) {
            followed = value
        }
        tasteRevision += 1
    }

    static func key(_ item: VodItem, _ episode: VodEpisode?) -> String {
        episode.map { "\(item.id):\($0.season):\($0.number)" } ?? item.id
    }

    // MARK: Мой список

    func isSaved(_ item: VodItem) -> Bool { saved.contains { $0.id == item.id } }

    func toggleSaved(_ item: VodItem) {
        if let index = saved.firstIndex(where: { $0.id == item.id }) {
            saved.remove(at: index)
        } else {
            saved.insert(item, at: 0)
        }
        tasteRevision += 1
        persist(saved, "library.saved")
    }

    // MARK: Оценки

    /// −1 «Не моё», 0 — без оценки, 1 «Нравится», 2 «Обожаю».
    func rating(_ item: VodItem) -> Int { marks[item.id]?.level ?? 0 }

    func rate(_ item: VodItem, _ level: Int) {
        Log.note("ДЕЙСТВИЕ", "оценка \(item.id) = \(level)")
        marks[item.id] = level == 0 ? nil : TasteMark(item: item, level: level, marked: .now)
        tasteRevision += 1
        persist(marks, "library.marks")
    }

    func clearMarks() {
        marks = [:]
        tasteRevision += 1
        persist(marks, "library.marks")
    }

    var liked: Set<String> { Set(marks.values.filter { $0.level >= 1 }.map(\.item.id)) }
    var loved: Set<String> { Set(marks.values.filter { $0.level == 2 }.map(\.item.id)) }
    var rejected: Set<String> { Set(marks.values.filter { $0.level == -1 }.map(\.item.id)) }
    /// «Нравится» и «Обожаю» — свежие первыми (раздел медиатеки).
    var likedItems: [VodItem] { marks.values.filter { $0.level >= 1 }.sorted { $0.marked > $1.marked }.map(\.item) }

    /// Прогресс по фильму или сериалу целиком (последний просмотр) — сигнал вкуса для подбора.
    var progressByItem: [String: WatchEntry] {
        var latest: [String: WatchEntry] = [:]
        for entry in entries.values where (latest[entry.item.id]?.updated ?? .distantPast) < entry.updated {
            latest[entry.item.id] = entry
        }
        return latest
    }

    // MARK: Подписки

    func isFollowed(_ person: VodPerson) -> Bool { followed.contains { $0.id == person.id } }

    func toggleFollow(_ person: VodPerson) {
        if let index = followed.firstIndex(where: { $0.id == person.id }) {
            followed.remove(at: index)
        } else {
            followed.insert(person, at: 0)
        }
        Log.note("ДЕЙСТВИЕ", "подписка на \(person.name): \(isFollowed(person))")
        persist(followed, "library.followed")
    }

    // MARK: Прогресс

    func entry(_ item: VodItem, _ episode: VodEpisode? = nil) -> WatchEntry? { entries[Self.key(item, episode)] }

    /// Последний просмотр сериала (любая серия) или фильма.
    func latest(for item: VodItem) -> WatchEntry? {
        entries.values.filter { $0.item.id == item.id }.max { $0.updated < $1.updated }
    }

    /// «Продолжить»: по одной записи на фильм или сериал — самая свежая и недосмотренная.
    var continueWatching: [WatchEntry] {
        progressByItem.values.filter(\.resumable).sorted { $0.updated > $1.updated }
    }

    func record(item: VodItem, episode: VodEpisode?, position: Double, duration: Double, source: WatchSource?) {
        guard position.isFinite, duration.isFinite else { return }
        let key = Self.key(item, episode)
        let old = entries[key]
        let entry = WatchEntry(key: key, item: item, episode: episode, position: position, duration: duration,
                               updated: .now, source: source ?? old?.source)
        entries[key] = entry
        if old == nil || ((old?.fraction ?? 0) >= 0.7) != (entry.fraction >= 0.7) { tasteRevision += 1 }
        persist(entries, "library.entries")
    }

    /// «Очистить «Продолжить»»: недосмотренное уходит из ряда, досмотренное остаётся в истории.
    func clearContinue() {
        entries = entries.filter { !$0.value.resumable }
        tasteRevision += 1
        persist(entries, "library.entries")
    }

    /// «Очистить историю просмотра»: весь прогресс; оценки и «Мой список» остаются.
    func clearHistory() {
        entries = [:]
        tasteRevision += 1
        persist(entries, "library.entries")
    }

    func forget(_ entry: WatchEntry) {
        entries[entry.key] = nil
        tasteRevision += 1
        persist(entries, "library.entries")
    }

    private func persist<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
