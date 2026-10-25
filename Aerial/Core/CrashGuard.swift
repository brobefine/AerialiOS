import Darwin
import Foundation

/// Как кончился прошлый запуск и падения этого.
/// - Сигналы падения (SIGSEGV, SIGABRT…) и исключения Objective-C пишутся в `logs/crash.log` прямо в обработчике —
///   `write` в заранее открытый файл, без выделения памяти.
/// - Запуск помнит, где был: «на экране», «в фоне», «закрыт». Если прошлый кончился «в фоне» без записи о падении —
///   его выгрузила система (нехватка памяти, сторож iOS, блокировка файла в общей папке при засыпании).
/// - Подробности от системы (стек, причина) приходят через MetricKit на следующий день — `logs/metrics/`.
enum CrashGuard {
    private static let stateKey = "session.state"
    nonisolated(unsafe) private static var fd: Int32 = -1

    static func start() {
        let previous = UserDefaults.standard.string(forKey: stateKey) ?? ""
        let crashFile = Log.directory.appending(path: "crash.log")
        let crashed = (try? String(contentsOf: crashFile, encoding: .utf8)).map { !$0.isEmpty } ?? false
        let exitMarker = Log.directory.appending(path: "exit.marker")
        let exited = FileManager.default.fileExists(atPath: exitMarker.path)
        try? FileManager.default.removeItem(at: exitMarker)
        switch previous {
        case _ where exited:
            // `exit()` зовёт не iOS (та убивает без него), а код в процессе — так LiveContainer перезапускает
            // приложение, когда его открывают ярлыком или из списка LiveContainer.
            Log.note("ПРОШЛЫЙ ЗАПУСК", "завершён вызовом exit() в состоянии «\(previous)» — закрыл код в процессе (LiveContainer?), не iOS")
        case "background" where !crashed:
            let last = UserDefaults.standard.string(forKey: PerfMonitor.backgroundKey).map { "; \($0)" } ?? ""
            Log.note("ПРОШЛЫЙ ЗАПУСК", "закрыт в фоне без падения — выгрузила система (память, сторож или блокировка файла)\(last)")
        case "active" where !crashed:
            Log.note("ПРОШЛЫЙ ЗАПУСК", "оборвался на экране без записи о падении (сторож iOS или убит)")
        default:
            if crashed { Log.note("ПРОШЛЫЙ ЗАПУСК", "упал — см. crash.log") }
        }
        // Прошлое падение — в crash.log.1, новый файл открыт заранее для обработчиков сигналов.
        let old = crashFile.appendingPathExtension("1")
        if crashed {
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: crashFile, to: old)
        }
        fd = open(crashFile.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        CrashGuardFD.value = fd
        // Только SIGABRT (abort, исключения) и SIGTRAP (падения Swift). SIGSEGV, SIGBUS, SIGFPE не трогаем: ими пользуется
        // Go внутри TorrServer (ловит свои ошибки и превращает в panic) — чужой обработчик ломал бы ему это.
        // Падения самого Go пишутся в журнал TorrServer (`torrserver.log`).
        for signal in [SIGABRT, SIGTRAP] {
            Darwin.signal(signal, crashSignal)
        }
        NSSetUncaughtExceptionHandler { exception in
            CrashGuard.write("ИСКЛЮЧЕНИЕ \(exception.name.rawValue): \(exception.reason ?? "")\n"
                + exception.callStackSymbols.prefix(30).joined(separator: "\n") + "\n")
        }
        // Выход через exit(): отметка файлом (обработчик atexit — без UserDefaults, только write).
        exitFD = open(exitMarker.path + ".pending", O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        CrashGuardFD.exitPath = strdup(exitMarker.path)
        CrashGuardFD.pendingPath = strdup(exitMarker.path + ".pending")
        atexit(exitHandler)
        let environment = ProcessInfo.processInfo.environment.keys.filter { $0.hasPrefix("LC_") }.sorted()
        if !environment.isEmpty { Log.note("ЗАПУСК", "переменные LiveContainer: \(environment.joined(separator: ", "))") }
        mark("active")
    }

    nonisolated(unsafe) private static var exitFD: Int32 = -1

    /// «active», «background» или «terminated».
    static func mark(_ state: String) {
        UserDefaults.standard.set(state, forKey: stateKey)
    }

    fileprivate static func write(_ text: String) {
        guard fd >= 0 else { return }
        text.utf8CString.withUnsafeBufferPointer { buffer in
            _ = Darwin.write(fd, buffer.baseAddress, max(0, buffer.count - 1))
        }
    }
}

/// Обработчик сигнала: только безопасные вызовы — номер сигнала в файл и стандартная обработка (падение).
private func crashSignal(_ signal: Int32) {
    var text: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0x53, 0x49, 0x47, 0x4E, 0x41, 0x4C, 0x20, 0x30 + UInt8(signal / 10), 0x30 + UInt8(signal % 10), 0x0A, 0, 0, 0, 0, 0, 0)
    withUnsafeBytes(of: &text) { _ = write(CrashGuardFD.value, $0.baseAddress, 10) }
    Darwin.signal(signal, SIG_DFL)
    raise(signal)
}

/// Номер файла для обработчика сигнала (глобальная функция не видит закрытые поля [CrashGuard]).
enum CrashGuardFD {
    nonisolated(unsafe) static var value: Int32 = -1
    nonisolated(unsafe) static var exitPath: UnsafeMutablePointer<CChar>?
    nonisolated(unsafe) static var pendingPath: UnsafeMutablePointer<CChar>?
}

/// Процесс завершается через exit(): переименовать заготовленный файл-отметку — следующий запуск увидит, кто закрыл.
private func exitHandler() {
    guard let pending = CrashGuardFD.pendingPath, let path = CrashGuardFD.exitPath else { return }
    rename(pending, path)
}
