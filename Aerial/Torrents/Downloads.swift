import Foundation
import Observation
import UIKit

/// Файл раздачи в загрузке. Серия — если в названии есть её координаты.
struct DownloadFile: Codable, Hashable, Identifiable, Sendable {
    var index: Int
    var path: String
    var bytes: Int64
    var episode: VodEpisode?

    var id: Int { index }
    var torrentFile: TorrentFile { TorrentFile(index: index, path: path, bytes: bytes) }
    var name: String { torrentFile.name }
}

/// Раздача в загрузках: работа, ссылка, выбранные файлы и папка в `Documents/Downloads`.
struct DownloadJob: Codable, Identifiable, Sendable {
    var hash: String
    var item: VodItem
    var link: String
    var releaseTitle: String
    var folder: String
    var files: [DownloadFile]
    var added: Date
    var paused = false
    var failure: String?

    var id: String { hash }
    var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
}

/// Загрузки — перенос `TorrentDownloads` ТВ: файлы раздачи по очереди читаются у TorrServer тем же адресом, что у плеера,
/// и пишутся в `Documents/Downloads/<работа>` (видно в «Файлах»). Файл пишется как `.part` и докачивается с места
/// обрыва (Range). Скачанный файл плеер берёт с диска — без сети ([localURL]).
///
/// iOS не даёт приложению качать в фоне дольше полминуты: загрузка идёт, пока приложение открыто (или играет фильм),
/// а при возврате продолжается сама ([kick]).
@MainActor @Observable
final class Downloads {
    static let shared = Downloads()

    static let root: URL = {
        var dir = URL.documentsDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Фильмы не уходят в резервную копию iCloud.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }()

    private(set) var jobs: [DownloadJob] = []
    /// Байт на диске по раздаче — готовые файлы и `.part`.
    private(set) var done: [String: Int64] = [:]
    /// Раздача, которая качается сейчас.
    private(set) var active: String?
    private(set) var rate: Int64 = 0

    @ObservationIgnored private weak var settings: AppSettings?
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var background: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private let manifest = URL.applicationSupportDirectory.appending(path: "downloads.json")

    init() {
        if let data = try? Data(contentsOf: manifest), let value = try? JSONDecoder().decode([DownloadJob].self, from: data) {
            jobs = value
        }
        for job in jobs { done[job.hash] = onDisk(job) }
    }

    func attach(_ settings: AppSettings) {
        self.settings = settings
        kick()
    }

    var busy: Bool { active != nil }

    // MARK: Файлы

    /// Куда лечь файлу: подпапки раздачи сохраняются («Сезон 1/01.mkv» и «Сезон 2/01.mkv» — разные файлы), корневая
    /// папка раздачи — нет (её роль играет папка работы).
    func target(_ job: DownloadJob, _ file: DownloadFile) -> URL {
        let parts = file.path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init).filter { !$0.isEmpty }
        let inner = parts.count > 1 ? Array(parts.dropFirst()) : parts
        return inner.reduce(Self.root.appending(path: job.folder, directoryHint: .isDirectory)) { $0.appending(path: Self.safe($1)) }
    }

    private static func size(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    func isComplete(_ job: DownloadJob, _ file: DownloadFile) -> Bool {
        file.bytes > 0 && Self.size(target(job, file)) == file.bytes
    }

    func complete(_ job: DownloadJob) -> Bool { job.files.allSatisfy { isComplete(job, $0) } }

    private func onDisk(_ job: DownloadJob) -> Int64 {
        job.files.reduce(0) { sum, file in
            let url = target(job, file)
            return sum + (isComplete(job, file) ? file.bytes : Self.size(url.deletingLastPathComponent().appending(path: url.lastPathComponent + ".part")))
        }
    }

    private func job(link: String) -> DownloadJob? {
        let hash = TorrServerClient.infoHash(link)
        return jobs.first { $0.link == link || $0.hash == hash }
    }

    /// Скачанный файл раздачи: [fileIndex] nil — единственный файл. Недокачанный — nil (играет TorrServer).
    func localURL(link: String, fileIndex: Int?) -> URL? {
        guard let job = job(link: link) else { return nil }
        let file = fileIndex.flatMap { index in job.files.first { $0.index == index } } ?? (job.files.count == 1 ? job.files.first : nil)
        guard let file, isComplete(job, file) else { return nil }
        return target(job, file)
    }

    /// Скачанные файлы раздачи — для следующей серии без сети.
    func localFiles(link: String) -> [TorrentFile] {
        guard let job = job(link: link) else { return [] }
        return job.files.filter { isComplete(job, $0) }.map(\.torrentFile)
    }

    // MARK: Управление

    /// Поставить файлы раздачи в загрузку. Вернёт текст ошибки или nil — загрузка пошла. Та же раздача — файлы
    /// добавляются к прежним.
    func add(item: VodItem, link: String, releaseTitle: String, info: TorrentInfo, files: [DownloadFile]) -> String? {
        guard !files.isEmpty else { return L("В раздаче нет видеофайлов") }
        var job = jobs.first { $0.hash == info.hash } ?? DownloadJob(
            hash: info.hash, item: item, link: link, releaseTitle: releaseTitle,
            folder: Self.safe(item.title + (item.year.isEmpty ? "" : " (\(item.year))")), files: [], added: .now)
        let fresh = files.filter { file in !job.files.contains { $0.index == file.index } }
        let needed = fresh.reduce(Int64(0)) { $0 + $1.bytes }
        let free = (try? Self.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? .max
        if needed > free {
            return String(format: L("Не хватает места: нужно %@, свободно %@"), Format.bytes(needed), Format.bytes(free))
        }
        job.files = (job.files + fresh).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        job.paused = false
        job.failure = nil
        if let index = jobs.firstIndex(where: { $0.hash == job.hash }) { jobs[index] = job } else { jobs.insert(job, at: 0) }
        done[job.hash] = onDisk(job)
        persist()
        Log.note("ЗАГРУЗКА", "\(item.title): +\(fresh.count) файл., \(Format.bytes(needed)) → \(job.folder)")
        kick()
        return nil
    }

    func pause(_ job: DownloadJob, _ paused: Bool) {
        update(job.hash) {
            $0.paused = paused
            $0.failure = nil
        }
        if paused && active == job.hash { restart() } else { kick() }
    }

    func delete(_ job: DownloadJob) {
        jobs.removeAll { $0.hash == job.hash }
        done[job.hash] = nil
        persist()
        if active == job.hash { restart() }
        try? FileManager.default.removeItem(at: Self.root.appending(path: job.folder, directoryHint: .isDirectory))
        Log.note("ЗАГРУЗКА", "удалена \(job.item.title)")
    }

    func deleteFile(_ job: DownloadJob, _ file: DownloadFile) {
        guard job.files.count > 1 else { return delete(job) }
        update(job.hash) { $0.files.removeAll { $0.index == file.index } }
        if active == job.hash { restart() }
        let url = target(job, file)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent().appending(path: url.lastPathComponent + ".part"))
        if let fresh = jobs.first(where: { $0.hash == job.hash }) { done[job.hash] = onDisk(fresh) }
    }

    /// Запустить очередь, если она стоит: после запуска приложения, возврата из фона, новой загрузки, повтора.
    func kick() {
        guard runner == nil, settings != nil else { return }
        runner = Task { [weak self] in
            await self?.run()
            self?.runner = nil
        }
    }

    /// Возврат из фона: прерванное сном продолжается.
    func resume() {
        for job in jobs where job.failure != nil && !job.paused { update(job.hash) { $0.failure = nil } }
        kick()
    }

    /// Уход в фон: держит приложение беззвучный звук ([DownloadKeepAlive]); задание фона — запас, если звук не включился.
    func enterBackground() {
        guard busy, background == .invalid else { return }
        background = UIApplication.shared.beginBackgroundTask(withName: "downloads") { [weak self] in
            MainActor.assumeIsolated { self?.endBackground() }
        }
    }

    private func endBackground() {
        guard background != .invalid else { return }
        UIApplication.shared.endBackgroundTask(background)
        background = .invalid
    }

    private func restart() {
        runner?.cancel()
        runner = nil
        active = nil
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.kick()
        }
    }

    // MARK: Очередь

    private func run() async {
        while !Task.isCancelled, let settings {
            guard let job = jobs.first(where: { !$0.paused && $0.failure == nil && !complete($0) }) else { break }
            active = job.hash
            PerfMonitor.activity = "загрузка: \(job.item.title)"
            do {
                let client = try await Torrents.client(settings)
                // Раздача могла уйти из сервера после перезапуска — добавляем снова (по хэшу быстро).
                _ = try await client.add(link: job.link, title: job.item.title)
                for file in job.files where !isComplete(job, file) {
                    try Task.checkCancellation()
                    guard let current = jobs.first(where: { $0.hash == job.hash }), !current.paused,
                          current.files.contains(where: { $0.index == file.index }) else { break }
                    let url = target(job, file)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let before = onDisk(job) - Self.size(url.deletingLastPathComponent().appending(path: url.lastPathComponent + ".part"))
                    try await fetch(client.streamURL(hash: job.hash, file: file.torrentFile), to: url, size: file.bytes) { [weak self] written in
                        guard let self else { return }
                        done[job.hash] = before + written
                        let done = before + written
                        // Звук держит приложение живым в фоне; в LiveContainer он же — плашка в Dynamic Island.
                        DownloadKeepAlive.shared.show(job, fraction: job.totalBytes > 0 ? min(1, Double(done) / Double(job.totalBytes)) : 0,
                                                      rate: rate)
                        if !DownloadKeepAlive.insideContainer {
                            DownloadLive.shared.show(job, done: done, rate: rate,
                                                     left: jobs.filter { !$0.paused && $0.failure == nil && !self.complete($0) }.count)
                        }
                    }
                    done[job.hash] = onDisk(job)
                }
                if complete(job) { Log.note("ЗАГРУЗКА", "готово \(job.item.title)") }
            } catch {
                if Task.isCancelled || HTTP.isCancellation(error) { break }
                // Сон iOS рвёт соединение с сервером — это не ошибка: при возврате загрузка продолжится.
                let asleep = UIApplication.shared.applicationState == .background
                Log.note("ЗАГРУЗКА", "\(job.item.title): \(error.localizedDescription)\(asleep ? " (в фоне)" : "")")
                update(job.hash) { $0.failure = asleep ? L("Прервано в фоне") : L("Загрузка прервалась: %@", error.localizedDescription) }
                if asleep { break }
            }
        }
        active = nil
        rate = 0
        PerfMonitor.activity = ""
        DownloadLive.shared.end()
        DownloadKeepAlive.shared.end()
        endBackground()
    }

    /// Файл в [target] через `.part` с докачкой; [onBytes] — сколько байт этого файла уже на диске.
    private func fetch(_ url: URL, to target: URL, size: Int64, onBytes: @escaping @MainActor (Int64) -> Void) async throws {
        let part = target.deletingLastPathComponent().appending(path: target.lastPathComponent + ".part")
        let from = Self.size(part)
        let started = Date()
        let fetcher = FileFetcher(url: url, part: part, from: from) { [weak self] written in
            Task { @MainActor in
                onBytes(written)
                let seconds = Date().timeIntervalSince(started)
                if seconds > 1 { self?.rate = Int64(Double(written - from) / seconds) }
            }
        }
        let written = try await fetcher.run()
        if size > 0 && written < size {
            throw DownloadError.truncated(written, size)
        }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: part, to: target)
    }

    private func update(_ hash: String, _ change: (inout DownloadJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.hash == hash }) else { return }
        change(&jobs[index])
        persist()
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(jobs) { try? data.write(to: manifest, options: .atomic) }
    }

    nonisolated static func safe(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "\\/:*?\"<>|").union(.controlCharacters))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let trimmed = String(cleaned.reversed().drop { $0 == "." }.reversed())
        return String((trimmed.isEmpty ? "video" : trimmed).prefix(120))
    }
}

enum DownloadError: LocalizedError {
    case truncated(Int64, Int64)
    case status(Int)

    var errorDescription: String? {
        switch self {
        case .truncated(let written, let size): L("файл оборвался: %@ из %@ МБ", "\(written >> 20)", "\(size >> 20)")
        case .status(let code): "HTTP \(code)"
        }
    }
}

/// Чтение одного файла у TorrServer прямо на диск: тело ответа пишется кусками, без памяти на весь файл.
/// Есть `.part` — запрос с `Range`; сервер не поддержал (200) — пишем заново.
final class FileFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let part: URL
    private let from: Int64
    private let progress: @Sendable (Int64) -> Void
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var failure: Error?
    /// Сервер ответил 416: `.part` уже целиком на диске.
    private var satisfied = false
    private var lastReport = Date.distantPast
    private var continuation: CheckedContinuation<Int64, Error>?
    private var task: URLSessionDataTask?
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 7 * 24 * 3600
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }()

    init(url: URL, part: URL, from: Int64, progress: @escaping @Sendable (Int64) -> Void) {
        self.url = url
        self.part = part
        self.from = from
        self.progress = progress
    }

    /// Сколько байт файла на диске после загрузки.
    func run() async throws -> Int64 {
        var request = URLRequest(url: url)
        if from > 0 { request.setValue("bytes=\(from)-", forHTTPHeaderField: "Range") }
        let task = session.dataTask(with: request)
        self.task = task
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 416 — `.part` уже целиком на диске: остаётся его переименовать.
        if code == 416 && from > 0 {
            written = from
            satisfied = true
            completionHandler(.cancel)
            return
        }
        guard (200..<300).contains(code) else {
            failure = DownloadError.status(code)
            completionHandler(.cancel)
            return
        }
        let append = from > 0 && code == 206
        if !append || !FileManager.default.fileExists(atPath: part.path) {
            FileManager.default.createFile(atPath: part.path, contents: nil)
        }
        do {
            let handle = try FileHandle(forWritingTo: part)
            if append {
                try handle.seekToEnd()
                written = from
            } else {
                try handle.truncate(atOffset: 0)
                written = 0
            }
            self.handle = handle
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
            written += Int64(data.count)
            if Date().timeIntervalSince(lastReport) > 0.25 {
                lastReport = .now
                progress(written)
            }
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        session.finishTasksAndInvalidate()
        progress(written)
        if let failure {
            continuation?.resume(throwing: failure)
        } else if let error, !satisfied {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(returning: written)
        }
        continuation = nil
    }
}
