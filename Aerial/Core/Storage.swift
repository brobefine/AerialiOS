import Foundation

/// Где лежат данные. В LiveContainer документы приложения могут оказаться в общей папке группы приложений
/// (`…/Shared/AppGroup/…`) — там нельзя держать блокировки файлов, пока приложение свёрнуто.
enum Storage {
    static let sharedGroup: Bool = URL.documentsDirectory.path.contains("/Shared/AppGroup/")

    /// Временная папка самого процесса — по системному `confstr`, а не по `TMPDIR`, который LiveContainer подменяет.
    static let privateTemp: URL = {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 {
            return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
    }()

    static func logPlacement() {
        Log.note("ДАННЫЕ", "приложение \(Bundle.main.bundlePath); документы \(URL.documentsDirectory.path)"
            + (DownloadKeepAlive.insideContainer ? "; LiveContainer" : "") + (sharedGroup ? "; общая папка группы" : ""))
    }
}
