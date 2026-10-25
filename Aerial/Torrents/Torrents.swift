import Foundation
import Observation
import TorrServerEngine
import UIKit

/// TorrServer внутри приложения: TorrServerKit (gomobile-сборка MatriX из релизов TorrServer) на 127.0.0.1:[port].
/// Работает, пока приложение на экране или играет звук (фоновый режим `audio`); после сна iOS сокет может
/// умереть — [ensureRunning] ждёт `/echo`. Сервер запускается один раз за жизнь процесса: остановка и повторный
/// запуск движка Go обрывали приложение.
@MainActor @Observable
final class EmbeddedTorrServer {
    enum State: Equatable {
        case stopped, starting, running(version: String), failed(String)
    }

    static let shared = EmbeddedTorrServer()
    /// Не 8090: так встроенный сервер не спорит за порт с другими приложениями TorrServer на устройстве.
    static let port = 18090

    private(set) var state: State = .stopped
    private var starting: Task<Void, Never>?

    var address: String { "http://127.0.0.1:\(Self.port)" }
    var client: TorrServerClient { try! TorrServerClient(address: address) }

    /// База и журнал сервера. Обычно — `Documents/TorrServer` (видно в «Файлах»). Если документы лежат в общей папке
    /// группы приложений (так бывает в LiveContainer), база уходит в личную временную папку процесса: сервер всё время
    /// держит блокировку файла базы, а свёрнутое приложение с блокировкой в общей папке iOS сразу закрывает.
    var dataDirectory: URL {
        Storage.sharedGroup ? Storage.privateTemp.appending(path: "TorrServer", directoryHint: .isDirectory)
            : URL.documentsDirectory.appending(path: "TorrServer", directoryHint: .isDirectory)
    }

    func ensureRunning(cacheMB: Int) async throws {
        if case .running = state, await client.echo() != nil { return }
        // Движок Go уже запущен в процессе: второй запуск (как и остановка с запуском) обрывал приложение при
        // возврате из фона. После сна сокет оживает не сразу — ждём ответа, но не перезапускаем.
        if TorrServerEngine.isRunning {
            for _ in 0..<25 {
                if let version = await client.echo() {
                    state = .running(version: version)
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            Log.note("TORRSERVER", "запущен, но не отвечает после сна")
            state = .failed(L("сервер не отвечает — перезапустите приложение"))
            throw TorrServerError.notRunning(L("сервер не отвечает"))
        }
        if let starting {
            await starting.value
        } else {
            let task = Task { await start(cacheMB: cacheMB) }
            starting = task
            await task.value
            starting = nil
        }
        if case .failed(let reason) = state { throw TorrServerError.notRunning(reason) }
    }

    private func start(cacheMB: Int) async {
        state = .starting
        let directory = dataDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.trimLogs(in: directory)
        let port = Self.port
        let error: String = await Task.detached(priority: .userInitiated) {
            TorrServerEngine.start(port: port, dataDir: directory.path)
        }.value
        if !error.isEmpty {
            Log.note("TORRSERVER", "старт: \(error)")
            state = .failed(error)
            return
        }
        let client = self.client
        var version: String?
        for _ in 0..<50 {
            version = await client.echo()
            if version != nil { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard let version else {
            Log.note("TORRSERVER", "не ответил на /echo за 10 с")
            state = .failed(L("сервер не отвечает"))
            return
        }
        await configure(cacheMB: cacheMB)
        Log.note("TORRSERVER", "встроенный \(version) на \(address)")
        state = .running(version: version)
    }

    /// Журналы сервера растут без предела до 100 МБ (сам TorrServer чистит только их), а в `torrserver.log` уходит
    /// весь stderr процесса — сервер перенаправляет его к себе. Больше 4 МБ — прошлый уходит в `.1`.
    private static func trimLogs(in directory: URL) {
        for name in ["torrserver.log", "web.log"] {
            let file = directory.appending(path: name)
            guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 4 << 20 else { continue }
            let previous = file.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.moveItem(at: file, to: previous)
        }
    }

    /// Кэш в памяти по настройке; DLNA, Bonjour и поиск соседей по локальной сети выключены — телефону они не нужны,
    /// а iOS спрашивала бы разрешение на локальную сеть.
    func configure(cacheMB: Int) async {
        let client = self.client
        do {
            var sets = try await client.settings()
            sets["CacheSize"] = cacheMB << 20
            // Подкачка перед стартом — 6 % кэша (~15 МБ при 256): при 50 % (128 МБ) фильм ждал минутами.
            sets["PreloadCache"] = 6
            sets["ReaderReadAHead"] = 95
            sets["UseDisk"] = false
            sets["EnableDLNA"] = false
            sets["EnableBonjour"] = false
            sets["EnableLPD"] = false
            sets["DisableUPNP"] = true
            // Телефон не раздаёт: отдача держит радио включённым и заметно садит батарею (и тратит мобильный трафик).
            sets["DisableUpload"] = true
            try await client.setSettings(sets)
        } catch {
            Log.note("TORRSERVER", "настройки: \(error.localizedDescription)")
        }
    }
}

/// Какой TorrServer использовать: встроенный (по умолчанию) или внешний — на ТВ или ПК в домашней сети.
@MainActor
enum Torrents {
    static func client(_ settings: AppSettings) async throws -> TorrServerClient {
        switch settings.serverMode {
        case .embedded:
            try await EmbeddedTorrServer.shared.ensureRunning(cacheMB: settings.cacheMB)
            return EmbeddedTorrServer.shared.client
        case .external:
            return try TorrServerClient(address: settings.externalAddress)
        }
    }

    /// Встроенный сервер поднимается при запуске приложения, чтобы к выбору раздачи уже был готов.
    static func warmUp(_ settings: AppSettings) async {
        guard settings.serverMode == .embedded else { return }
        try? await EmbeddedTorrServer.shared.ensureRunning(cacheMB: settings.cacheMB)
    }
}
