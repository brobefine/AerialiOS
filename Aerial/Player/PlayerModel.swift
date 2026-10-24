import AVFoundation
import Foundation
import Observation
import SwiftUI
import UIKit

/// Что смотреть: раздача и, если уже известен, файл в ней. Без файла плеер выбирает сам ([EpisodeMatch.pick]).
struct PlaybackRequest: Identifiable {
    let id = UUID()
    var item: VodItem
    var episode: VodEpisode?
    var link: String
    var fileIndex: Int?
    var releaseTitle: String
    var startAt: Double = 0
    var runtimeMinutes: Int = 0
    /// Писать ли прогресс в медиатеку (проверка воспроизведения на CI — нет).
    var record = true

    var title: String { item.title }
    var subtitle: String {
        guard let episode else { return item.year }
        return "Сезон \(episode.season), серия \(episode.number) · \(episode.title)"
    }
}

/// Показ полноэкранного плеера. Плеер показывается через UIKit, как системный: его контроллер сам объявляет альбомную
/// ориентацию, и iOS поворачивает экран при показе. Запрос поворота из окна SwiftUI (`fullScreenCover`) iOS отклоняла.
@MainActor @Observable
final class Playback {
    private(set) var request: PlaybackRequest?
    @ObservationIgnored private weak var settings: AppSettings?
    @ObservationIgnored private weak var library: Library?
    @ObservationIgnored private var controller: UIViewController?

    func attach(settings: AppSettings, library: Library) {
        self.settings = settings
        self.library = library
    }

    func play(_ request: PlaybackRequest) {
        guard controller == nil, let settings, let library, let presenter = Self.topController() else { return }
        self.request = request
        Orientation.allowLandscape(true)
        let view = PlayerView(request: request) { [weak self] in self?.close() }
            .environment(settings)
            .environment(library)
            .environment(self)
        let host = PlayerHostingController(rootView: AnyView(view))
        host.modalPresentationStyle = .fullScreen
        controller = host
        presenter.present(host, animated: true)
    }

    func close() {
        guard let controller else { return }
        self.controller = nil
        controller.dismiss(animated: true) { [weak self] in
            Orientation.allowLandscape(false)
            self?.request = nil
        }
    }

    /// «Продолжить»: раздача и файл уже известны, позиция — из медиатеки.
    func resume(_ entry: WatchEntry) {
        guard let source = entry.source else { return }
        play(PlaybackRequest(item: entry.item, episode: entry.episode, link: source.link, fileIndex: source.fileIndex,
                             releaseTitle: source.releaseTitle, startAt: entry.resumable ? entry.position : 0,
                             runtimeMinutes: Int(entry.duration / 60)))
    }

    private static func topController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.keyWindow?.rootViewController ?? scene?.windows.first?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

/// Контроллер плеера: на iPhone — только альбомная ориентация (открывается повёрнутым), без строки состояния
/// и полоски «домой»; на iPad — как держат.
final class PlayerHostingController: UIHostingController<AnyView> {
    private var phone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { phone ? .landscape : .all }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        phone ? .landscapeRight : super.preferredInterfaceOrientationForPresentation
    }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
}

/// Ход просмотра: TorrServer → подкачка начала → mpv; прогресс пишется в медиатеку каждые 5 с и при закрытии.
@MainActor @Observable
final class PlayerModel {
    enum Phase: Equatable {
        case connecting(String)
        case preloading(Double)
        case playing
        case failed(String)
    }

    let request: PlaybackRequest
    let layer = MPVMetalLayer()
    private(set) var phase: Phase = .connecting("Запускаю TorrServer…")
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var paused = false
    private(set) var buffering = false
    private(set) var started = false
    private(set) var finished = false
    private(set) var audioTracks: [MPVTrack] = []
    private(set) var subtitleTracks: [MPVTrack] = []
    private(set) var peers = 0
    private(set) var speed: Int64 = 0

    @ObservationIgnored private var core: MPVCore?
    @ObservationIgnored private var library: Library?
    @ObservationIgnored private var client: TorrServerClient?
    @ObservationIgnored private var source: WatchSource?
    @ObservationIgnored private var stats: Task<Void, Never>?
    @ObservationIgnored private var lastSaved = Date.distantPast
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    private let nowPlaying = NowPlaying()
    @ObservationIgnored private var nowPlayingUpdated = Date.distantPast

    init(request: PlaybackRequest) {
        self.request = request
    }

    func start(settings: AppSettings, library: Library) async {
        self.library = library
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
        UIApplication.shared.isIdleTimerDisabled = true
        observeLifecycle()
        do {
            let client = try await Torrents.client(settings)
            self.client = client
            phase = .connecting("Получаю раздачу…")
            let poster = TMDbImage.urls(request.item.poster, "w342").first?.absoluteString ?? ""
            var info = try await client.add(link: request.link, title: request.item.title, poster: poster)
            phase = .connecting("Жду список файлов…")
            info = try await client.awaitFiles(info)
            let chosen = request.fileIndex.flatMap { index in info.files.first { $0.index == index } }
                ?? EpisodeMatch.pick(info.files, episode: request.episode)
                ?? info.files.max { $0.bytes < $1.bytes }
            guard let file = chosen else { throw TorrServerError.noVideo }
            source = WatchSource(link: request.link, hash: info.hash, fileIndex: file.index, fileName: file.name,
                                 releaseTitle: request.releaseTitle)
            Log.note("ПЛЕЕР", "\(request.title): \(file.name) (\(Format.bytes(file.bytes))), с \(Int(request.startAt)) с")
            phase = .preloading(0)
            await client.preload(hash: info.hash, file: file, duration: Double(request.runtimeMinutes * 60)) { [weak self] value, stat in
                let peers = (stat?["active_peers"] as? NSNumber)?.intValue
                let speed = (stat?["download_speed"] as? NSNumber)?.doubleValue
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.preloaded(value, peers: peers, speed: speed) }
                }
            }
            guard !Task.isCancelled else { return }
            let core = MPVCore(layer: layer)
            core.onEvent = { [weak self] event in self?.handle(event) }
            self.core = core
            core.load(client.streamURL(hash: info.hash, file: file), start: request.startAt, title: request.title)
            phase = .playing
            nowPlaying.activate(title: request.title, subtitle: request.subtitle, poster: request.item.poster,
                                toggle: { [weak self] in self?.togglePause() },
                                setPaused: { [weak self] in self?.core?.setPaused($0) },
                                skip: { [weak self] in self?.skip($0) },
                                seek: { [weak self] in self?.seek(to: $0) })
            watchStats(hash: info.hash)
        } catch {
            if HTTP.isCancellation(error) { return }
            Log.note("ПЛЕЕР", "сбой: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
        }
    }

    func stop() {
        save(force: true)
        stats?.cancel()
        core?.destroy()
        core = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        nowPlaying.deactivate()
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Управление

    func togglePause() { core?.setPaused(!paused) }
    func seek(to seconds: Double) { core?.seek(to: max(0, min(seconds, duration > 0 ? duration - 1 : seconds))) }
    func skip(_ seconds: Double) { core?.seek(by: seconds) }
    func selectAudio(_ track: MPVTrack) { core?.selectAudio(track.id) }
    func selectSubtitle(_ track: MPVTrack?) { core?.selectSubtitle(track?.id) }

    // MARK: События

    private func preloaded(_ value: Double, peers: Int?, speed: Double?) {
        if case .preloading = phase { phase = .preloading(value) }
        if let peers { self.peers = peers }
        if let speed { self.speed = Int64(speed) }
    }

    private func handle(_ event: MPVEvent) {
        switch event {
        case .time(let value):
            position = value
            if value > 0 { started = true }
            save(force: false)
            if Date().timeIntervalSince(nowPlayingUpdated) >= 5 { publishNowPlaying() }
        case .duration(let value):
            duration = value
            publishNowPlaying()
        case .paused(let value):
            paused = value
            save(force: true)
            publishNowPlaying()
        case .buffering(let value): buffering = value
        case .cache: break
        case .fileLoaded: Log.note("ПЛЕЕР", "файл открыт")
        case .tracks(let tracks):
            audioTracks = tracks.filter { $0.type == "audio" }
            subtitleTracks = tracks.filter { $0.type == "sub" }
        case .ended(let error):
            if let error {
                phase = .failed("Не удалось воспроизвести: \(error)")
            } else {
                position = max(position, duration)
                save(force: true)
                finished = true
            }
        }
    }

    /// Позицию экран блокировки досчитывает сам по скорости; обновляем при паузе, длительности и раз в 5 с.
    private func publishNowPlaying() {
        nowPlayingUpdated = .now
        nowPlaying.update(position: position, duration: duration, paused: paused)
    }

    private func save(force: Bool) {
        guard request.record, let library, duration > 0, position > 0 else { return }
        guard force || Date().timeIntervalSince(lastSaved) >= 5 else { return }
        lastSaved = .now
        library.record(item: request.item, episode: request.episode, position: position, duration: duration, source: source)
    }

    /// Пиры и скорость раздачи — подпись под значком буферизации.
    private func watchStats(hash: String) {
        stats?.cancel()
        guard let client else { return }
        stats = Task { [weak self] in
            while !Task.isCancelled {
                if let stat = try? await client.stat(hash) {
                    self?.peers = (stat["active_peers"] as? NSNumber)?.intValue ?? 0
                    self?.speed = Int64((stat["download_speed"] as? NSNumber)?.doubleValue ?? 0)
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.core?.setVideoEnabled(false)
                    self?.save(force: true)
                }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.core?.setVideoEnabled(true) }
            },
        ]
    }
}
