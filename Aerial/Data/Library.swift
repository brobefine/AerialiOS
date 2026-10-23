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
        return minutes > 0 ? "Осталось \(Format.runtime(minutes: minutes))" : "Почти досмотрено"
    }
}

/// Медиатека: «Мой список», прогресс просмотра и последняя серия сериала. Хранение — UserDefaults (JSON).
@MainActor @Observable
final class Library {
    private(set) var saved: [VodItem] = []
    private(set) var entries: [String: WatchEntry] = [:]

    private let defaults = UserDefaults.standard

    init() {
        let decoder = JSONDecoder()
        if let data = defaults.data(forKey: "library.saved"), let value = try? decoder.decode([VodItem].self, from: data) {
            saved = value
        }
        if let data = defaults.data(forKey: "library.entries"), let value = try? decoder.decode([String: WatchEntry].self, from: data) {
            entries = value
        }
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
        persist(saved, "library.saved")
    }

    // MARK: Прогресс

    func entry(_ item: VodItem, _ episode: VodEpisode? = nil) -> WatchEntry? { entries[Self.key(item, episode)] }

    /// Последний просмотр сериала (любая серия) или фильма.
    func latest(for item: VodItem) -> WatchEntry? {
        entries.values.filter { $0.item.id == item.id }.max { $0.updated < $1.updated }
    }

    /// «Продолжить»: по одной записи на фильм или сериал — самая свежая и недосмотренная.
    var continueWatching: [WatchEntry] {
        var latest: [String: WatchEntry] = [:]
        for entry in entries.values where (latest[entry.item.id]?.updated ?? .distantPast) < entry.updated {
            latest[entry.item.id] = entry
        }
        return latest.values.filter(\.resumable).sorted { $0.updated > $1.updated }
    }

    func record(item: VodItem, episode: VodEpisode?, position: Double, duration: Double, source: WatchSource?) {
        guard position.isFinite, duration.isFinite else { return }
        let key = Self.key(item, episode)
        entries[key] = WatchEntry(key: key, item: item, episode: episode, position: position, duration: duration,
                                  updated: .now, source: source ?? entries[key]?.source)
        persist(entries, "library.entries")
    }

    func forget(_ entry: WatchEntry) {
        entries[entry.key] = nil
        persist(entries, "library.entries")
    }

    private func persist<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
