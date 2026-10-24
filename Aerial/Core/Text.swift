import Foundation

/// Регулярное выражение ICU (NSRegularExpression): в нём есть просмотр назад, нужный разбору раздач,
/// и те же флаги `(?i)`/`(?u)`, что у шаблонов ТВ, — шаблоны переносятся как есть.
struct Rx: @unchecked Sendable {
    private let regex: NSRegularExpression

    init(_ pattern: String) {
        // Шаблоны — константы кода: ошибка в них должна падать сразу на тестах, а не молча не находить.
        regex = try! NSRegularExpression(pattern: pattern)
    }

    func matches(_ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Группы первого совпадения: [0] — всё совпадение, отсутствующая группа — пустая строка.
    func groups(_ text: String) -> [String]? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    /// Начало первого совпадения в UTF-16 — для сравнения, какое из двух найдено раньше.
    func location(_ text: String) -> Int? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.range.location
    }

    func all(_ text: String) -> [String] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
}

enum SearchText {
    /// Как `normalizedSearch` ТВ: нижний регистр, ё → е, слова через один пробел.
    static func normalized(_ value: String) -> String {
        let lowered = value.lowercased().replacingOccurrences(of: "ё", with: "е")
        return lowered.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Похожесть названия на запрос, как `titleSearchRelevance` ТВ: точное — 100, начало — 80, все слова — 60, вхождение — 40.
    static func relevance(_ query: String, title: String, original: String = "") -> Int {
        let wanted = normalized(query)
        guard !wanted.isEmpty else { return 0 }
        return [title, original].map { alias in
            let candidate = normalized(alias)
            if candidate == wanted { return 100 }
            if candidate.hasPrefix(wanted) { return 80 }
            let words = candidate.split(separator: " ")
            if wanted.split(separator: " ").allSatisfy({ part in words.contains { $0.hasPrefix(part) } }) { return 60 }
            if candidate.contains(wanted) { return 40 }
            return 0
        }.max() ?? 0
    }
}

/// Подсказки поиска — перенос `rankVodSuggestions` ТВ: точное и начало названия раньше совпадения слов, затем
/// исправленная раскладка («lsyf» → «дюна»), транслит и одна опечатка. Недавние запросы — первыми при равенстве.
enum Suggestions {
    struct Title: Sendable {
        var title: String
        var original = ""
    }

    static func rank(_ query: String, titles: [Title], recent: [String], limit: Int = 6) -> [String] {
        let wanted = key(query)
        let all = (recent.map { Title(title: $0) } + titles).filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
        var seen = Set<String>()
        guard !wanted.isEmpty else {
            return Array(all.map { $0.title.trimmingCharacters(in: .whitespaces) }.filter { seen.insert(key($0)).inserted }.prefix(limit))
        }
        var queries = [(query, 0)]
        let repaired = repairKeyboard(query)
        if key(repaired) != wanted { queries.append((repaired, 4)) }
        let scored = all.enumerated().compactMap { index, candidate -> (String, Int, Int)? in
            let scores = [candidate.title, candidate.original].filter { !$0.isEmpty }.flatMap { alias in
                queries.compactMap { pair in score(pair.0, alias).map { $0 + pair.1 } }
            }
            guard let best = scores.min() else { return nil }
            return (candidate.title.trimmingCharacters(in: .whitespaces), best, index)
        }
        return Array(scored.sorted { ($0.1, $0.2) < ($1.1, $1.2) }.map { $0.0 }.filter { seen.insert(key($0)).inserted }.prefix(limit))
    }

    /// Ключ сравнения: нижний регистр, ё → е, только буквы и цифры.
    static func key(_ value: String) -> String {
        String(value.lowercased().replacingOccurrences(of: "ё", with: "е").filter { $0.isLetter || $0.isNumber })
    }

    private static func words(_ value: String) -> [String] {
        value.lowercased().replacingOccurrences(of: "ё", with: "е")
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    private static func score(_ query: String, _ title: String) -> Int? {
        let q = key(query), t = key(title)
        guard !q.isEmpty else { return nil }
        if t == q { return 0 }
        if t.hasPrefix(q) { return 10 }
        let qw = words(query), tw = words(title)
        if !qw.isEmpty && qw.allSatisfy({ part in tw.contains { $0.hasPrefix(part) } }) { return 20 }
        if q.count >= 2 && t.contains(q) { return 30 }
        let tq = transliterate(q)
        if tq.count >= 3 && transliterate(t).hasPrefix(tq) { return 35 }
        if q.count >= 4 && qw.allSatisfy({ part in part.count >= 4 && tw.contains { oneTypo(part, String($0.prefix(part.count))) } }) {
            return 60
        }
        return nil
    }

    static func oneTypo(_ a: String, _ b: String) -> Bool {
        let a = Array(a), b = Array(b)
        guard abs(a.count - b.count) <= 1 else { return false }
        if a == b { return true }
        if a.count == b.count {
            let different = a.indices.filter { a[$0] != b[$0] }
            return different.count == 1 || (different.count == 2 && different[1] == different[0] + 1
                && a[different[0]] == b[different[1]] && a[different[1]] == b[different[0]])
        }
        let (longer, shorter) = a.count > b.count ? (a, b) : (b, a)
        return longer.indices.contains { index in
            var copy = longer
            copy.remove(at: index)
            return copy == shorter
        }
    }

    /// Набрано не в той раскладке: латиница ↔ кириллица по клавишам.
    static func repairKeyboard(_ value: String) -> String {
        let latin = Array("qwertyuiop[]asdfghjkl;'zxcvbnm,.")
        let russian = Array("йцукенгшщзхъфывапролджэячсмитьбю")
        let lowered = value.lowercased()
        let toRussian = lowered.filter { latin.contains($0) }.count > lowered.filter { russian.contains($0) }.count
        let (from, to) = toRussian ? (latin, russian) : (russian, latin)
        return String(lowered.map { char in from.firstIndex(of: char).map { to[$0] } ?? char })
    }

    private static func transliterate(_ value: String) -> String {
        let letters = Array("абвгдеёжзийклмнопрстуфхцчшщъыьэюя")
        let replacements = ["a", "b", "v", "g", "d", "e", "e", "zh", "z", "i", "y", "k", "l", "m", "n", "o", "p", "r", "s", "t", "u",
                            "f", "h", "ts", "ch", "sh", "sch", "", "y", "", "e", "yu", "ya"]
        return value.map { char in letters.firstIndex(of: char).map { replacements[$0] } ?? String(char) }.joined()
    }
}

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    /// «1:42:05» или «42:05».
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// «2 ч 14 мин», «48 мин».
    static func runtime(minutes: Int) -> String {
        guard minutes > 0 else { return "" }
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) мин" }
        return m == 0 ? "\(h) ч" : "\(h) ч \(m) мин"
    }

    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let mod100 = n % 100, mod10 = n % 10
        if (11...14).contains(mod100) { return many }
        if mod10 == 1 { return one }
        if (2...4).contains(mod10) { return few }
        return many
    }

    /// «2026-10-24» → «24 октября 2026».
    static func date(_ iso: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: String(iso.prefix(10))) else { return iso }
        let out = DateFormatter()
        out.locale = Locale(identifier: "ru_RU")
        out.dateFormat = "d MMMM yyyy"
        return out.string(from: date)
    }
}
