import Foundation

/// Защита «Духовных родственников» от спойлеров (24 октября: к «Реинкарнации» ИИ написал «переселение душ через ритуалы
/// чёрной магии» — это развязка фильма). Одной просьбы в запросе мало, поэтому слоями:
/// 1. запрос: «чем связан» — только завязка обеих работ, без концовок, поворотов и скрытой правды ([rules]);
/// 2. проверка: модель отдельно читает каждое «чем связан» и называет спойлеры — они не показываются ([apply]);
///    проверка не удалась — не показывается ни одно «чем связан» (лучше пусто, чем спойлер);
/// 3. местный фильтр по словам-признакам развязки ([hasMarkers]) — срабатывает и без модели.
/// Тот же порядок — в приложении для ТВ (`SpoilerGuard.kt`).
enum SpoilerGuard {
    /// Правило для запроса «родственников» — общее с ТВ.
    static let rules = "The \"why\" must be completely SPOILER-FREE for BOTH works: use only what a viewer knows from the " +
        "official synopsis or the first 15 minutes — the premise, setting, mood or central question. NEVER reveal or hint at endings, " +
        "twists, final-act events, who dies, secret identities, the true nature or hidden cause of events (for example possession, " +
        "a cult's real goal, a character being dead, imagined or someone else), or how a mystery is solved. If the strongest link " +
        "between two works is a spoiler, describe a safe premise-level link instead, or leave that title out."

    /// Признаки развязки: такие «чем связан» не показываются никогда, что бы ни ответила проверка.
    private static let markers = [
        "финал", "в конце", "концовк", "развязк", "оказыва", "на самом деле", "твист", "поворот", "разгадк",
        "выясня", "раскрыва", "тайна раскры", "погиба", "умира", "умер", "мёртв", "мертв", "переселени", "одержим",
        "вселя", "подмен", "двойник", "воображ", "галлюцин", "приснил", "был призрак", "ending", "twist", "turns out",
        "reveal", "dies", "was dead",
    ]

    static func hasMarkers(_ text: String) -> Bool {
        let lower = text.lowercased().replacingOccurrences(of: "ё", with: "е")
        return markers.contains { lower.contains($0.replacingOccurrences(of: "ё", with: "е")) }
    }

    /// Запрос проверки: номера фраз со спойлерами. `items` — пары «название — чем связан».
    static func checkPrompt(seed: String, items: [(title: String, why: String)]) -> String {
        let list = items.enumerated().map { "\($0.offset): \"\($0.element.title)\" — \($0.element.why)" }.joined(separator: "\n")
        return "You are a strict spoiler checker for a movie app. Each line below links the work \"\(seed)\" to another work. " +
            "Using everything you know about BOTH works, mark every line whose phrase reveals or hints at an ending, twist, " +
            "final-act event, death, secret identity, the true nature or hidden cause of events, or the solution of a mystery " +
            "of EITHER work — anything a first-time viewer would not know from the official synopsis. When in doubt, mark it.\n" +
            list + "\nReturn JSON {\"spoilers\": [line numbers]}."
    }

    /// Ответ проверки → номера спойлеров; не разобрался — nil (тогда скрываем все).
    static func parseVerdict(_ text: String) -> Set<Int>? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["spoilers"] as? [Any] else { return nil }
        return Set(list.compactMap { ($0 as? NSNumber)?.intValue ?? Int($0 as? String ?? "") })
    }

    /// Итог: спойлер по проверке или по признакам — «чем связан» пустое; проверки нет (nil) — пустые все.
    static func apply(_ titles: [AiTitle], verdict: Set<Int>?) -> [AiTitle] {
        titles.enumerated().map { index, title in
            var safe = title
            if verdict == nil || verdict?.contains(index) == true || hasMarkers(title.why) { safe.why = "" }
            return safe
        }
    }
}
