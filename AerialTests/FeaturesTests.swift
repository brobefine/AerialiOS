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
