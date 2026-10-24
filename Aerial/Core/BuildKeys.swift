import Foundation

/// Ключи сборки из Info.plist (CI пишет их из секретов репозитория в `Config/Secrets.xcconfig`). Пусто — функция
/// выключена: без Worker'а нет друзей и комнат, без ключа MDBList — только свой ключ пользователя.
enum BuildKeys {
    private static func value(_ name: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: name) as? String ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// Worker `aerial-api` (друзья, комнаты): в xcconfig адрес без схемы — «//» там начало комментария.
    static let apiBase: URL? = {
        let host = value("AerialApiHost")
        guard !host.isEmpty, !host.hasPrefix("$(") else { return nil }
        return URL(string: host.contains("://") ? host : "https://\(host)")
    }()

    static let apiToken: String = {
        let token = value("AerialApiToken")
        return token.hasPrefix("$(") ? "" : token
    }()

    static let mdblist: String = {
        let key = value("MDBListKey")
        return key.hasPrefix("$(") ? "" : key
    }()

    static var apiEnabled: Bool { apiBase != nil && !apiToken.isEmpty }
}
