import Foundation
import Observation

/// Настройки приложения поверх UserDefaults: меняются из экрана настроек, сохраняются сразу.
@MainActor @Observable
final class AppSettings {
    enum ServerMode: String, CaseIterable, Identifiable {
        case embedded, external
        var id: String { rawValue }
        var title: String { self == .embedded ? "Встроенный" : "Внешний" }
    }

    struct ParserServer: Identifiable, Sendable {
        var name: String
        var address: String
        var key: String = ""
        var id: String { address }
    }

    /// Публичные серверы JacRed — каталог, как у ТВ (`ParserState.catalog`): имя, адрес, ключ.
    static let parserCatalog: [ParserServer] = [
        ParserServer(name: "Jac.red", address: "https://jac.red"),
        ParserServer(name: "JacRed.su", address: "https://jacred.su"),
        ParserServer(name: "jac-red.ru", address: "https://jac-red.ru"),
        ParserServer(name: "Lampa.app", address: "https://lampa.app"),
        ParserServer(name: "jr.maxvol.pro", address: "https://jr.maxvol.pro"),
        ParserServer(name: "Jacred.my.to", address: "https://jacred.my.to"),
        ParserServer(name: "Viewbox", address: "https://jacred.viewbox.dev", key: "viewbox"),
    ]

    private let defaults = UserDefaults.standard

    var parserAddress: String { didSet { defaults.set(parserAddress, forKey: "parser.address") } }
    var parserKey: String { didSet { defaults.set(parserKey, forKey: "parser.key") } }
    /// Torrentio — раздачи по номеру IMDb (в основном зарубежные), без ключа.
    var torrentio: Bool { didSet { defaults.set(torrentio, forKey: "parser.torrentio") } }
    var serverMode: ServerMode { didSet { defaults.set(serverMode.rawValue, forKey: "torrserver.mode") } }
    var externalAddress: String { didSet { defaults.set(externalAddress, forKey: "torrserver.address") } }
    /// Кэш встроенного TorrServer в памяти, МБ.
    var cacheMB: Int { didSet { defaults.set(cacheMB, forKey: "torrserver.cacheMB") } }
    var tmdbProxy: String { didSet { defaults.set(tmdbProxy, forKey: TMDb.proxyKey) } }

    init() {
        parserAddress = defaults.string(forKey: "parser.address") ?? Self.parserCatalog[0].address
        parserKey = defaults.string(forKey: "parser.key") ?? ""
        torrentio = defaults.object(forKey: "parser.torrentio") as? Bool ?? true
        serverMode = ServerMode(rawValue: defaults.string(forKey: "torrserver.mode") ?? "") ?? .embedded
        externalAddress = defaults.string(forKey: "torrserver.address") ?? ""
        cacheMB = defaults.object(forKey: "torrserver.cacheMB") as? Int ?? 256
        tmdbProxy = defaults.string(forKey: TMDb.proxyKey) ?? TMDb.defaultProxy
    }
}
