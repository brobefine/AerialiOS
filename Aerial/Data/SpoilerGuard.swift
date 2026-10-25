import Foundation

/// «Духовные родственники» без спойлеров (25 октября: к «Реинкарнации» ИИ написал «переселение душ через ритуалы
/// чёрной магии» — это развязка). Спойлер распознаётся по смыслу, а не по словам — слов-признаков не перечислить:
/// 1. запрос: «чем связан» — только завязка обеих работ ([rules]);
/// 2. проверка: модель читает каждое «чем связан» и называет спойлеры ([checkPrompt]);
/// 3. отмеченные модель переписывает по завязке ([rewritePrompt]), переписанное проверяется ещё раз;
/// 4. и после этого спойлер — нейтральная фраза ([fallback]): описание есть всегда, развязки нет никогда.
/// Проверка не ответила — нейтральная фраза у всех (лучше общо, чем спойлер). То же — на ТВ (`SpoilerGuard.kt`).
enum SpoilerGuard {
    static let rules = "The \"why\" must be completely SPOILER-FREE for BOTH works: use only what a viewer knows from the " +
        "official synopsis or the first 15 minutes — the premise, setting, mood or central question. NEVER reveal or hint at endings, " +
        "twists, final-act events, who dies, secret identities, the true nature or hidden cause of events (for example possession, " +
        "a cult's real goal, a character being dead, imagined or someone else), or how a mystery is solved. If the strongest link " +
        "between two works is a spoiler, describe a safe premise-level link instead."

    /// Когда безопасной формулировки нет.
    static var fallback: String { L("Близки по настроению и темам") }

    static func checkPrompt(seed: String, items: [(title: String, why: String)]) -> String {
        let list = items.enumerated().map { "\($0.offset): \"\($0.element.title)\" — \($0.element.why)" }.joined(separator: "\n")
        return "You are a strict spoiler checker for a movie app. Each line below links the work \"\(seed)\" to another work. " +
            "Judge by MEANING, using everything you know about BOTH works: mark every line whose phrase reveals or hints at an ending, " +
            "twist, final-act event, death, secret identity, the true nature or hidden cause of events, or the solution of a mystery " +
            "of EITHER work — anything a first-time viewer would not know from the official synopsis. When in doubt, mark it.\n" +
            list + "\nReturn JSON {\"spoilers\": [line numbers]}."
    }

    static func rewritePrompt(seed: String, items: [(index: Int, title: String, why: String)]) -> String {
        let list = items.map { "\($0.index): \"\($0.title)\" — \($0.why)" }.joined(separator: "\n")
        return "Each line links the work \"\(seed)\" to another work, but the phrase gives away a plot secret. Rewrite every phrase " +
            "in \(AppLanguage.ai) (max 70 chars) so it still names a real, specific link between the two works, but only through their " +
            "premise, setting, mood or central question as known from the official synopses. " + rules + "\n" + list +
            "\nReturn JSON {\"items\": [{\"i\": line number, \"why\": new phrase}]}."
    }

    /// Номера спойлеров; не разобрался — nil.
    static func parseVerdict(_ text: String?) -> Set<Int>? {
        guard let object = json(text), let list = object["spoilers"] as? [Any] else { return nil }
        return Set(list.compactMap { ($0 as? NSNumber)?.intValue ?? Int($0 as? String ?? "") })
    }

    /// Переписанные фразы по номерам строк.
    static func parseRewrites(_ text: String?) -> [Int: String] {
        guard let object = json(text), let rows = object["items"] as? [[String: Any]] else { return [:] }
        var result: [Int: String] = [:]
        for row in rows {
            guard let index = (row["i"] as? NSNumber)?.intValue ?? Int(row["i"] as? String ?? ""),
                  let why = (row["why"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !why.isEmpty else { continue }
            result[index] = String(why.prefix(100))
        }
        return result
    }

    /// Итог. [verdict] — спойлеры исходных фраз (nil — проверки не было); [rewrites] — переписанные по номерам;
    /// [recheck] — номера (исходные) переписанных, что всё ещё спойлер (nil — повторной проверки не было).
    static func merge(_ titles: [AiTitle], verdict: Set<Int>?, rewrites: [Int: String] = [:], recheck: Set<Int>? = nil) -> [AiTitle] {
        titles.enumerated().map { index, title in
            var safe = title
            if title.why.isEmpty { return safe }
            guard let verdict else {
                safe.why = fallback
                return safe
            }
            guard verdict.contains(index) else { return safe }
            if let rewrite = rewrites[index], let recheck, !recheck.contains(index) {
                safe.why = rewrite
            } else {
                safe.why = fallback
            }
            return safe
        }
    }

    private static func json(_ text: String?) -> [String: Any]? {
        guard let data = text?.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
