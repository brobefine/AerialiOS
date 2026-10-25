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

    /// Рантайм Go: процент сборки мусора (GOGC), мягкий лимит памяти в МБ (GOMEMLIMIT), число потоков (GOMAXPROCS).
    /// 0 — не менять. Переменные окружения Go читает при загрузке библиотеки — раньше, чем их может задать приложение.
    public static func setRuntime(gcPercent: Int, memoryLimitMB: Int, maxProcs: Int) {
        TorrserverkitSetRuntime(gcPercent, memoryLimitMB, maxProcs)
    }

    /// Сборка мусора и возврат освобождённой памяти системе — перед сном приложения.
    public static func freeMemory() {
        TorrserverkitFreeMemory()
    }
}
