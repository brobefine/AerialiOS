import Foundation
import Testing
@testable import Aerial

/// «Духовные родственники» без спойлеров: ни при каком ответе модели развязка не попадает на экран.
struct SpoilerGuardTests {
    private func pick(_ title: String, _ why: String) -> AiTitle {
        AiTitle(title: title, original: title, year: 2000, tv: false, why: why)
    }

    /// Случай 24 октября: «Реинкарнация» → «Ключ от всех дверей». Проверка назвала строку спойлером — текст скрыт.
    @Test func verdictHidesHereditaryTwist() {
        let picks = [pick("Ключ от всех дверей", "переселение душ через ритуалы черной магии в чужие тела"),
                     pick("Бабадук", "мать и сын в доме, где горе становится чудовищем")]
        let safe = SpoilerGuard.apply(picks, verdict: [0])
        #expect(safe[0].why.isEmpty)
        #expect(safe[1].why == picks[1].why)
    }

    /// Та же строка, даже если проверка её пропустила: признак «переселение» — скрыта всё равно.
    @Test func markersCatchWhatCheckMissed() {
        let picks = [pick("Ключ от всех дверей", "переселение душ через ритуалы черной магии в чужие тела")]
        #expect(SpoilerGuard.apply(picks, verdict: []).first?.why.isEmpty == true)
    }

    /// Проверка не ответила или ответила мусором — не показывается ни одно «чем связан».
    @Test func failedCheckHidesEverything() {
        let picks = [pick("Бабадук", "мать и сын в доме, где горе становится чудовищем"), pick("Сияние", "семья в отрезанном от мира отеле")]
        #expect(SpoilerGuard.apply(picks, verdict: nil).allSatisfy { $0.why.isEmpty })
        #expect(SpoilerGuard.parseVerdict("не JSON") == nil)
        #expect(SpoilerGuard.parseVerdict("{\"other\": [1]}") == nil)
    }

    @Test func verdictParsing() {
        #expect(SpoilerGuard.parseVerdict("{\"spoilers\": [0, 3]}") == [0, 3])
        #expect(SpoilerGuard.parseVerdict("{\"spoilers\": []}") == [])
        #expect(SpoilerGuard.parseVerdict("{\"spoilers\": [\"2\"]}") == [2])
    }

    /// Типичные формулировки развязок — все пойманы признаками.
    @Test(arguments: [
        "в финале выясняется, что герой мертв",
        "оказывается, это всё ему приснилось",
        "на самом деле девочка одержима демоном",
        "главный твист — подмена личности",
        "концовка с неожиданным поворотом",
        "the twist is that he was dead all along",
        "призрак вселяется в тело дочери",
    ])
    func spoilerPhrasesAreCaught(_ phrase: String) {
        #expect(SpoilerGuard.hasMarkers(phrase))
    }

    /// Безопасные описания завязки не трогаются.
    @Test(arguments: [
        "семья переживает утрату бабушки",
        "одинокий смотритель маяка и нарастающая тревога",
        "подростки в маленьком городе и странные исчезновения",
    ])
    func premisePhrasesStay(_ phrase: String) {
        #expect(!SpoilerGuard.hasMarkers(phrase))
        #expect(SpoilerGuard.apply([pick("X", phrase)], verdict: []).first?.why == phrase)
    }

    /// Запрос «родственников» и проверки несут правила про спойлеры обеих работ.
    @Test func promptsCarryRules() {
        #expect(SpoilerGuard.rules.contains("SPOILER-FREE for BOTH works"))
        let check = SpoilerGuard.checkPrompt(seed: "Hereditary (2018)", items: [("The Skeleton Key", "переселение душ")])
        #expect(check.contains("Hereditary (2018)"))
        #expect(check.contains("0: \"The Skeleton Key\" — переселение душ"))
        #expect(check.contains("When in doubt, mark it"))
    }
}
