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
    /// «Вышли в 4K»: недавние домашние релизы, у которых парсер нашёл раздачу 4K того же года.
    private(set) var fourK: [VodItem] = {
        guard let data = UserDefaults.standard.data(forKey: "feeds.fourK") else { return [] }
        return (try? JSONDecoder().decode([VodItem].self, from: data)) ?? []
    }()

    @ObservationIgnored private var fourKJob: Task<Void, Never>?

    /// Перенос `refreshFourK` ТВ: популярные фильмы, вышедшие в онлайн или на диске за 4 месяца (TMDb), и для каждого —
    /// поиск раздачи 4K с тем же годом. По одному запросу с паузой (парсер ограничивает частоту). Раз в 6 часов.
    func refreshFourK(_ settings: AppSettings) {
        let defaults = UserDefaults.standard
        guard !settings.parserAddress.isEmpty, fourKJob == nil else { return }
        if Date().timeIntervalSince1970 - defaults.double(forKey: "feeds.fourKAt") < 6 * 3600 && !fourK.isEmpty { return }
        let parser = ReleaseSearch.Parser(address: settings.parserAddress, key: settings.parserKey, torrentio: false)
        fourKJob = Task { [weak self] in
            defer { self?.fourKJob = nil }
            let candidates = await Catalogue.shared.recentHomeReleases().prefix(45)
            var films: [VodItem] = []
            for film in candidates {
                if films.count >= 24 || Task.isCancelled { break }
                if await Self.hasFourK(film, parser: parser) {
                    films.append(film)
                    if films.count >= 3 { self?.fourK = films }
                }
                try? await Task.sleep(for: .milliseconds(1200))
            }
            guard !films.isEmpty else { return }
            self?.fourK = films
            if let data = try? JSONEncoder().encode(films) { defaults.set(data, forKey: "feeds.fourK") }
            defaults.set(Date().timeIntervalSince1970, forKey: "feeds.fourKAt")
            Log.note("4K", "найдено \(films.count) из \(candidates.count)")
        }
    }

    /// Раздача 4K с годом фильма и его названием в заголовке.
    private nonisolated static func hasFourK(_ film: VodItem, parser: ReleaseSearch.Parser) async -> Bool {
        let found = await ReleaseSearch.search(item: film, episode: nil, imdbId: nil, parser: parser)
        let names = Set([film.originalTitle, film.title].map(SearchText.normalized).filter { $0.count > 1 })
        return found.contains { release in
            guard release.title.contains(film.year), release.info.quality == "4K" else { return false }
            let title = SearchText.normalized(release.title)
            return names.contains { title.contains($0) }
        }
    }

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
