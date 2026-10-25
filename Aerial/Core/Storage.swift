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

    /// RunningBoard закрывает уснувший процесс, если тот держит замок на файле (0xdead10cc), — кроме файлов с этим
    /// атрибутом. В многозадачном режиме LiveContainer Aerial — расширение LiveProcess, и закрывался через минуту после
    /// сворачивания: база TorrServer (bbolt) держит `flock` всё время. LiveContainer ставит атрибут сам (`Dead10ccFix`),
    /// но не во всех версиях и только когда кончатся фоновые задачи; ставим и мы — при старте сервера и при уходе в фон.
    static func allowSuspendLocked(_ path: String) {
        var value: UInt8 = 1
        _ = setxattr(path, "com.apple.runningboard.can-suspend-locked", &value, 1, 0, 0)
    }

    static func logPlacement() {
        Log.note("ДАННЫЕ", "приложение \(Bundle.main.bundlePath); документы \(URL.documentsDirectory.path)"
            + (DownloadKeepAlive.insideContainer ? "; LiveContainer" : "") + (sharedGroup ? "; общая папка группы" : ""))
    }
}
