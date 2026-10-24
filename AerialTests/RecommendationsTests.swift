import Foundation
import Testing
@testable import Aerial

/// Подбор «Вам понравится?» — те же правила, что у `VodRecommendations` ТВ.
struct RecommendationsTests {
    private func film(_ id: Int, _ genres: [String], rating: Double = 7.5, votes: Int = 5000, kind: VodKind = .movie) -> VodItem {
        VodItem(id: "tmdb:\(kind.rawValue):\(id)", remoteId: id, kind: kind, title: "Фильм \(id)", genres: genres,
                rating: rating, votes: votes)
    }

    @Test func javaHash() {
        // Как `"hello".hashCode()` в Java: порядок «на сегодня» тот же между запусками.
        #expect(Recommendations.javaHash("hello") == 99_162_322)
        #expect(Recommendations.dailyOrder("tmdb:movie:1", day: 20_000) == Recommendations.dailyOrder("tmdb:movie:1", day: 20_000))
        #expect(Recommendations.dailyOrder("tmdb:movie:1", day: 20_000) != Recommendations.dailyOrder("tmdb:movie:1", day: 20_001))
    }

    @Test func genres() {
        #expect(Recommendations.genres(film(1, ["НФ и Фэнтези", "Драма"])) == ["фантастика", "фэнтези", "драма"])
        #expect(Recommendations.genres(film(2, ["Drama", "драма"])) == ["драма"])
    }

    @Test func quality() {
        #expect(Recommendations.quality(film(1, [], rating: 8.5, votes: 20_000)) == 1)
        #expect(Recommendations.quality(film(2, [], rating: 0, votes: 0)) == 0.5)
        // 8,5 от четырёх голосов — почти средняя.
        #expect(Recommendations.trustedRating(film(3, [], rating: 8.5, votes: 4)) < 6.7)
    }

    @Test func neighboursOfLikedComeFirst() {
        let seed = film(1, ["Драма"])
        let neighbour = film(2, ["Комедия"], rating: 7)
        let sameGenre = film(3, ["Драма"], rating: 7)
        let stranger = film(4, ["Ужасы"], rating: 7)
        let rejected = film(5, ["Драма"])
        var signals = TasteSignals(liked: [seed.id], related: [seed.id: [neighbour]])
        signals.rejected = [rejected.id]
        let ranked = Recommendations.rank([seed, sameGenre, stranger, rejected], signals)
        #expect(ranked.first?.id == neighbour.id)
        #expect(ranked.contains { $0.id == sameGenre.id })
        #expect(!ranked.contains { $0.id == seed.id || $0.id == rejected.id })
        #expect(!ranked.contains { $0.id == stranger.id })
    }

    @Test func shelfOnlyGetsItsKind() {
        let seed = film(1, ["Драма"])
        let series = film(2, ["Драма"], kind: .series)
        let movie = film(3, ["Драма"])
        let ranked = Recommendations.rank([seed, series, movie], TasteSignals(loved: [seed.id]), accept: VodShelf.series.accepts)
        #expect(ranked.map(\.id) == [series.id])
    }

    @Test func nothingWithoutTaste() {
        #expect(Recommendations.rank([film(1, ["Драма"])], TasteSignals()).isEmpty)
    }

    @Test func pickSeeds() {
        let ids = (0..<30).map { "tmdb:movie:\($0)" }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let picked = Recommendations.pickSeeds(ids, limit: 20, now: now)
        #expect(picked.count == 20)
        #expect(Array(picked.prefix(16)) == Array(ids.prefix(16)))
        #expect(Recommendations.pickSeeds(ids, limit: 20, now: now) == picked)
    }

    @Test func watchWeight() {
        let item = film(1, [])
        let now = Date()
        let finished = WatchEntry(key: item.id, item: item, position: 5000, duration: 6000, updated: now)
        #expect(Recommendations.watchWeight(finished, now: now) == Recommendations.finishedWeight)
        let abandoned = WatchEntry(key: item.id, item: item, position: 300, duration: 6000, updated: now.addingTimeInterval(-3 * 86400))
        #expect(Recommendations.watchWeight(abandoned, now: now) < 0)
    }
}
