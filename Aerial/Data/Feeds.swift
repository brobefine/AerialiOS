import Foundation
import Observation

/// Следующая серия сериала, которого ещё нет: дата выхода и кадр, если TMDb его уже знает.
struct UpcomingEpisode: Identifiable, Hashable, Sendable {
    var item: VodItem
    var date: String
    var season: Int
    var number: Int
    var title: String
    var still: String

    var id: String { item.id }
    var code: String { "\(season)x\(number)" }
}

/// Личные ряды главной, как у ТВ: «Скоро новые серии» (`refreshUpcoming`) — сериалы, за которыми следишь, и
/// «Новое с вашими актёрами» (`refreshFollowedFeed`) — вышедшее за два года и анонсированное у тех, на кого подписан.
@MainActor @Observable
final class Feeds {
    private(set) var upcoming: [UpcomingEpisode] = []
    private(set) var followed: [VodItem] = []

    @ObservationIgnored private var upcomingKey = ""
    @ObservationIgnored private var upcomingAt = Date.distantPast
    @ObservationIgnored private var followedKey = ""
    @ObservationIgnored private var followedAt = Date.distantPast

    /// Сериалы из «Моего списка», оценённые и начатые (без «Не моё»), — до 40; повтор тех же — не чаще раза в 30 минут.
    func refreshUpcoming(_ library: Library) async {
        let rejected = library.rejected
        var seen = Set<String>()
        let series = (library.saved + library.marks.values.map(\.item) + library.progressByItem.values.map(\.item))
            .filter { $0.kind == .series && $0.remoteId > 0 && !rejected.contains($0.id) && seen.insert($0.id).inserted }
            .prefix(40)
        let key = series.map(\.id).sorted().joined(separator: ",")
        guard key != upcomingKey || Date().timeIntervalSince(upcomingAt) > 30 * 60 else { return }
        guard !series.isEmpty else {
            upcoming = []
            return
        }
        let today = ISO8601DateFormatter.day.string(from: .now)
        var found: [UpcomingEpisode] = []
        await withTaskGroup(of: UpcomingEpisode?.self) { group in
            for item in series {
                group.addTask { try? await Catalogue.shared.upcoming(item) }
            }
            for await episode in group {
                if let episode, episode.date >= today { found.append(episode) }
            }
        }
        guard !Task.isCancelled else { return }
        upcomingKey = key
        upcomingAt = .now
        upcoming = found.sorted { $0.date < $1.date }
    }

    /// Фильмографии до 20 подписок; свежие первыми, без «Не моё», до 30 работ. Повтор — не чаще раза в 6 часов.
    func refreshFollowed(_ library: Library) async {
        let people = Array(library.followed.prefix(20))
        let key = people.map { String($0.id) }.joined(separator: ",")
        guard key != followedKey || Date().timeIntervalSince(followedAt) > 6 * 3600 else { return }
        guard !people.isEmpty else {
            followed = []
            followedKey = key
            return
        }
        let since = String(Calendar.current.component(.year, from: .now) - 2)
        var all: [VodItem] = []
        await withTaskGroup(of: [VodItem].self) { group in
            for person in people {
                group.addTask { (try? await Catalogue.shared.person(person))?.works ?? [] }
            }
            for await works in group { all += works }
        }
        guard !Task.isCancelled else { return }
        let rejected = library.rejected
        var seen = Set<String>()
        followed = Array(all.filter { $0.year >= since && !rejected.contains($0.id) && seen.insert($0.id).inserted }
            .sorted { ($0.releaseDate.isEmpty ? $0.year : $0.releaseDate) > ($1.releaseDate.isEmpty ? $1.year : $1.releaseDate) }
            .prefix(30))
        followedKey = key
        followedAt = .now
    }
}
