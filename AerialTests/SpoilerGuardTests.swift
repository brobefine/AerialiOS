import Foundation
import Testing
@testable import Aerial

/// «Духовные родственники» без спойлеров: что бы ни ответила модель, на экране — либо безопасное описание, либо
/// нейтральная фраза; развязки нет, пустого места нет.
struct SpoilerGuardTests {
    private let hereditary = "переселение душ через ритуалы черной магии в чужие тела"
    private let safe = "мать и сын в доме, где горе становится чудовищем"

    private func pick(_ title: String, _ why: String) -> AiTitle {
        AiTitle(title: title, original: title, year: 2000, tv: false, why: why)
    }

    /// Случай 25 октября: проверка отметила, модель переписала, повторная проверка приняла — показан новый текст.
    @Test func flaggedIsRewritten() {
        let picks = [pick("Ключ от всех дверей", hereditary), pick("Бабадук", safe)]
        let result = SpoilerGuard.merge(picks, verdict: [0], rewrites: [0: "семейные тайны и старый дом с запертыми комнатами"],
                                        recheck: [])
        #expect(result[0].why == "семейные тайны и старый дом с запертыми комнатами")
        #expect(result[1].why == safe)
    }

    /// Переписанное всё ещё спойлер — нейтральная фраза, а не пустота и не спойлер.
    @Test func rewriteStillSpoilerFallsBack() {
        let picks = [pick("Ключ от всех дверей", hereditary)]
        let result = SpoilerGuard.merge(picks, verdict: [0], rewrites: [0: "души переселяются в тела"], recheck: [0])
        #expect(result[0].why == SpoilerGuard.fallback)
    }

    /// Переписать не удалось или повторной проверки не было — нейтральная фраза.
    @Test func missingRewriteOrRecheckFallsBack() {
        let picks = [pick("Ключ от всех дверей", hereditary)]
        #expect(SpoilerGuard.merge(picks, verdict: [0], rewrites: [:], recheck: []).first?.why == SpoilerGuard.fallback)
        #expect(SpoilerGuard.merge(picks, verdict: [0], rewrites: [0: "тайны дома"], recheck: nil).first?.why == SpoilerGuard.fallback)
    }

    /// Проверка не ответила — ни одной исходной фразы на экране, у всех нейтральная.
    @Test func failedCheckNeverShowsOriginals() {
        let picks = [pick("Ключ от всех дверей", hereditary), pick("Бабадук", safe)]
        #expect(SpoilerGuard.merge(picks, verdict: nil).allSatisfy { $0.why == SpoilerGuard.fallback })
        #expect(SpoilerGuard.parseVerdict("не JSON") == nil)
        #expect(SpoilerGuard.parseVerdict("{\"other\": [1]}") == nil)
        #expect(SpoilerGuard.parseVerdict(nil) == nil)
    }

    /// Не отмеченные проверкой — без изменений; пустые так и остаются пустыми.
    @Test func cleanLinesStay() {
        let picks = [pick("Бабадук", safe), pick("Без связи", "")]
        let result = SpoilerGuard.merge(picks, verdict: [])
        #expect(result[0].why == safe)
        #expect(result[1].why.isEmpty)
    }

    @Test func parsing() {
        #expect(SpoilerGuard.parseVerdict("{\"spoilers\": [0, 3]}") == [0, 3])
        #expect(SpoilerGuard.parseVerdict("{\"spoilers\": [\"2\"]}") == [2])
        #expect(SpoilerGuard.parseRewrites("{\"items\": [{\"i\": 1, \"why\": \"тайны дома\"}, {\"i\": \"4\", \"why\": \" \"}]}") == [1: "тайны дома"])
        #expect(SpoilerGuard.parseRewrites("мусор").isEmpty)
    }

    /// Запросы требуют суждения по смыслу о ОБЕИХ работах и описания только по завязке.
    @Test func promptsCarryRules() {
        #expect(SpoilerGuard.rules.contains("SPOILER-FREE for BOTH works"))
        let check = SpoilerGuard.checkPrompt(seed: "Hereditary (2018)", items: [("The Skeleton Key", "переселение душ")])
        #expect(check.contains("Judge by MEANING"))
        #expect(check.contains("0: \"The Skeleton Key\" — переселение душ"))
        let fix = SpoilerGuard.rewritePrompt(seed: "Hereditary (2018)", items: [(3, "The Skeleton Key", "переселение душ")])
        #expect(fix.contains("3: \"The Skeleton Key\""))
        #expect(fix.contains(SpoilerGuard.rules))
    }
}
