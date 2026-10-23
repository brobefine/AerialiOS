import Foundation
import TorrServerKit

/// Тонкая обёртка над API gomobile (`Torrserverkit*`): приложение не видит имён Go.
public enum TorrServerEngine {
    /// Запускает HTTP-сервер и клиент BitTorrent на 127.0.0.1:`port`. Пустая строка — успех, иначе текст ошибки.
    public static func start(port: Int, dataDir: String) -> String {
        TorrserverkitStartServer(port, dataDir)
    }

    /// Останавливает сервер (до 5 с). Пустая строка — успех.
    public static func stop() -> String {
        TorrserverkitStopServer()
    }

    public static var isRunning: Bool {
        TorrserverkitIsRunning()
    }
}
