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
