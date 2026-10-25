import Darwin
import Foundation
import MetricKit
import UIKit

/// Замеры производительности и энергии — чтобы по журналам сразу видеть тяжёлые места:
/// - `perf.log` раз в 15 с, пока приложение на экране: загрузка процессора процессом (%), память (МБ), нагрев,
///   заряд и режим энергосбережения, что сейчас идёт (плеер, загрузка);
/// - там же «ЗАТОР» — главный поток не отвечал дольше 250 мс (с тем, что шло в этот момент);
/// - `logs/metrics/` — суточные отчёты MetricKit (процессорное и графическое время, сеть, яркость экрана, зависания)
///   и диагностика падений и зависаний со стеками — iOS присылает их на следующий день.
@MainActor
final class PerfMonitor: NSObject, MXMetricManagerSubscriber {
    static let shared = PerfMonitor()

    /// Что идёт сейчас — подпись к замерам («плеер: …», «загрузка»). Ставят [Playback] и [Downloads].
    nonisolated(unsafe) static var activity = ""
    /// Сторож главного потока спит, пока приложение в фоне: каждое его пробуждение — лишняя трата батареи.
    nonisolated(unsafe) static var foreground = true
    /// Подробности того, что идёт: у плеера — разрешение, кодек, аппаратное ли декодирование.
    nonisolated(unsafe) static var detail = ""
    /// Заторы главного потока за текущее окно сводки.
    nonisolated(unsafe) static var stalls = 0

    /// Окно сводки (1 мин): замеры процессора и сеть в начале.
    private var windowStart = Date()
    private var windowCPU: [Double] = []
    /// Заряд считается с возврата на экран: за минуту он меняется на 0–1 % — скорость в час по окну была бы шумом.
    private var batteryStart = Date()
    private var batteryLevel: Float = -1
    private var windowNet: (wifi: UInt64, cell: UInt64)?
    private var heartbeat: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private var sampler: Task<Void, Never>?
    private var watchdog: Thread?
    private let metrics = Log.directory.appending(path: "metrics", directoryHint: .isDirectory)

    func start() {
        try? FileManager.default.createDirectory(at: metrics, withIntermediateDirectories: true)
        MXMetricManager.shared.add(self)
        UIDevice.current.isBatteryMonitoringEnabled = true
        windowNet = Self.networkBytes()
        startWatchdog()
        resume()
    }

    /// На экране — замеры идут; в фоне — стоят (сам сборщик не должен тратить батарею).
    func resume() {
        heartbeat?.cancel()
        heartbeat = nil
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        Self.foreground = true
        batteryStart = Date()
        batteryLevel = UIDevice.current.batteryLevel
        guard sampler == nil else { return }
        sampler = Task { [weak self] in
            while !Task.isCancelled {
                self?.sample()
                await Self.torrserverLine()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func pause() {
        Self.foreground = false
        sampler?.cancel()
        sampler = nil
        sample(tag: "в фон")
        Self.rememberBackground(seconds: 0)
        let files = Self.openFiles()
        if !files.isEmpty { Log.note("ФАЙЛЫ", "открыты при уходе в фон (🔒 — заблокирован): " + files.joined(separator: ", ")) }
    }

    /// Открытые файлы процесса. Если iOS закрывает уснувшее приложение за блокировку файла (0xdead10cc), виновник —
    /// среди отмеченных 🔒: их держит `flock` (так база bbolt у TorrServer), проверка — попытка взять общий замок.
    nonisolated static func openFiles() -> [String] {
        let home = URL.documentsDirectory.deletingLastPathComponent().path
        var paths = Set<String>()
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        for fd in 0..<getdtablesize() where fcntl(fd, F_GETPATH, &buffer) != -1 {
            let path = String(cString: buffer)
            guard path.hasPrefix("/"), !path.hasPrefix("/dev/") else { continue }
            var locked = false
            let probe = open(path, O_RDONLY | O_NONBLOCK)
            if probe >= 0 {
                if flock(probe, LOCK_SH | LOCK_NB) == 0 { flock(probe, LOCK_UN) } else { locked = errno == EWOULDBLOCK }
                close(probe)
            }
            // F_GETPATH даёт `/private/var/…`, а папка документов — `/var/…`.
            let plain = path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
            let short = plain.hasPrefix(home) ? "~" + plain.dropFirst(home.count) : plain
            paths.insert((locked ? "🔒 " : "") + short)
        }
        return paths.sorted()
    }

    /// Последнее, что известно о свёрнутом приложении: когда ушло в фон, сколько прожило и сколько держало памяти.
    /// Если iOS его выгрузит, следующий запуск напишет это в «ПРОШЛЫЙ ЗАПУСК» ([CrashGuard]).
    nonisolated static let backgroundKey = "session.background"

    private static func rememberBackground(seconds: Int) {
        let since = Date().addingTimeInterval(-Double(seconds))
        UserDefaults.standard.set(String(format: "ушёл в фон %@, жил в фоне ≥ %d с, память %.0f МБ%@",
                                         since.formatted(date: .omitted, time: .standard), seconds, memoryMB(),
                                         activity.isEmpty ? "" : ", \(activity)"), forKey: backgroundKey)
    }

    private func sample(tag: String = "ЗАМЕР") {
        let device = UIDevice.current
        let battery = device.batteryLevel >= 0 ? "\(Int(device.batteryLevel * 100)) %" : "?"
        let charging = device.batteryState == .charging || device.batteryState == .full ? " (заряжается)" : ""
        let thermal = switch ProcessInfo.processInfo.thermalState {
        case .nominal: "норма"
        case .fair: "тёплый"
        case .serious: "горячий"
        case .critical: "критично"
        @unknown default: "?"
        }
        let saver = ProcessInfo.processInfo.isLowPowerModeEnabled ? " · энергосбережение" : ""
        let what = Self.activity.isEmpty ? "" : " · \(Self.activity)"
        let cpu = Self.cpuPercent()
        let detail = Self.detail.isEmpty ? "" : " · \(Self.detail)"
        Log.perf(String(format: "%@ ЦП %.0f %% · память %.0f МБ · нагрев %@ · заряд %@%@%@ · яркость %.0f %%%@%@", tag, cpu,
                        Self.memoryMB(), thermal, battery, charging, saver, UIScreen.main.brightness * 100, what, detail))
        windowCPU.append(cpu)
        if Date().timeIntervalSince(windowStart) >= 60 { summary() }
        let threads = threadBreakdown()
        if !threads.isEmpty { Log.perf("  потоки: " + threads) }
    }

    /// Что делает встроенный TorrServer: раздачи с пирами и скорость — видно, если он качает, пока фильм не идёт.
    private static func torrserverLine() async {
        guard case .running = EmbeddedTorrServer.shared.state,
              let list = try? await EmbeddedTorrServer.shared.client.list() else { return }
        let busy = list.filter { $0.peers > 0 || $0.speed > 0 }
        guard !busy.isEmpty else { return }
        let speed = busy.reduce(Int64(0)) { $0 + $1.speed }
        Log.perf("  TorrServer: раздач с пирами \(busy.count), пиров \(busy.reduce(0) { $0 + $1.peers }), \(Format.bytes(speed))/с")
    }

    // MARK: Сводка за минуту

    /// Средний и пиковый процессор, сеть Wi‑Fi и сотовая, расход заряда и его скорость в час, заторы — по этому видно,
    /// сажает ли приложение батарею и на чём.
    private func summary() {
        let now = Date()
        let minutes = now.timeIntervalSince(windowStart) / 60
        let device = UIDevice.current
        let level = device.batteryLevel
        let charging = device.batteryState == .charging || device.batteryState == .full
        var parts: [String] = []
        if !windowCPU.isEmpty {
            parts.append(String(format: "ЦП в среднем %.0f %%, пик %.0f %%", windowCPU.reduce(0, +) / Double(windowCPU.count),
                                windowCPU.max() ?? 0))
        }
        let net = Self.networkBytes()
        if let start = windowNet, let net {
            let wifi = Double(net.wifi &- start.wifi) / 1_048_576, cell = Double(net.cell &- start.cell) / 1_048_576
            parts.append(String(format: "сеть Wi‑Fi %.0f МБ, сотовая %.0f МБ", wifi, cell))
        }
        let onScreen = now.timeIntervalSince(batteryStart) / 60
        if charging {
            parts.append("на зарядке")
            batteryStart = now
            batteryLevel = -1
        } else if batteryLevel < 0 {
            batteryStart = now
            batteryLevel = level
        } else if level >= 0, onScreen > 0 {
            let used = Double(batteryLevel - level) * 100
            parts.append(String(format: "заряд −%.0f %% за %.0f мин на экране (≈ %.0f %% в час)", used, onScreen, used / onScreen * 60))
        }
        parts.append("заторов \(Self.stalls)")
        Log.perf(String(format: "СВОДКА за %.0f мин: ", minutes) + parts.joined(separator: " · "))
        windowStart = now
        windowCPU = []
        windowNet = net
        Self.stalls = 0
    }

    /// Байты через Wi‑Fi (`en*`) и сотовую (`pdp_ip*`) с включения телефона — по всем приложениям; разница за окно
    /// при открытом Aerial — почти вся его. Счётчики 32-битные — разница с переполнением (`&-`).
    nonisolated static func networkBytes() -> (wifi: UInt64, cell: UInt64)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var wifi: UInt64 = 0, cell: UInt64 = 0
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = pointer {
            defer { pointer = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  let raw = entry.pointee.ifa_data else { continue }
            let data = raw.assumingMemoryBound(to: if_data.self).pointee
            let name = String(cString: entry.pointee.ifa_name)
            let bytes = UInt64(data.ifi_ibytes) + UInt64(data.ifi_obytes)
            if name.hasPrefix("en") { wifi += bytes } else if name.hasPrefix("pdp_ip") { cell += bytes }
        }
        return (wifi, cell)
    }

    // MARK: Фон

    /// После ухода в фон 20 с пишем пульс раз в 2 с: по журналу видно, сколько приложение прожило свёрнутым и что
    /// в это время делало (если его закрыли — пульс обрывается).
    func backgroundHeartbeat() {
        heartbeat?.cancel()
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "perf-heartbeat") { [weak self] in
                MainActor.assumeIsolated {
                    Log.perf("ФОН: iOS забирает время у приложения")
                    if let task = self?.backgroundTask { UIApplication.shared.endBackgroundTask(task) }
                    self?.backgroundTask = .invalid
                }
            }
        }
        heartbeat = Task { [weak self] in
            for second in stride(from: 2, through: 20, by: 2) {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                Log.perf(String(format: "ФОН %d с · ЦП %.0f %% · память %.0f МБ%@", second, Self.cpuPercent(), Self.memoryMB(),
                                Self.activity.isEmpty ? "" : " · \(Self.activity)"))
                Self.rememberBackground(seconds: second)
            }
            guard let self else { return }
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }
    }

    // MARK: Потоки

    /// Время процессора каждого потока на прошлом замере (по номеру потока) и момент замера.
    private var lastThreadTimes: [UInt64: Double] = [:]
    private var lastThreadSample = Date()

    /// Кто ел процессор с прошлого замера: время потоков (user + system), сложенное по именам, в % одного ядра.
    /// Имена: «главный», потоки mpv и libmpv, очереди GCD (сеть, картинки, журнал); безымянные — в основном Go
    /// (TorrServer) — идут как «без имени».
    private func threadBreakdown() -> String {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return "" }
        defer {
            for index in 0..<Int(count) { mach_port_deallocate(mach_task_self_, threads[index]) }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        let now = Date()
        let interval = max(0.5, now.timeIntervalSince(lastThreadSample))
        var times: [UInt64: Double] = [:]
        var byName: [String: Double] = [:]
        for index in 0..<Int(count) {
            let thread = threads[index]
            var basic = thread_basic_info()
            var size = mach_msg_type_number_t(THREAD_INFO_MAX)
            let ok = withUnsafeMutablePointer(to: &basic) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                    thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &size)
                }
            }
            guard ok == KERN_SUCCESS else { continue }
            var ident = thread_identifier_info()
            var identSize = mach_msg_type_number_t(MemoryLayout<thread_identifier_info>.size / MemoryLayout<integer_t>.size)
            let identified = withUnsafeMutablePointer(to: &ident) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(identSize)) {
                    thread_info(thread, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &identSize)
                }
            }
            guard identified == KERN_SUCCESS else { continue }
            let seconds = Double(basic.user_time.seconds + basic.system_time.seconds)
                + Double(basic.user_time.microseconds + basic.system_time.microseconds) / 1_000_000
            times[ident.thread_id] = seconds
            guard let before = lastThreadTimes[ident.thread_id], seconds > before else { continue }
            byName[Self.name(thread), default: 0] += seconds - before
        }
        lastThreadTimes = times
        lastThreadSample = now
        return byName.filter { $0.value / interval >= 0.01 }
            .sorted { $0.value > $1.value }
            .prefix(6)
            .map { String(format: "%@ %.0f %%", $0.key, $0.value / interval * 100) }
            .joined(separator: " · ")
    }

    private static func name(_ thread: thread_act_t) -> String {
        guard let pthread = pthread_from_mach_thread_np(thread) else { return "без имени" }
        if pthread_equal(pthread, pthread_self()) != 0 && Thread.isMainThread { return "главный" }
        var buffer = [CChar](repeating: 0, count: 64)
        pthread_getname_np(pthread, &buffer, buffer.count)
        let name = String(cString: buffer)
        if !name.isEmpty { return name == "main" ? "главный" : name }
        return "без имени (Go, GCD)"
    }

    // MARK: Главный поток

    /// Сторож главного потока: раз в секунду ставит в него метку и смотрит, через сколько она выполнилась.
    private func startWatchdog() {
        let thread = Thread {
            while true {
                if !PerfMonitor.foreground {
                    Thread.sleep(forTimeInterval: 5)
                    continue
                }
                let sent = DispatchTime.now()
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { done.signal() }
                if done.wait(timeout: .now() + 5) == .timedOut {
                    Log.perf("ЗАТОР главный поток не отвечает 5 с · \(PerfMonitor.activity)")
                    done.wait()
                }
                let ms = Double(DispatchTime.now().uptimeNanoseconds - sent.uptimeNanoseconds) / 1_000_000
                if ms > 250 {
                    let state = DispatchQueue.main.sync { UIApplication.shared.applicationState == .active }
                    if state {
                        PerfMonitor.stalls += 1
                        Log.perf(String(format: "ЗАТОР %.0f мс · %@", ms, PerfMonitor.activity))
                    }
                }
                Thread.sleep(forTimeInterval: 1)
            }
        }
        thread.name = "aerial.watchdog"
        thread.qualityOfService = .utility
        thread.start()
        watchdog = thread
    }

    // MARK: MetricKit

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            save(payload.jsonRepresentation(), kind: "metrics", end: payload.timeStampEnd)
            var parts: [String] = []
            if let cpu = payload.cpuMetrics { parts.append("ЦП \(Int(cpu.cumulativeCPUTime.converted(to: .seconds).value)) с") }
            if let gpu = payload.gpuMetrics { parts.append("графика \(Int(gpu.cumulativeGPUTime.converted(to: .seconds).value)) с") }
            if let net = payload.networkTransferMetrics {
                let mb = (net.cumulativeWifiDownload.converted(to: .megabytes).value + net.cumulativeCellularDownload.converted(to: .megabytes).value)
                parts.append("сеть \(Int(mb)) МБ")
            }
            if let display = payload.displayMetrics?.averagePixelLuminance {
                parts.append("яркость \(Int(display.averageMeasurement.value)) APL")
            }
            Log.perf("METRICKIT сутки: " + parts.joined(separator: " · "))
            if let exits = payload.applicationExitMetrics { Self.logExits(exits) }
        }
    }

    /// Почему iOS закрывала приложение за сутки — единственный точный ответ на «выгрузила в фоне»: падения в фоне
    /// не оставляют следов в процессе, а здесь их причины посчитаны системой.
    nonisolated private static func logExits(_ exits: MXAppExitMetric) {
        let back = exits.backgroundExitData
        let background: [(String, Int)] = [
            ("обычно", back.cumulativeNormalAppExitCount),
            ("нехватка памяти у системы (jetsam)", back.cumulativeMemoryPressureExitCount),
            ("превышен лимит памяти", back.cumulativeMemoryResourceLimitExitCount),
            ("лимит ЦП", back.cumulativeCPUResourceLimitExitCount),
            ("блокировка файла во сне (0xdead10cc)", back.cumulativeSuspendedWithLockedFileExitCount),
            ("не закрыта фоновая задача", back.cumulativeBackgroundTaskAssertionTimeoutExitCount),
            ("сторож (завис)", back.cumulativeAppWatchdogExitCount),
            ("падение: доступ к памяти", back.cumulativeBadAccessExitCount),
            ("падение: инструкция", back.cumulativeIllegalInstructionExitCount),
            ("падение: прочее", back.cumulativeAbnormalExitCount),
        ]
        let front = exits.foregroundExitData
        let foreground: [(String, Int)] = [
            ("обычно", front.cumulativeNormalAppExitCount),
            ("превышен лимит памяти", front.cumulativeMemoryResourceLimitExitCount),
            ("сторож (завис)", front.cumulativeAppWatchdogExitCount),
            ("падение: доступ к памяти", front.cumulativeBadAccessExitCount),
            ("падение: инструкция", front.cumulativeIllegalInstructionExitCount),
            ("падение: прочее", front.cumulativeAbnormalExitCount),
        ]
        func line(_ rows: [(String, Int)]) -> String {
            let shown = rows.filter { $0.1 > 0 }.map { "\($0.0) \($0.1)" }
            return shown.isEmpty ? "нет" : shown.joined(separator: ", ")
        }
        Log.note("ДИАГНОСТИКА", "MetricKit, закрытия за сутки — в фоне: \(line(background)); на экране: \(line(foreground))")
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            save(payload.jsonRepresentation(), kind: "diagnostics", end: payload.timeStampEnd)
            let crashes = payload.crashDiagnostics?.count ?? 0
            let hangs = payload.hangDiagnostics?.count ?? 0
            let cpu = payload.cpuExceptionDiagnostics?.count ?? 0
            let disk = payload.diskWriteExceptionDiagnostics?.count ?? 0
            Log.perf("METRICKIT диагностика: падений \(crashes), зависаний \(hangs), перегрузок ЦП \(cpu), записи на диск \(disk)")
            Log.note("ДИАГНОСТИКА", "MetricKit: падений \(crashes), зависаний \(hangs) — подробно в logs/metrics")
            for crash in payload.crashDiagnostics ?? [] {
                let parts = [crash.signal.map { "сигнал \($0)" }, crash.exceptionType.map { "исключение \($0)" },
                             crash.exceptionCode.map { "код \($0)" }, crash.terminationReason].compactMap { $0 }
                Log.note("ДИАГНОСТИКА", "падение \(crash.metaData.applicationBuildVersion): " + parts.joined(separator: " · "))
            }
        }
    }

    private nonisolated func save(_ data: Data, kind: String, end: Date) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let name = "\(kind)-\(formatter.string(from: end).replacingOccurrences(of: ":", with: "-")).json"
        try? data.write(to: Log.directory.appending(path: "metrics").appending(path: name))
    }

    // MARK: Замеры процесса

    /// Загрузка процессора всеми потоками процесса, % одного ядра (как в Xcode).
    nonisolated static func cpuPercent() -> Double {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return 0 }
        defer {
            // Права на потоки тоже возвращаем — иначе каждый замер оставлял их в процессе.
            for index in 0..<Int(count) { mach_port_deallocate(mach_task_self_, threads[index]) }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        var total = 0.0
        for index in 0..<Int(count) {
            var info = thread_basic_info()
            var size = mach_msg_type_number_t(THREAD_INFO_MAX)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                    thread_info(threads[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &size)
                }
            }
            if result == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            }
        }
        return total
    }

    /// Память, которую iOS считает за приложением (`phys_footprint`, как в Xcode), МБ.
    nonisolated static func memoryMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}
