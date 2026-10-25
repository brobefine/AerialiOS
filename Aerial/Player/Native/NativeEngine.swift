import AVFoundation
import Foundation
import UIKit

/// Что плееру нужно от движка: mpv ([MPVCore]) или системный AVPlayer ([NativeEngine]). События — [MPVEvent].
@MainActor
protocol PlayerEngine: AnyObject {
    var onEvent: (@MainActor (MPVEvent) -> Void)? { get set }
    func load(_ url: URL, start: Double, title: String)
    func setPaused(_ paused: Bool)
    func seek(to seconds: Double)
    func seek(by seconds: Double)
    func selectAudio(_ id: Int)
    func setSpeed(_ value: Double)
    func addSubtitle(_ file: URL)
    func selectSubtitle(_ id: Int?)
    func videoSummary() -> String
    func setVideoEnabled(_ enabled: Bool)
    func refreshVideo()
    func destroy()
}

extension MPVCore: PlayerEngine {}

/// Системный плеер: AVPlayer играет MKV через перепаковку в HLS ([HLSSession]) или MP4/MOV напрямую. Видео идёт
/// путём Apple (VideoToolbox → слой показа), с настоящим HDR и Dolby Vision; батареи — заметно меньше, чем у mpv.
/// Не вышло открыть (кодек, нет индекса MKV) — событие `.fallback`, и плеер переходит на mpv.
@MainActor
final class NativeEngine: PlayerEngine {
    var onEvent: (@MainActor (MPVEvent) -> Void)?
    let player = AVPlayer()
    let layer: AVPlayerLayer
    /// Что играет AVPlayer — его же откроет окно PiP.
    private(set) var playbackURL: URL?

    private var session: HLSSession?
    private var source: URL?
    private var title = ""
    private var audioStream: Int32?
    private var userPaused = false
    private var started = false
    private var loaded = false
    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    private var subtitleTracks: [Int: [Remuxer.Cue]] = [:]
    private var subtitleNames: [Int: (title: String, lang: String)] = [:]
    private var subtitle: Int?
    private var shownCue: String?
    private var opening: Task<Void, Never>?
    private var destroyed = false

    init() {
        layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
        player.preventsDisplaySleepDuringVideoPlayback = true
    }

    /// Подходит ли файл системному плееру (иначе — сразу mpv).
    static func accepts(fileName: String) -> Bool {
        ["mkv", "mp4", "m4v", "mov"].contains((fileName as NSString).pathExtension.lowercased())
    }

    func load(_ url: URL, start: Double, title: String) {
        source = url
        self.title = title
        open(at: start, autoplay: true)
    }

    private func open(at start: Double, autoplay: Bool) {
        guard let source else { return }
        opening?.cancel()
        let previous = session
        let audio = audioStream
        let direct = ["mp4", "m4v", "mov"].contains(source.pathExtension.lowercased())
            || ["mp4", "m4v", "mov"].contains((source.lastPathComponent as NSString).pathExtension.lowercased())
        opening = Task { [weak self] in
            do {
                let url: URL
                var opened: HLSSession?
                if direct {
                    url = source
                } else {
                    let session = try await HLSSession.open(url: source, audioStream: audio, start: start)
                    opened = session
                    url = session.masterURL
                }
                guard let self, !Task.isCancelled, !destroyed else {
                    opened?.close()
                    return
                }
                previous?.release()
                session = opened
                if let opened { describe(opened.remuxer) }
                play(url, start: direct ? start : 0, autoplay: autoplay)
            } catch {
                guard let self, !Task.isCancelled, !destroyed else { return }
                Log.player("системный плеер: \(error.localizedDescription)")
                onEvent?(.fallback(error.localizedDescription))
            }
        }
    }

    /// Дорожки MKV и уже найденные реплики субтитров.
    private func describe(_ remuxer: Remuxer) {
        audioStream = remuxer.audio.map(\.stream)
        for track in remuxer.textTracks where subtitleNames[Int(track.stream)] == nil {
            subtitleNames[Int(track.stream)] = (track.title, track.lang)
        }
        let info = remuxer.audio.map { "\($0.codec)\($0.copy ? "" : " → AAC")" } ?? "без звука"
        Log.player(String(format: "системный плеер: %@ %ldx%ld %@, %ld отрезков, звук %@", remuxer.videoCodec, remuxer.width,
                          remuxer.height, remuxer.videoRange, remuxer.segments.count, info))
    }

    private func play(_ url: URL, start: Double, autoplay: Bool) {
        playbackURL = url
        let item = AVPlayerItem(url: url)
        // Запас вперёд — полминуты: дальше AVPlayer не тянет поток (TorrServer качает, пока читают).
        item.preferredForwardBufferDuration = 30
        clearObservers()
        player.replaceCurrentItem(with: item)
        if start > 0 { player.seek(to: CMTime(seconds: start, preferredTimescale: 600)) }
        observe(item)
        userPaused = !autoplay
        if autoplay { player.play() }
    }

    private func observe(_ item: AVPlayerItem) {
        let interval = CMTime(seconds: subtitle == nil ? 0.5 : 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        observations = [
            item.observe(\.status, options: [.new]) { [weak self] item, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.statusChanged(item) } }
            },
            player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.controlChanged(player.timeControlStatus) } }
            },
        ]
        let center = NotificationCenter.default
        notifications = [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onEvent?(.ended(error: nil)) }
            },
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] note in
                let error = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "?"
                MainActor.assumeIsolated { self?.onEvent?(.ended(error: error)) }
            },
        ]
    }

    private func clearObservers() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        observations = []
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
        notifications = []
    }

    private func statusChanged(_ item: AVPlayerItem) {
        switch item.status {
        case .readyToPlay:
            let seconds = item.duration.seconds
            if seconds.isFinite, seconds > 0 { onEvent?(.duration(seconds)) }
            if !loaded {
                loaded = true
                onEvent?(.fileLoaded)
            }
            onEvent?(.tracks(tracks()))
        case .failed:
            let message = item.error?.localizedDescription ?? "?"
            Log.player("AVPlayer: \(message) \((item.error as NSError?)?.userInfo ?? [:])")
            // Не пошло с самого начала — пусть играет mpv; сломалось посреди — как ошибка.
            onEvent?(started ? .ended(error: message) : .fallback(message))
        default:
            break
        }
    }

    private func controlChanged(_ status: AVPlayer.TimeControlStatus) {
        switch status {
        case .playing:
            onEvent?(.buffering(false))
            onEvent?(.paused(false))
        case .waitingToPlayAtSpecifiedRate:
            onEvent?(.buffering(true))
        case .paused:
            onEvent?(.buffering(false))
            onEvent?(.paused(userPaused))
        @unknown default:
            break
        }
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        if seconds > 0 { started = true }
        onEvent?(.time(seconds))
        updateSubtitle(at: seconds)
    }

    // MARK: Субтитры

    private func updateSubtitle(at seconds: Double) {
        var text: String?
        if let subtitle {
            text = cues(for: subtitle).last { $0.start <= seconds && seconds < $0.end }?.text
        }
        if text != shownCue {
            shownCue = text
            onEvent?(.subtitle(text))
        }
    }

    private func cues(for id: Int) -> [Remuxer.Cue] {
        if let external = subtitleTracks[id] { return external }
        // Реплики MKV копятся по мере перепаковки — снимок под замком перепаковщика.
        return session?.remuxer.cues(for: Int32(id)) ?? []
    }

    // MARK: Команды

    func setPaused(_ paused: Bool) {
        userPaused = paused
        if paused { player.pause() } else { player.play() }
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seek(by seconds: Double) {
        let now = player.currentTime().seconds
        guard now.isFinite else { return }
        player.seek(to: CMTime(seconds: max(0, now + seconds), preferredTimescale: 600),
                    toleranceBefore: CMTime(seconds: 0.5, preferredTimescale: 600), toleranceAfter: CMTime(seconds: 0.5, preferredTimescale: 600))
    }

    /// Другая озвучка — новый сеанс перепаковки с этой дорожкой, с того же места (у MP4 — выбор дорожки AVPlayer).
    func selectAudio(_ id: Int) {
        if session == nil {
            guard let item = player.currentItem, let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible),
                  group.options.indices.contains(id) else { return }
            item.select(group.options[id], in: group)
            onEvent?(.tracks(tracks()))
            return
        }
        guard Int32(id) != audioStream else { return }
        audioStream = Int32(id)
        let position = player.currentTime().seconds
        Log.player("системный плеер: звук → поток \(id) с \(Int(position)) с")
        open(at: position.isFinite ? position : 0, autoplay: !userPaused)
    }

    func setSpeed(_ value: Double) {
        player.defaultRate = Float(value)
        if !userPaused { player.rate = Float(value) }
    }

    func addSubtitle(_ file: URL) {
        guard let text = (try? String(contentsOf: file, encoding: .utf8)) ?? (try? String(contentsOf: file, encoding: .windowsCP1251)) else {
            return
        }
        let id = 10_000 + subtitleTracks.count
        subtitleTracks[id] = SRT.parse(text)
        subtitleNames[id] = (file.deletingPathExtension().lastPathComponent, "")
        selectSubtitle(id)
    }

    func selectSubtitle(_ id: Int?) {
        subtitle = id
        if let item = player.currentItem {
            // Частота часов: с субтитрами — 4 раза в секунду, без — 2.
            clearObservers()
            observe(item)
        }
        updateSubtitle(at: player.currentTime().seconds)
        onEvent?(.tracks(tracks()))
    }

    func videoSummary() -> String {
        guard let remuxer = session?.remuxer else { return "AVPlayer · аппаратно (напрямую)" }
        return "\(remuxer.width)×\(remuxer.height) \(remuxer.videoCodec) \(remuxer.videoRange) · аппаратно (AVPlayer)"
    }

    /// В фоне слой отвязываем — звук играет дальше, а видео не декодируется зря.
    func setVideoEnabled(_ enabled: Bool) {
        layer.player = enabled ? player : nil
    }

    func refreshVideo() {}

    func destroy() {
        destroyed = true
        opening?.cancel()
        clearObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
        session?.release()
        session = nil
    }

    private func tracks() -> [MPVTrack] {
        var list: [MPVTrack] = []
        if let remuxer = session?.remuxer {
            list += remuxer.audioTracks.map {
                MPVTrack(id: Int($0.stream), type: "audio", title: $0.title, lang: $0.lang, codec: $0.codec, selected: $0.stream == audioStream)
            }
        } else if let item = player.currentItem, let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible) {
            let selected = item.currentMediaSelection.selectedMediaOption(in: group)
            list += group.options.enumerated().map { index, option in
                MPVTrack(id: index, type: "audio", title: option.displayName, lang: option.extendedLanguageTag ?? "", codec: "",
                         selected: option == selected)
            }
        }
        list += subtitleNames.keys.sorted().map { id in
            let name = subtitleNames[id] ?? ("", "")
            return MPVTrack(id: id, type: "sub", title: name.title, lang: name.lang, codec: "", selected: id == subtitle)
        }
        return list
    }
}

/// Субтитры SubRip из файла (OpenSubtitles): номер, время «чч:мм:сс,мс --> …», текст.
enum SRT {
    static func parse(_ text: String) -> [Remuxer.Cue] {
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        return blocks.compactMap { block in
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let bounds = lines[timing].components(separatedBy: "-->")
            guard bounds.count == 2, let start = seconds(bounds[0]), let end = seconds(bounds[1]) else { return nil }
            let body = SubtitleText.clean(lines[(timing + 1)...].joined(separator: "\n"), ass: false)
            return body.isEmpty ? nil : Remuxer.Cue(start: start, end: end, text: body)
        }.sorted { $0.start < $1.start }
    }

    static func seconds(_ value: String) -> Double? {
        let parts = value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count == 3, let hours = Double(parts[0]), let minutes = Double(parts[1]),
              let rest = Double(parts[2].split(separator: " ").first ?? "") else { return nil }
        return hours * 3600 + minutes * 60 + rest
    }
}

/// Слой AVPlayer в иерархии SwiftUI.
final class NativeVideoHost: UIView {
    let playerLayer: AVPlayerLayer

    init(layer: AVPlayerLayer) {
        playerLayer = layer
        super.init(frame: .zero)
        backgroundColor = .black
        self.layer.addSublayer(layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}
