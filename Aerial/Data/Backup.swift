import SwiftUI
import UniformTypeIdentifiers

/// Резервная копия — как `BackupManager` ТВ по смыслу: настройки, медиатека (список, оценки, прогресс, подписки), подбор
/// и друзья одним файлом. Формат свой (plist ключей UserDefaults): у ТВ копия — база Android и prefs, напрямую
/// они не совместимы. Код устройства для друзей не переносится — он у каждого устройства свой.
enum Backup {
    private static let prefixes = ["parser.", "torrserver.", "tmdbProxy", "taste.", "player.", "ai.", "opensubs.", "mdblist.key",
                                   "releases.", "search.", "reviews.", "library.", "friends."]
    private static let skip: Set<String> = ["friends.code", "friends.dirty"]

    static func export() throws -> Data {
        let values = UserDefaults.standard.dictionaryRepresentation().filter { key, _ in
            !skip.contains(key) && prefixes.contains { key.hasPrefix($0) }
        }
        let root: [String: Any] = ["format": 1, "app": "Aerial iOS", "created": Date(), "values": values]
        return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }

    /// Восстановить: ключи копии ложатся поверх нынешних. Вернёт число восстановленных значений.
    @discardableResult
    static func restore(_ data: Data) throws -> Int {
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              root["app"] as? String == "Aerial iOS", let values = root["values"] as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let defaults = UserDefaults.standard
        var count = 0
        for (key, value) in values where !skip.contains(key) && prefixes.contains(where: { key.hasPrefix($0) }) {
            defaults.set(value, forKey: key)
            count += 1
        }
        Log.note("КОПИЯ", "восстановлено \(count) значений")
        return count
    }

    static var fileName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "Aerial-\(formatter.string(from: .now))"
    }
}

/// Файл копии для `fileExporter`.
struct BackupFile: FileDocument {
    static var readableContentTypes: [UTType] { [.propertyList] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
