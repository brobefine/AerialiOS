import CryptoKit
import Foundation

/// Ответы TMDb на диске, как `ApiDiskCache` ТВ: повтор того же запроса — из файла, без сети;
/// сеть упала — отдаём старый ответ ([stale]). Предел — по числу файлов, лишние уходят старшие первыми.
final class DiskCache: @unchecked Sendable {
    static let api = DiskCache(name: "api-cache", maxFiles: 3000)

    static let hour: TimeInterval = 3600
    static let day: TimeInterval = 24 * hour

    private let directory: URL
    private let maxFiles: Int
    private let queue = DispatchQueue(label: "aerial.disk-cache", qos: .utility)
    private var writes = 0

    init(name: String, maxFiles: Int) {
        directory = URL.cachesDirectory.appending(path: name, directoryHint: .isDirectory)
        self.maxFiles = maxFiles
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func get(_ key: String, ttl: TimeInterval) -> Data? {
        let file = url(for: key)
        guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              Date().timeIntervalSince(modified) < ttl else { return nil }
        return try? Data(contentsOf: file)
    }

    func stale(_ key: String) -> Data? {
        try? Data(contentsOf: url(for: key))
    }

    func put(_ key: String, _ data: Data) {
        let file = url(for: key)
        queue.async { [self] in
            try? data.write(to: file, options: .atomic)
            writes += 1
            if writes % 200 == 0 { trim() }
        }
    }

    func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    var bytes: Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
    }

    private func trim() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys),
              files.count > maxFiles else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast) }
        for (file, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - maxFiles) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func url(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: digest)
    }
}
