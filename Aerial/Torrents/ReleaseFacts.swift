import Foundation

/// Что фильтруется помимо разбора названия, как `ReleaseFacts` ТВ: трекеры, год, 3D, языки. Считается раз на раздачу.
struct ReleaseFacts: Sendable {
    static let ru = "RU", uk = "UK", en = "EN"

    var trackers: [String]
    var year: String
    var threeD: Bool
    var languages: Set<String>

    private static let yearWord = Rx("(?<!\\d)(19|20)\\d{2}(?!\\d)")
    private static let threeDWord = Rx("(?i)\\b3D\\b")
    private static let cyrillic = Rx("[А-Яа-яЁё]")
    private static let ruWord = Rx("(?i)\\bRUS\\b")
    private static let ukWord = Rx("(?i)\\bUKR\\b|укр")
    private static let enWord = Rx("(?i)\\bENG\\b|\\bOriginal\\b")

    init(_ release: Release) {
        let title = release.title
        trackers = release.tracker.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        year = Self.yearWord.all(title).first { (1900...2100).contains(Int($0) ?? 0) } ?? ""
        threeD = Self.threeDWord.matches(title)
        var found = Set<String>()
        if Self.cyrillic.matches(title) || Self.ruWord.matches(title) || release.voices.contains(where: { Self.cyrillic.matches($0) }) {
            found.insert(Self.ru)
        }
        if Self.ukWord.matches(title) { found.insert(Self.uk) }
        if Self.enWord.matches(title) { found.insert(Self.en) }
        languages = found
    }

    static func languageTitle(_ code: String) -> String {
        switch code {
        case ru: "Русский"
        case uk: "Украинский"
        case en: "Английский"
        default: code
        }
    }
}
