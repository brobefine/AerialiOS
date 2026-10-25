import Foundation

/// Язык приложения, как настройка языка ТВ: «Как в системе», «Русский», «English». Строки интерфейса написаны
/// по-русски и переводятся через [L] по таблице [English]; каталог TMDb, даты и ответы ИИ — на том же языке.
/// Выбор применяется при следующем запуске: ряды каталога и ответы TMDb в кэше уже на старом языке.
enum AppLanguage {
    static let key = "app.language"

    /// «system», «ru» или «en».
    static let setting = UserDefaults.standard.string(forKey: key) ?? "system"

    static let english: Bool = {
        // UI-тесты ищут кнопки по русским названиям, модульные сверяют русский текст — в тестах всегда русский
        // (симулятор CI на английском).
        let process = ProcessInfo.processInfo
        if process.arguments.contains("-uiTest") || process.environment["XCTestConfigurationFilePath"] != nil { return false }
        switch setting {
        case "en": return true
        case "ru": return false
        default: return !(Locale.preferredLanguages.first ?? "ru").hasPrefix("ru")
        }
    }()

    /// Язык запросов TMDb.
    static var tmdb: String { english ? "en-US" : "ru-RU" }
    /// Язык ответов ИИ — в тексте запроса.
    static var ai: String { english ? "English" : "Russian" }
    static var locale: Locale { Locale(identifier: english ? "en_US" : "ru_RU") }
}

/// Строка интерфейса на языке приложения: русский текст — ключ, перевод — из [English.table]; нет перевода — русский.
func L(_ russian: String) -> String {
    AppLanguage.english ? (English.table[russian] ?? russian) : russian
}

/// Строка с подстановками: `%@` в тексте по порядку заменяются [args] (без `String(format:)` — в тексте бывает «%»).
func L(_ russian: String, _ args: String...) -> String {
    var text = L(russian)
    for arg in args {
        guard let range = text.range(of: "%@") else { break }
        text.replaceSubrange(range, with: arg)
    }
    return text
}
