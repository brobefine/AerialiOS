import Foundation
import Testing
@testable import Aerial

/// Подсказки поиска, оценки MDBList, имена файлов загрузок — на примерах ТВ.
struct SuggestionsTests {
    private let titles = ["Дюна", "Дюна: Часть вторая", "Интерстеллар", "Начало"].map { Suggestions.Title(title: $0) }

    @Test func prefixFirst() {
        #expect(Suggestions.rank("дюн", titles: titles, recent: []).first == "Дюна")
    }

    @Test func wrongKeyboard() {
        #expect(Suggestions.repairKeyboard("l.yf") == "дюна")
        #expect(Suggestions.rank("l.yf", titles: titles, recent: []).first == "Дюна")
    }

    @Test func typo() {
        #expect(Suggestions.oneTypo("интерстелдар", "интерстеллар"))
        #expect(Suggestions.rank("Интерстелдар", titles: titles, recent: []).contains("Интерстеллар"))
    }

    @Test func recentWithoutQuery() {
        #expect(Suggestions.rank("", titles: titles, recent: ["Начало"]).first == "Начало")
    }
}

struct MdbListTests {
    @Test func format() {
        let text = MdbList.format(["imdb": 8.1, "tomatoes": 92, "metacritic": 74, "letterboxd": 9])
        #expect(text == "IMDb 8.1 · 🍅 92% · Metacritic 74")
    }
}

struct DownloadsTests {
    @Test func safeNames() {
        #expect(Downloads.safe("Дюна: Часть вторая (2024)") == "Дюна  Часть вторая (2024)")
        #expect(Downloads.safe("Конец...") == "Конец")
        #expect(Downloads.safe("") == "video")
    }
}

struct AITests {
    @Test func titlesFromFencedJSON() {
        let text = "```json\n[{\"title\": \"Начало\", \"original\": \"Inception\", \"year\": 2010, \"type\": \"movie\"}, {\"title\": \"\"}]\n```"
        let titles = AI.titles(text)
        #expect(titles.count == 1)
        #expect(titles.first?.original == "Inception")
        #expect(titles.first?.year == 2010)
        #expect(titles.first?.tv == false)
    }

    @Test func titlesFromObjectWithWhy() {
        let text = "{\"themes\": [\"память\"], \"items\": [{\"title\": \"Помни\", \"original\": \"Memento\", \"year\": \"2000\", \"type\": \"movie\", \"why\": \"память\"}]}"
        let titles = AI.titles(text, withWhy: true)
        #expect(titles.first?.why == "память")
        #expect(titles.first?.year == 2000)
    }

    @Test func splitLongText() {
        let text = String(repeating: "слово ", count: 2000)
        let parts = AI.split(text, limit: 4000)
        #expect(parts.count >= 3)
        #expect(parts.allSatisfy { $0.count <= 4000 })
    }

    @Test func translationNeeded() {
        #expect(AI.needsTranslation("A great movie with a clever plot"))
        #expect(!AI.needsTranslation("Отличный фильм с хитрым сюжетом"))
    }
}

struct WikiTests {
    @Test func serviceBlocksRemoved() {
        let html = "<div class=\"ambox\"><div>плашка</div></div><p>История <b>съёмок</b>&nbsp;фильма&#160;началась.</p><sup>[1]</sup>"
        #expect(WikiPolicy.plainText(html) == "История съёмок фильма началась.")
    }

    @Test func sections() {
        #expect(WikiPolicy.storyPriority("Съёмки") == 1)
        #expect(WikiPolicy.plotPriority("<span>Plot</span>") == 0)
        #expect(WikiPolicy.plotPriority("Критика") == nil)
    }
}

struct PartyTests {
    @Test func mediaFromRoom() {
        let hash = String(repeating: "ab", count: 20)
        let media = PartyMedia.from(["hash": hash.uppercased(), "file": 3, "title": "Сериал", "series": "1399", "season": 2, "episode": 5])
        #expect(media?.hash == hash)
        #expect(media?.file == 3)
        #expect(PartyMedia.from(["hash": "nothex", "file": 1]) == nil)
    }

    @Test func stateTarget() {
        let state = PartyState(playing: true, position: 100, buffering: 0, members: [], receivedAt: 10)
        #expect(state.target(now: 15) == 105)
        let waiting = PartyState(playing: true, position: 100, buffering: 1, members: [], receivedAt: 10)
        #expect(waiting.target(now: 15) == 100)
    }
}
