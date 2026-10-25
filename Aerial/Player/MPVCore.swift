import Foundation
import Libmpv
import QuartzCore
import UIKit

/// Слой Metal для mpv (`vo=gpu-next` через MoltenVK), как в демо MPVKit: MoltenVK на миг ставит размер 1×1,
/// чтобы досрочно завершить показ, — от этого мерцание и залипший размер. Такие размеры не принимаем.
final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 { super.drawableSize = newValue }
        }
    }
}

struct MPVTrack: Identifiable, Hashable, Sendable {
    var id: Int
    var type: String
    var title: String
    var lang: String
    var codec: String
    var selected: Bool

    var label: String {
        let language = Locale(identifier: "ru_RU").localizedString(forLanguageCode: lang).map { $0.capitalized } ?? lang.uppercased()
        let parts = [title, language.isEmpty ? "" : language, codec.uppercased()].filter { !$0.isEmpty }
        return parts.isEmpty ? L("Дорожка %@", "\(id)") : parts.joined(separator: " · ")
    }
}

enum MPVEvent: Sendable {
    case time(Double)
    case duration(Double)
    case paused(Bool)
    case buffering(Bool)
    case cache(Double)
    case fileLoaded
    case tracks([MPVTrack])
    case ended(error: String?)
}

/// Ядро mpv (libmpv из MPVKit) без UIKit: свой поток событий, команды из любого потока (API mpv потокобезопасен),
/// события — на главный поток через [onEvent]. [destroy] обязателен до освобождения.
final class MPVCore: @unchecked Sendable {
    private(set) var handle: OpaquePointer?
    private var layer: MPVMetalLayer
    private let queue = DispatchQueue(label: "aerial.mpv.events", qos: .userInitiated)
    var onEvent: (@MainActor (MPVEvent) -> Void)?

    init(layer: MPVMetalLayer) {
        self.layer = layer
        guard let handle = mpv_create() else {
            Log.player("mpv_create не удался")
            return
        }
        self.handle = handle
        mpv_request_log_messages(handle, "info")
        // Вывод в наш слой: mpv ждёт адрес объекта CAMetalLayer числом (как в демо MPVKit).
        check(mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &self.layer), "wid")
        let options: [(String, String)] = [
            // `fast` — простое масштабирование без тяжёлых шейдеров: на экране телефона разницы почти нет, батарея целее.
            ("profile", "fast"),
            ("vo", "gpu-next"), ("gpu-api", "vulkan"), ("gpu-context", "moltenvk"),
            ("hwdec", "videotoolbox"), ("video-rotate", "no"),
            ("keep-open", "yes"), ("idle", "yes"),
            // Поток с TorrServer: держим запас вперёд, сеть ждём долго — раздача может замереть на минуту.
            // Запас mpv — поверх кэша TorrServer в том же процессе (256 МБ): при 150+50 МБ плеер доходил до 650 МБ
            // памяти (perf.log 24 октября). 64+16 МБ — это минуты видео, остальное держит сервер.
            ("cache", "yes"), ("demuxer-max-bytes", "64MiB"), ("demuxer-max-back-bytes", "16MiB"),
            ("demuxer-readahead-secs", "30"), ("network-timeout", "90"),
            ("alang", "ru,rus,en,eng"), ("slang", "ru,rus,en,eng"), ("subs-fallback", "yes"),
            ("input-default-bindings", "no"), ("input-vo-keyboard", "no"),
        ]
        for (name, value) in options { check(mpv_set_option_string(handle, name, value), name) }
        check(mpv_initialize(handle), "initialize")
        mpv_observe_property(handle, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 0, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 0, "demuxer-cache-duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 0, "track-list", MPV_FORMAT_NONE)
        mpv_set_wakeup_callback(handle, { context in
            guard let context else { return }
            Unmanaged<MPVCore>.fromOpaque(context).takeUnretainedValue().drain()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit { destroy() }

    // MARK: Команды

    func load(_ url: URL, start: Double, title: String) {
        guard let handle else { return }
        if start > 0 { mpv_set_property_string(handle, "start", String(format: "%.1f", start)) }
        mpv_set_property_string(handle, "force-media-title", title)
        command(["loadfile", url.isFileURL ? url.path : url.absoluteString, "replace"])
    }

    func setPaused(_ paused: Bool) {
        guard let handle else { return }
        var flag: Int32 = paused ? 1 : 0
        mpv_set_property(handle, "pause", MPV_FORMAT_FLAG, &flag)
    }

    func seek(to seconds: Double) { command(["seek", String(format: "%.2f", seconds), "absolute"]) }
    func seek(by seconds: Double) { command(["seek", String(format: "%.2f", seconds), "relative"]) }
    func selectAudio(_ id: Int) { set("aid", String(id)) }
    func setSpeed(_ value: Double) { set("speed", String(format: "%.2f", value)) }
    /// Внешний файл субтитров — сразу включённым.
    func addSubtitle(_ file: URL) { command(["sub-add", file.path, "select"]) }
    func selectSubtitle(_ id: Int?) { set("sid", id.map(String.init) ?? "no") }
    /// В фоне видео выключаем — звук играет дальше, а при возврате не бывает чёрного экрана (как в демо MPVKit).
    /// Для журнала батареи: «1920×1080 hevc · аппаратно (videotoolbox)» или «… · программно».
    func videoSummary() -> String {
        let width = string("video-params/w") ?? "?", height = string("video-params/h") ?? "?"
        let codec = string("video-codec-name") ?? string("video-format") ?? "?"
        let hw = string("hwdec-current") ?? "no"
        return "\(width)×\(height) \(codec) · " + (hw == "no" || hw.isEmpty ? "программно" : "аппаратно (\(hw))")
    }

    func setVideoEnabled(_ enabled: Bool) { set("vid", enabled ? "auto" : "no") }

    /// Размер вывода сменился (поворот). Контекст MoltenVK в сборке MPVKit (патч `0001-player-add-moltenvk-context`)
    /// не сообщает mpv о смене размера (`control` — `VO_NOTIMPL`) и читает `drawableSize` слоя только при перенастройке
    /// вывода. Без неё после поворота mpv рисовал в прежний размер — видео в углу, обрезано или за краями экрана.
    /// Перенастройка — выключить и включить видеодорожку (так же видео возвращается после фона).
    func refreshVideo() {
        set("vid", "no")
        set("vid", "auto")
    }

    func destroy() {
        guard let handle else { return }
        self.handle = nil
        mpv_set_wakeup_callback(handle, nil, nil)
        let retained = self.layer
        // Завершение ждёт потоки воспроизведения — не на главном потоке; слой живёт, пока mpv его отпускает.
        queue.async {
            mpv_terminate_destroy(handle)
            _ = retained
        }
    }

    private func set(_ name: String, _ value: String) {
        guard let handle else { return }
        check(mpv_set_property_string(handle, name, value), name)
    }

    private func command(_ args: [String]) {
        guard let handle else { return }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) } + [nil]
        defer { for pointer in cargs where pointer != nil { free(UnsafeMutablePointer(mutating: pointer)) } }
        check(mpv_command(handle, &cargs), args.first ?? "")
    }

    private func check(_ status: Int32, _ what: String) {
        if status < 0 { Log.player("ошибка mpv (\(what)): \(String(cString: mpv_error_string(status)))") }
    }

    // MARK: События

    private func drain() {
        queue.async { [weak self] in
            guard let self else { return }
            while let handle = self.handle, let event = mpv_wait_event(handle, 0)?.pointee, event.event_id != MPV_EVENT_NONE {
                self.process(event)
            }
        }
    }

    private func process(_ event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let data = event.data else { return }
            let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
            guard let cName = property.name else { return }
            let name = String(cString: cName)
            if property.format == MPV_FORMAT_NONE {
                if name == "track-list" { post(.tracks(tracks())) }
                return
            }
            guard let value = property.data else { return }
            switch (name, property.format) {
            case ("time-pos", MPV_FORMAT_DOUBLE): post(.time(value.assumingMemoryBound(to: Double.self).pointee))
            case ("duration", MPV_FORMAT_DOUBLE): post(.duration(value.assumingMemoryBound(to: Double.self).pointee))
            case ("demuxer-cache-duration", MPV_FORMAT_DOUBLE): post(.cache(value.assumingMemoryBound(to: Double.self).pointee))
            case ("pause", MPV_FORMAT_FLAG): post(.paused(value.assumingMemoryBound(to: Int32.self).pointee != 0))
            case ("paused-for-cache", MPV_FORMAT_FLAG): post(.buffering(value.assumingMemoryBound(to: Int32.self).pointee != 0))
            default: break
            }
        case MPV_EVENT_FILE_LOADED:
            post(.fileLoaded)
            post(.tracks(tracks()))
        case MPV_EVENT_END_FILE:
            guard let data = event.data else { return }
            let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            if end.reason == MPV_END_FILE_REASON_ERROR {
                let message = String(cString: mpv_error_string(end.error))
                Log.player("конец файла с ошибкой: \(message)")
                post(.ended(error: message))
            } else if end.reason == MPV_END_FILE_REASON_EOF {
                post(.ended(error: nil))
            }
        case MPV_EVENT_LOG_MESSAGE:
            guard let data = event.data else { return }
            let message = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
            let prefix = message.prefix.map { String(cString: $0) } ?? ""
            let level = message.level.map { String(cString: $0) } ?? ""
            let text = message.text.map { String(cString: $0) } ?? ""
            Log.player("[\(prefix)] \(level): \(text)")
        default:
            break
        }
    }

    private func tracks() -> [MPVTrack] {
        guard let handle else { return [] }
        var count: Int64 = 0
        mpv_get_property(handle, "track-list/count", MPV_FORMAT_INT64, &count)
        return (0..<max(0, Int(count))).compactMap { index in
            let type = string("track-list/\(index)/type") ?? ""
            guard type == "audio" || type == "sub" else { return nil }
            var id: Int64 = 0
            mpv_get_property(handle, "track-list/\(index)/id", MPV_FORMAT_INT64, &id)
            var selected: Int32 = 0
            mpv_get_property(handle, "track-list/\(index)/selected", MPV_FORMAT_FLAG, &selected)
            return MPVTrack(id: Int(id), type: type, title: string("track-list/\(index)/title") ?? "",
                            lang: string("track-list/\(index)/lang") ?? "", codec: string("track-list/\(index)/codec") ?? "",
                            selected: selected != 0)
        }
    }

    private func string(_ name: String) -> String? {
        guard let handle, let value = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(value) }
        return String(cString: value)
    }

    private func post(_ event: MPVEvent) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onEvent?(event) }
        }
    }
}

/// Хозяин слоя видео в иерархии UIKit: растягивает слой на весь вид.
final class MPVViewController: UIViewController {
    let metalLayer: MPVMetalLayer
    /// Слой сменил размер — плеер перестраивает картинку.
    var onResize: (() -> Void)?
    private var lastSize = CGSize.zero
    private var rotating = false
    private var settle: DispatchWorkItem?

    init(layer: MPVMetalLayer) {
        metalLayer = layer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        view.layer.addSublayer(metalLayer)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Масштаб — экрана, на котором вид (до появления в окне `traitCollection` ещё не знает его и даёт 1).
        let scale = view.window?.screen.nativeScale ?? UIScreen.main.nativeScale
        metalLayer.contentsScale = scale
        metalLayer.frame = view.bounds
        // Размер кадра сам за поворотом не идёт: видео оставалось в углу размером с книжную ориентацию.
        let size = CGSize(width: (view.bounds.width * scale).rounded(), height: (view.bounds.height * scale).rounded())
        metalLayer.drawableSize = size
        CATransaction.commit()
        // Размер сменился не поворотом (окно на iPad) — перенастройка после того, как размер успокоится.
        if size != lastSize, size.width > 1, size.height > 1 {
            let first = lastSize == .zero
            lastSize = size
            guard !first, !rotating else { return }
            settle?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.onResize?() }
            settle = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        // Поворот: перенастройка один раз — после анимации, с окончательным размером.
        rotating = true
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self else { return }
            rotating = false
            view.setNeedsLayout()
            view.layoutIfNeeded()
            settle?.cancel()
            onResize?()
        }
    }
}
