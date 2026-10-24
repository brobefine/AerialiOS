import AVFoundation
import MediaPlayer
import UIKit

/// Загрузка не прерывается, когда приложение свёрнуто, и видна в Dynamic Island.
///
/// iOS усыпляет свёрнутое приложение через полминуты; не трогает она только те, что играют звук (фоновый режим
/// `audio`). Пока идёт загрузка, играет беззвучный звук:
/// - при обычной установке — вперемешку с другими (`mixWithOthers`): музыку не прерывает, а в Dynamic Island
///   загрузку показывает Live Activity ([DownloadLive], виджет `AerialWidgets`);
/// - в LiveContainer виджеты приложения не работают (он запускает Aerial от своего имени), поэтому в фоне звук
///   становится «основным», и загрузка выводится плашкой «Сейчас играет» — как музыка у Endel: название, доля
///   полосой, скорость; пауза в плашке ставит загрузку на паузу.
/// Во время фильма звук играет сам плеер — беззвучный останавливается и возвращается после.
@MainActor
final class DownloadKeepAlive {
    static let shared = DownloadKeepAlive()

    /// Приложение запущено внутри LiveContainer: оно лежит не на системном месте установки, а в документах
    /// самого LiveContainer (`…/Documents/Applications/…`), и LiveContainer ставит свои переменные `LC_*`.
    static let insideContainer: Bool = {
        let path = Bundle.main.bundlePath
        let environment = ProcessInfo.processInfo.environment
        return path.contains("/Documents/") || path.contains("/Data/Application/")
            || environment.keys.contains { $0.hasPrefix("LC_") }
    }()

    private var player: AVAudioPlayer?
    private var job: DownloadJob?
    private var fraction = 0.0
    private var rate: Int64 = 0
    private var background = false
    private var forPlayer = false
    private var commands: [(MPRemoteCommand, Any)] = []
    private var artwork: MPMediaItemArtwork?
    private var shownPlate = false
    private var lastDuration = 1000.0

    var active: Bool { player != nil }

    /// Загрузка пошла или обновилась: звук держит приложение живым, плашка — с долей и скоростью.
    func show(_ job: DownloadJob, fraction: Double, rate: Int64) {
        let changed = self.job?.hash != job.hash
        self.job = job
        self.fraction = fraction
        self.rate = rate
        if player == nil && !forPlayer { start() }
        if changed { loadArtwork(job.item.poster) }
        if shownPlate { publish() }
    }

    /// Очередь кончилась: в плашке остаётся итог («Загружено» или «На паузе»), а не системное «Not Playing».
    func end() {
        if shownPlate, let job {
            let finished = Downloads.shared.complete(Downloads.shared.jobs.first { $0.hash == job.hash } ?? job)
            publish(final: finished ? "Загружено · можно смотреть без сети" : "Загрузка на паузе · откройте Aerial, чтобы продолжить")
        }
        job = nil
        stop(keepInfo: true)
    }

    /// Плеер забирает звук себе — беззвучный встаёт; после фильма продолжается, если загрузка ещё идёт.
    func suspendForPlayer() {
        forPlayer = true
        stop()
    }

    func resumeAfterPlayer() {
        forPlayer = false
        if job != nil { start() }
        if background { enterBackground() }
    }

    func enterBackground() {
        background = true
        guard Self.insideContainer, player != nil, !forPlayer else { return }
        // Плашка «Сейчас играет» достаётся только «основному» звуку — без смешивания.
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
            player?.play()
            showPlate()
        } catch {
            Log.note("ЗАГРУЗКА", "плашка «Сейчас играет»: \(error.localizedDescription)")
        }
    }

    func enterForeground() {
        background = false
        // Плашку не прячем: иначе на экране блокировки оставалось системное «Not Playing». Загрузка в LiveContainer
        // и так уже забрала звук, пока приложение было свёрнуто.
        guard shownPlate, !Self.insideContainer else { return }
        hidePlate()
        // На экране — снова вперемешку: музыка пользователя не должна прерываться из-за загрузки.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        player?.play()
    }

    // MARK: Звук

    private func start() {
        guard player == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(data: Self.silence)
            player.numberOfLoops = -1
            player.volume = 0
            player.play()
            self.player = player
            Log.note("ЗАГРУЗКА", "фоновый звук включён\(Self.insideContainer ? " (LiveContainer: плашка «Сейчас играет»)" : "")")
        } catch {
            Log.note("ЗАГРУЗКА", "фоновый звук: \(error.localizedDescription)")
        }
    }

    private func stop(keepInfo: Bool = false) {
        if keepInfo, shownPlate {
            shownPlate = false
            for (command, target) in commands { command.removeTarget(target) }
            commands = []
        } else {
            hidePlate()
        }
        guard let player else { return }
        player.stop()
        self.player = nil
        if !forPlayer { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        Log.note("ЗАГРУЗКА", "фоновый звук выключен")
    }

    /// Секунда тишины WAV (8 кГц, 16 бит, моно) — без файла в сборке.
    private static let silence: Data = {
        let samples = 8000
        let bytes = samples * 2
        var data = Data()
        func put(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); put(16); put16(1); put16(1); put(8000); put(16000); put16(2); put16(16)
        data.append(contentsOf: Array("data".utf8)); put(UInt32(bytes))
        data.append(Data(count: bytes))
        return data
    }()

    // MARK: Плашка «Сейчас играет»

    private func showPlate() {
        guard !shownPlate else { return }
        shownPlate = true
        let center = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor () -> Void) {
            command.isEnabled = true
            let target = command.addTarget { _ in
                MainActor.assumeIsolated { action() }
                return .success
            }
            commands.append((command, target))
        }
        on(center.togglePlayPauseCommand) { [weak self] in self?.togglePause() }
        on(center.pauseCommand) { [weak self] in self?.setPaused(true) }
        on(center.playCommand) { [weak self] in self?.setPaused(false) }
        publish()
    }

    private func hidePlate() {
        guard shownPlate else { return }
        shownPlate = false
        for (command, target) in commands { command.removeTarget(target) }
        commands = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// Плашка как Live Activity: полоса — доля загрузки. Время на полосе — в секундах загрузки при текущей скорости:
    /// слева — сколько ушло на скачанное, справа «−» — сколько осталось. Пока скорость держится, полоса идёт сама.
    private func publish(final: String? = nil) {
        guard let job else { return }
        let paused = Downloads.shared.jobs.first { $0.hash == job.hash }?.paused ?? false
        let total = Double(max(job.totalBytes, 1))
        let speed = Double(max(rate, 1))
        let duration = rate > 0 ? total / speed : max(lastDuration, 100)
        lastDuration = duration
        let left = rate > 0 ? Format.runtime(minutes: max(1, Int(total * (1 - fraction) / speed / 60))) : ""
        let status = final ?? (paused ? "На паузе · \(Int(fraction * 100)) %"
            : "\(Int(fraction * 100)) % · \(Format.bytes(rate))/с" + (left.isEmpty ? "" : " · осталось \(left)"))
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: final == nil ? "Загрузка: \(job.item.title)" : job.item.title,
            MPMediaItemPropertyArtist: status,
            MPMediaItemPropertyAlbumTitle: "Aerial · загрузки",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: (final == nil ? fraction : 1) * duration,
            MPNowPlayingInfoPropertyPlaybackRate: paused || final != nil ? 0.0 : 1.0,
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func togglePause() {
        guard let job, let current = Downloads.shared.jobs.first(where: { $0.hash == job.hash }) else { return }
        setPaused(!current.paused)
    }

    private func setPaused(_ paused: Bool) {
        guard let job, let current = Downloads.shared.jobs.first(where: { $0.hash == job.hash }) else { return }
        Downloads.shared.pause(current, paused)
        publish()
    }

    private func loadArtwork(_ poster: String) {
        artwork = nil
        Task { [weak self] in
            guard let image = await ImageLoader.shared.image(TMDbImage.urls(poster, "w342"), pixelWidth: 600) else { return }
            self?.artwork = Self.artwork(image)
            if self?.shownPlate == true { self?.publish() }
        }
    }

    private nonisolated static func artwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
