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
    /// Скачанный файл — плеер берёт его с диска, без TorrServer ([Downloads]).
    var localFile: URL?
    /// Открыт по команде комнаты (она переключила серию) — сообщать ей о смене не нужно.
    var fromParty = false
    /// Озвучка, выбранная в окне раздачи: дорожка с таким названием включается сама.
    var voice: String?

    var title: String { item.title }

    /// Гость комнаты: раздача по хэшу, файл и оформление — от создателя; сериал TMDb, если он его назвал.
    static func party(_ media: PartyMedia, at position: Double) -> PlaybackRequest {
        let series = Int(media.series) ?? 0
        let item = VodItem(id: series > 0 ? "tmdb:series:\(series)" : "torrent:\(media.hash)", remoteId: series,
                           kind: series > 0 ? .series : .movie, title: media.title, poster: media.poster, backdrop: media.backdrop,
                           releaseDate: media.year)
        let episode = media.episode > 0
            ? VodEpisode(season: media.season, number: media.episode, title: "Серия \(media.episode)") : nil
        return PlaybackRequest(item: item, episode: episode, link: "magnet:?xt=urn:btih:\(media.hash)", fileIndex: media.file,
                               releaseTitle: media.title, startAt: position, record: series > 0)
    }
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
        // Окно PiP развернули — плеер Aerial с того же места; закрыли — прогресс в медиатеку.
        PictureInPicture.shared.onRestore = { [weak self] request in
            self?.request = nil
            self?.play(request)
        }
        PictureInPicture.shared.onClose = { [weak library] request, position, duration in
            guard request.record, position > 0 else { return }
            library?.record(item: request.item, episode: request.episode, position: position, duration: duration, source: nil)
        }
    }

    func play(_ request: PlaybackRequest) {
        PictureInPicture.shared.stop()
        guard controller == nil, let settings, let library, let presenter = Self.topController() else { return }
        DownloadKeepAlive.shared.suspendForPlayer()
        self.request = Self.resolved(request)
        PerfMonitor.activity = "плеер: \(request.title)\(self.request?.localFile == nil ? "" : " (с диска)")"
        Orientation.allowLandscape(true)
        let view = PlayerScreen { [weak self] in self?.close() }
            .font(.aerial(.body))
            .environment(settings)
            .environment(library)
            .environment(self)
        let host = PlayerHostingController(rootView: AnyView(view))
        host.modalPresentationStyle = .fullScreen
        controller = host
        presenter.present(host, animated: true)
    }

    func close() {
        guard let controller else {
            // Контроллер потерян (повтор показа, сбой) — снимаем то, что показано поверх, чтобы плеер не залип.
            Self.topController()?.presentingViewController?.dismiss(animated: true)
            Orientation.allowLandscape(false)
            request = nil
            return
        }
        self.controller = nil
        PerfMonitor.activity = ""
        controller.dismiss(animated: true) { [weak self] in
            Orientation.allowLandscape(false)
            DownloadKeepAlive.shared.resumeAfterPlayer()
            self?.request = nil
        }
    }

    /// Следующая серия в том же окне плеера: прежний плеер уже остановлен и сохранил прогресс.
    func advance(to next: PlaybackRequest) {
        guard controller != nil else { return }
        Log.note("ПЛЕЕР", "следующая серия: \(next.subtitle)")
        request = Self.resolved(next)
    }

    /// Файл уже скачан — играем его с диска.
    private static func resolved(_ request: PlaybackRequest) -> PlaybackRequest {
        guard request.localFile == nil, let url = Downloads.shared.localURL(link: request.link, fileIndex: request.fileIndex) else {
            return request
        }
        var local = request
        local.localFile = url
        return local
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

/// Плеер текущего запроса [Playback]; новая серия — новый [PlayerView] со своим mpv.
private struct PlayerScreen: View {
    let onClose: () -> Void

    @Environment(Playback.self) private var playback

    var body: some View {
        if let request = playback.request {
            PlayerView(request: request, onClose: onClose) { playback.advance(to: $0) }
                .id(request.id)
        } else {
            Color.black.ignoresSafeArea()
        }
    }
}

/// Контроллер плеера: на iPhone открывается повёрнутым в альбомную, но можно смотреть и в книжной; без строки
/// состояния и полоски «домой»; на iPad — как держат.
final class PlayerHostingController: UIHostingController<AnyView> {
    private var phone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { phone ? .allButUpsideDown : .all }
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
    /// Заставка и титры серии (IntroDB, AniSkip); пусто — неизвестны.
    private(set) var skips: [SkipSegment] = []
    /// Следующая серия из той же раздачи; nil — фильм или серия последняя.
    private(set) var next: PlaybackRequest?
    /// Скорость воспроизведения.
    private(set) var rate: Double = 1
    /// Поток для «Картинки в картинке»: только контейнеры, которые понимает AVPlayer ([PictureInPicture]).
    private(set) var pipURL: URL?

    /// Идёт заставка или «ранее в сериале» — кнопка пропуска (до конца отрезка больше 1,5 с).
    var skipNow: SkipSegment? {
        skips.first { $0.kind != .outro && position >= $0.start && position < $0.end - 1.5 }
    }

    /// Титры: с начала отмеченных, иначе за минуту до конца (или 2,5 % длины) — пора предложить следующую серию.
    var credits: Bool {
        guard duration > 0, next != nil else { return false }
        if let outro = skips.first(where: { $0.kind == .outro }) { return position >= outro.start }
        return duration - position <= max(60, duration / 40)
    }

    @ObservationIgnored private var core: MPVCore?
    @ObservationIgnored private var library: Library?
    @ObservationIgnored private var client: TorrServerClient?
    @ObservationIgnored private var source: WatchSource?
    @ObservationIgnored private var stats: Task<Void, Never>?
    @ObservationIgnored private var lastSaved = Date.distantPast
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    private let nowPlaying = NowPlaying()
    @ObservationIgnored private var nowPlayingUpdated = Date.distantPast
    @ObservationIgnored private var stopped = false

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
            let url: URL
            var statsHash: String?
            if let local = request.localFile {
                // Скачанный файл: без сервера и подкачки.
                let files = Downloads.shared.localFiles(link: request.link)
                let file = files.first { $0.index == request.fileIndex }
                    ?? TorrentFile(index: request.fileIndex ?? 0, path: local.lastPathComponent, bytes: 0)
                source = WatchSource(link: request.link, hash: TorrServerClient.infoHash(request.link) ?? "", fileIndex: file.index,
                                     fileName: file.name, releaseTitle: request.releaseTitle)
                Log.note("ПЛЕЕР", "\(request.title): с диска \(local.lastPathComponent), с \(Int(request.startAt)) с")
                plan(files: files, current: file)
                url = local
            } else {
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
                plan(files: info.files, current: file)
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
                url = client.streamURL(hash: info.hash, file: file)
                statsHash = info.hash
            }
            if PictureInPicture.supported, PictureInPicture.containers.contains((source?.fileName as NSString?)?.pathExtension.lowercased() ?? "") {
                pipURL = url
            }
            let core = MPVCore(layer: layer)
            core.onEvent = { [weak self] event in self?.handle(event) }
            self.core = core
            core.load(url, start: request.startAt, title: request.title)
            phase = .playing
            nowPlaying.activate(title: request.title, subtitle: request.subtitle, poster: request.item.poster,
                                toggle: { [weak self] in self?.togglePause() },
                                setPaused: { [weak self] in self?.core?.setPaused($0) },
                                skip: { [weak self] in self?.skip($0) },
                                seek: { [weak self] in self?.seek(to: $0) })
            if let statsHash { watchStats(hash: statsHash) }
            startPartySync()
            Friends.shared.watching = FriendWatching(title: request.item.title, sub: request.episode?.code ?? "", poster: request.item.poster,
                                                     room: WatchParty.shared.code ?? "")
        } catch {
            if HTTP.isCancellation(error) { return }
            Log.note("ПЛЕЕР", "сбой: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
        }
    }

    /// Повторный вызов ничего не делает: при переходе к следующей серии плеер останавливают раньше, чем экран уходит.
    func stop() {
        guard !stopped else { return }
        stopped = true
        partySync?.cancel()
        Friends.shared.watching = nil
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

    func togglePause() {
        let playing = paused
        core?.setPaused(!paused)
        partyPush(playing: playing, position: position)
    }

    func seek(to seconds: Double) {
        let target = max(0, min(seconds, duration > 0 ? duration - 1 : seconds))
        core?.seek(to: target)
        partyPush(playing: !paused, position: target, seeking: true)
    }

    func skip(_ seconds: Double) {
        core?.seek(by: seconds)
        partyPush(playing: !paused, position: max(0, position + seconds), seeking: true)
    }

    // MARK: Совместный просмотр

    /// Комната смотрит эту раздачу (файл может быть другим — тогда плеер переключится на него).
    var inParty: Bool {
        let party = WatchParty.shared
        guard party.active, let media = party.media, let source else { return false }
        return media.hash == source.hash.lowercased()
    }

    var partyFile: Bool { inParty && WatchParty.shared.media?.file == source?.fileIndex }

    @ObservationIgnored private var partySync: Task<Void, Never>?
    @ObservationIgnored private var seekingUntil: TimeInterval = 0

    /// Сведения комнате: эта раздача, этот файл и серия — по ним гость найдёт заставку и титры.
    var partyMedia: PartyMedia? {
        guard let source, !source.hash.isEmpty else { return nil }
        return PartyMedia(hash: source.hash.lowercased(), file: source.fileIndex, title: request.item.title, poster: request.item.poster,
                          backdrop: request.item.backdrop, year: request.item.year,
                          series: request.item.kind == .series && request.item.remoteId > 0 ? String(request.item.remoteId) : "",
                          season: request.episode?.season ?? 0, episode: request.episode?.number ?? 0)
    }

    /// Создать комнату с этим фильмом; код — друзьям в статус.
    @discardableResult
    func hostParty() -> String? {
        guard let media = partyMedia else { return nil }
        let code = WatchParty.shared.host(media, playing: !paused, position: position)
        Friends.shared.watching = FriendWatching(title: request.item.title, sub: request.episode?.code ?? "", poster: request.item.poster, room: code)
        return code
    }

    /// Своё действие — в комнату: пауза, ход, перемотка применятся у всех.
    private func partyPush(playing: Bool, position: Double, seeking: Bool = false) {
        guard partyFile else { return }
        if seeking { seekingUntil = ProcessInfo.processInfo.systemUptime + 4 }
        WatchParty.shared.sendState(playing: playing, position: position)
    }

    /// Общий ход комнаты → свой плеер: раз в секунду сверка паузы и места (расхождение больше 2,5 с — перемотка к общему).
    /// Пока сами перематываем или догружаем место, комнату не слушаем, иначе её эхо возвращало бы назад.
    private func startPartySync() {
        partySync?.cancel()
        // Сами переключили серию той же раздачи в комнате — сообщаем комнате, у всех откроется она же.
        let party = WatchParty.shared
        if party.active, !request.fromParty, let mine = partyMedia, let roomMedia = party.media,
           roomMedia.hash == mine.hash, roomMedia.file != mine.file {
            party.switchMedia(mine)
        }
        partySync = Task { [weak self] in
            var wasBuffering = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let party = WatchParty.shared
                guard partyFile, started, let room = party.room else { continue }
                if buffering != wasBuffering {
                    wasBuffering = buffering
                    party.sendBuffering(buffering)
                    // Догрузил место после перемотки — комната ждёт всех.
                    if !buffering && ProcessInfo.processInfo.systemUptime < seekingUntil { party.sendReady() }
                }
                guard party.connected, ProcessInfo.processInfo.systemUptime > seekingUntil, !buffering else { continue }
                if room.effectivePlaying == paused { core?.setPaused(!room.effectivePlaying) }
                let target = room.target()
                if abs(target - position) > 2.5 && (duration <= 0 || target < duration - 1) {
                    Log.note("PARTY", "сверка: \(Int(position)) → \(Int(target)) с")
                    seekingUntil = ProcessInfo.processInfo.systemUptime + 3
                    core?.seek(to: target)
                }
            }
        }
    }
    func selectAudio(_ track: MPVTrack) { core?.selectAudio(track.id) }
    func refreshVideo() { core?.refreshVideo() }
    func selectSubtitle(_ track: MPVTrack?) { core?.selectSubtitle(track?.id) }
    func addSubtitle(_ file: URL) {
        Log.note("ПЛЕЕР", "субтитры: \(file.lastPathComponent)")
        core?.addSubtitle(file)
    }

    func setRate(_ value: Double) {
        rate = value
        core?.setSpeed(value)
    }

    func skipSegment() {
        if let segment = skipNow { seek(to: segment.end) }
    }

    // MARK: Сериал

    private func plan(files: [TorrentFile], current: TorrentFile) {
        Task { [weak self] in
            await self?.planNext(files: files, current: current)
            await self?.loadSkips()
        }
    }

    /// Следующая серия — следующий по сезону и номеру файл той же раздачи (пачка сезона или нескольких сезонов).
    /// Название и длительность — из TMDb, если сезон отвечает.
    private func planNext(files: [TorrentFile], current: TorrentFile) async {
        guard request.item.kind == .series, let episode = request.episode else { return }
        let here = EpisodeMatch.coordinates(current.path) ?? (season: episode.season, episode: episode.number)
        let found = files.compactMap { file -> (file: TorrentFile, season: Int, number: Int)? in
            guard let place = EpisodeMatch.coordinates(file.path), (place.season, place.episode) > (here.season, here.episode) else {
                return nil
            }
            return (file: file, season: place.season, number: place.episode)
        }.min { ($0.season, $0.number) < ($1.season, $1.number) }
        guard let found else { return }
        let episodes = request.item.remoteId > 0 ? (try? await Catalogue.shared.season(request.item, found.season)) ?? [] : []
        let meta = episodes.first { $0.number == found.number }
            ?? VodEpisode(season: found.season, number: found.number, title: "Серия \(found.number)")
        next = PlaybackRequest(item: request.item, episode: meta, link: request.link, fileIndex: found.file.index,
                               releaseTitle: request.releaseTitle, runtimeMinutes: meta.runtimeMinutes, record: request.record)
    }

    private func loadSkips() async {
        guard request.item.kind == .series, request.item.remoteId > 0, let episode = request.episode else { return }
        let imdb = await Catalogue.shared.imdbId(request.item)
        let found = await SkipSegments.shared.load(tmdbId: request.item.remoteId, imdbId: imdb, season: episode.season,
                                                   episode: episode.number)
        skips = found
        let list = found.map { "\($0.kind) \(Int($0.start))-\(Int($0.end)) с" }.joined(separator: ", ")
        Log.note("ЗАСТАВКА", "\(request.title) S\(episode.season)E\(episode.number) imdb=\(imdb ?? "—") → \(list.isEmpty ? "нет отметок" : list)")
    }

    // MARK: События

    private func preloaded(_ value: Double, peers: Int?, speed: Double?) {
        if case .preloading = phase { phase = .preloading(value) }
        if let peers { self.peers = peers }
        if let speed { self.speed = Int64(speed) }
    }

    private func handle(_ event: MPVEvent) {
        switch event {
        case .time(let value):
            // mpv присылает время каждый кадр; на каждое изменение SwiftUI пересчитывал плеер — 30–60 раз в секунду,
            // и это заметно садило батарею. Часы и шкале хватает полсекунды.
            if abs(value - position) >= 0.5 { position = value }
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
            let firstTracks = audioTracks.isEmpty
            audioTracks = tracks.filter { $0.type == "audio" }
            if firstTracks, let voice = request.voice?.lowercased(), !voice.isEmpty,
               let track = audioTracks.first(where: { $0.title.lowercased().contains(voice) }), !track.selected {
                selectAudio(track)
            }
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
                // Пиры и скорость видны только при подкачке — во время просмотра спрашиваем реже.
                let busy = self.map { $0.buffering || !$0.started } ?? false
                try? await Task.sleep(for: .seconds(busy ? 2 : 15))
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
