import Foundation
import OSLog

/// Журнал в файлы, как у ТВ: `Documents/logs/app.log` (прошлый запуск — `app.log.1`), `mpv.log` — журнал плеера,
/// `perf.log` — замеры [PerfMonitor], `metrics/` — отчёты MetricKit (энергия, зависания, падения).
/// Папка видна в «Файлах» (На iPhone › Aerial › logs) — оттуда журнал можно прислать.
enum Log {
    static let directory: URL = {
        let dir = URL.documentsDirectory.appending(path: "logs", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let queue = DispatchQueue(label: "aerial.log", qos: .utility)
    private static let logger = Logger(subsystem: "com.aerial.ios", category: "app")
    private static let app = LogFile(name: "app.log", limit: 4 << 20)
    private static let mpv = LogFile(name: "mpv.log", limit: 8 << 20)
    private static let perfFile = LogFile(name: "perf.log", limit: 4 << 20)
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "dd.MM HH:mm:ss.SSS"
        return f
    }()

    /// Начало запуска: прошлые журналы уходят в `.1`, чтобы падение было видно и после перезапуска.
    static func startSession() {
        reserveStandardDescriptors()
        queue.sync {
            app.rotate()
            mpv.rotate()
            perfFile.rotate()
        }
        let info = Bundle.main.infoDictionary
        note("ЗАПУСК", "Aerial \(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?")), iOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    static func note(_ tag: String, _ message: String) {
        logger.info("\(tag, privacy: .public): \(message, privacy: .public)")
        let line = "\(stamp.string(from: .now)) \(tag): \(message)\n"
        queue.async { app.append(line) }
    }

    /// Приложение, запущенное не из Xcode, может стартовать с закрытыми 0, 1, 2. Тогда первый открытый файл журнала
    /// получал номер 1 или 2, а встроенный TorrServer перенаправляет stdout/stderr в свой журнал (`dup2`) — и записи
    /// `app.log` уходили к нему: `app.log` «переставал писаться». Пустые номера занимаем /dev/null.
    private static func reserveStandardDescriptors() {
        for fd: Int32 in 0...2 where fcntl(fd, F_GETFD) == -1 {
            let null = open("/dev/null", O_RDWR)
            if null >= 0 && null != fd {
                dup2(null, fd)
                close(null)
            }
        }
    }

    /// Замеры производительности и энергии ([PerfMonitor]) — `perf.log`.
    static func perf(_ line: String) {
        let text = "\(stamp.string(from: .now)) \(line)\n"
        queue.async { perfFile.append(text) }
    }

    static func player(_ line: String) {
        let text = "\(stamp.string(from: .now)) \(line)" + (line.hasSuffix("\n") ? "" : "\n")
        queue.async { mpv.append(text) }
    }
}

/// Один файл журнала с пределом размера: переполнился — уходит в `.1`, пишем заново.
private final class LogFile {
    let url: URL
    let limit: Int
    private var handle: FileHandle?
    private var abandoned: [FileHandle] = []
    private var size = 0

    init(name: String, limit: Int) {
        url = Log.directory.appending(path: name)
        self.limit = limit
    }

    func rotate() {
        try? handle?.close()
        handle = nil
        let old = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
        size = 0
    }

    func append(_ line: String) {
        let data = Data(line.utf8)
        if size + data.count > limit { rotate() }
        // Дескриптор подменили (`dup2` сервера) или файл удалили из «Файлов» — открываем заново.
        // Старый не закрываем: под его номером теперь чужой файл (журнал сервера) — держим, чтобы не закрыть его.
        if let handle, !Self.same(handle.fileDescriptor, url.path) {
            abandoned.append(handle)
            self.handle = nil
        }
        if handle == nil {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            size = Int((try? handle?.seekToEnd()) ?? 0)
        }
        try? handle?.write(contentsOf: data)
        size += data.count
    }

    private static func same(_ fd: Int32, _ path: String) -> Bool {
        var open = stat()
        var disk = stat()
        guard fstat(fd, &open) == 0, stat(path, &disk) == 0 else { return false }
        return open.st_ino == disk.st_ino && open.st_dev == disk.st_dev
    }
}
