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

    private var sampler: Task<Void, Never>?
    private var watchdog: Thread?
    private let metrics = Log.directory.appending(path: "metrics", directoryHint: .isDirectory)

    func start() {
        try? FileManager.default.createDirectory(at: metrics, withIntermediateDirectories: true)
        MXMetricManager.shared.add(self)
        UIDevice.current.isBatteryMonitoringEnabled = true
        startWatchdog()
        resume()
    }

    /// На экране — замеры идут; в фоне — стоят (сам сборщик не должен тратить батарею).
    func resume() {
        guard sampler == nil else { return }
        sampler = Task { [weak self] in
            while !Task.isCancelled {
                self?.sample()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func pause() {
        sampler?.cancel()
        sampler = nil
        sample(tag: "в фон")
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
        Log.perf(String(format: "%@ ЦП %.0f %% · память %.0f МБ · нагрев %@ · заряд %@%@%@%@", tag, Self.cpuPercent(),
                        Self.memoryMB(), thermal, battery, charging, saver, what))
    }

    // MARK: Главный поток

    /// Сторож главного потока: раз в секунду ставит в него метку и смотрит, через сколько она выполнилась.
    private func startWatchdog() {
        let thread = Thread {
            while true {
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
                    if state { Log.perf(String(format: "ЗАТОР %.0f мс · %@", ms, PerfMonitor.activity)) }
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
        }
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
