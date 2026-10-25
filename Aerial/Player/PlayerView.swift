import SwiftUI
import UIKit

/// Полноэкранный плеер в духе Apple TV: видео во весь экран, панель по касанию, сама прячется через 4 с.
struct PlayerView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Library.self) private var library

    @State private var model: PlayerModel
    @State private var controls = true
    @State private var scrub: Double?
    @State private var hideTask: Task<Void, Never>?
    @State private var nextDismissed = false
    @State private var countdown = 10
    @State private var findingSubtitles = false
    @State private var partyOpen = false
    /// Цвет постера: шкала времени и стекло кнопок ([PosterPalette]).
    @State private var accent: Color?
    private let dismiss: () -> Void
    private let onNext: (PlaybackRequest) -> Void

    init(request: PlaybackRequest, onClose: @escaping () -> Void, onNext: @escaping (PlaybackRequest) -> Void) {
        _model = State(initialValue: PlayerModel(request: request))
        dismiss = onClose
        self.onNext = onNext
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MPVVideoView(layer: model.layer) { model.refreshVideo() }.ignoresSafeArea()
            if !model.started {
                // Пока видео не пошло — кадр фильма в размытии, как у системного плеера при загрузке.
                CachedImage(path: model.request.item.backdrop.isEmpty ? model.request.item.poster : model.request.item.backdrop,
                            size: "w780", pixelWidth: 800)
                    .blur(radius: 30, opaque: true)
                    .overlay(Color.black.opacity(0.45))
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { toggleControls() }
                // Смахнуть вниз — закрыть, как системный плеер.
                .gesture(DragGesture(minimumDistance: 40).onEnded { value in
                    if value.translation.height > 120 && abs(value.translation.width) < value.translation.height { dismiss() }
                })
            status
            overlay
            corner
            PartyOverlay(party: WatchParty.shared)
            knockBanner
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .task { await model.start(settings: settings, library: library) }
        .task { accent = await PosterPalette.accent(model.request.item.poster) }
        .onAppear { scheduleHide() }
        .onDisappear { model.stop() }
        .onChange(of: model.finished) { _, finished in
            if finished && (model.next == nil || nextDismissed) { dismiss() }
        }
        .task(id: model.finished) { await autoplay() }
        .sheet(isPresented: $partyOpen) { PartySheet(model: model) }
        .onChange(of: WatchParty.shared.media) { _, media in followRoom(media) }
        .sheet(isPresented: $findingSubtitles) {
            SubtitleSearch(item: model.request.item, episode: model.request.episode, key: settings.openSubsKey,
                           languages: settings.subsLanguages) { file in
                findingSubtitles = false
                model.addSubtitle(file)
            }
        }
    }

    // MARK: Комната

    /// Комната переключила серию или фильм — открываем то же у себя (своё переключение комната уже знает).
    private func followRoom(_ media: PartyMedia?) {
        guard let media, WatchParty.shared.active, let source = model.partyMedia, source != media else { return }
        guard media.hash != source.hash || media.file != source.file else { return }
        var request = PlaybackRequest.party(media, at: 0)
        if media.hash == source.hash { request.item = model.request.item }
        request.fromParty = true
        model.stop()
        onNext(request)
    }

    /// Друг постучался — предложить комнату: код уйдёт в его список друзей.
    @ViewBuilder private var knockBanner: some View {
        if let from = Friends.shared.knockFrom {
            VStack {
                HStack(spacing: 12) {
                    Image(systemName: "hand.wave.fill").foregroundStyle(Theme.accent)
                    Text(L("%@ хочет смотреть вместе", from)).font(.aerial(.subheadline, .semibold)).lineLimit(2)
                    if !WatchParty.shared.active && model.partyMedia != nil {
                        Button(L("Открыть комнату")) {
                            model.hostParty()
                            Friends.shared.knockFrom = nil
                            partyOpen = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button { Friends.shared.knockFrom = nil } label: { Image(systemName: "xmark") }.foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glass(in: Capsule())
                .padding(.top, 16)
                Spacer()
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: Серии

    /// Справа внизу: «Пропустить заставку», а на титрах и после конца серии — «Далее».
    @ViewBuilder private var corner: some View {
        let upNext = model.next.flatMap { (model.finished || model.credits) && !nextDismissed ? $0 : nil }
        VStack {
            Spacer()
            HStack {
                Spacer()
                if let upNext {
                    nextCard(upNext)
                } else if let skip = model.skipNow, !model.buffering {
                    Button {
                        model.skipSegment()
                        scheduleHide()
                    } label: {
                        Label(skip.kind == .recap ? L("Пропустить «Ранее в сериале»") : L("Пропустить заставку"), systemImage: "forward.end.fill")
                            .font(.aerial(.subheadline, .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 18)
                            .frame(height: 44)
                            .background(.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("player-skip")
                }
            }
            .padding(.trailing, 24)
            .padding(.bottom, controls ? 110 : 28)
        }
        .animation(.easeOut(duration: 0.2), value: upNext?.id)
        .animation(.easeOut(duration: 0.2), value: model.skipNow)
    }

    private func nextCard(_ next: PlaybackRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("Далее")).font(.aerial(.caption, .semibold)).foregroundStyle(Theme.secondaryText)
                Spacer()
                Button {
                    nextDismissed = true
                    if model.finished { dismiss() }
                } label: {
                    Image(systemName: "xmark").font(.aerial(.caption, .bold)).foregroundStyle(.white.opacity(0.8))
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel(L("Скрыть"))
            }
            if let episode = next.episode {
                Text("\(episode.code) · \(episode.title)").font(.aerial(.headline)).foregroundStyle(.white).lineLimit(2)
            }
            if model.finished && settings.autoplayNext {
                Text(L("Начнётся через %@ с", "\(countdown)")).font(.aerial(.caption)).foregroundStyle(Theme.secondaryText)
            }
            Button { playNext() } label: { Label(L("Смотреть"), systemImage: "play.fill") }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("player-next")
        }
        .padding(16)
        .frame(width: 300)
        .glass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    /// Серия кончилась — через 10 с следующая, если так в настройках и карточку не скрыли.
    private func autoplay() async {
        countdown = 10
        guard model.finished, model.next != nil, settings.autoplayNext, !nextDismissed else { return }
        while countdown > 0 {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled || nextDismissed { return }
            countdown -= 1
        }
        playNext()
    }

    private func playNext() {
        guard let next = model.next else { return }
        model.stop()
        onNext(next)
    }

    // MARK: Состояние

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .connecting(let text):
            PreparingView(text: text, progress: nil, peers: model.peers, speed: model.speed)
        case .preloading(let value):
            PreparingView(text: L("Подготовка к просмотру"), progress: value, peers: model.peers, speed: model.speed)
        case .failed(let message):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill").font(.aerial(.largeTitle)).foregroundStyle(.yellow)
                Text(message).multilineTextAlignment(.center).foregroundStyle(.white)
                Button(L("Закрыть")) { dismiss() }.buttonStyle(PrimaryButtonStyle()).frame(maxWidth: 220)
            }
            .padding(32)
        case .playing:
            if model.buffering || !model.started {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large).tint(.white)
                    if model.peers > 0 { Text(rate).font(.aerial(.footnote).monospacedDigit()).foregroundStyle(.white.opacity(0.8)) }
                }
                .allowsHitTesting(false)
            }
        }
    }

    private var rate: String { L("%@/с · пиров: %@", Format.bytes(model.speed), "\(model.peers)") }

    // MARK: Панель

    /// Панель как у системного плеера iOS 26–27: слева сверху — закрыть, справа — кнопки одной стеклянной капсулой;
    /// по центру видео — −10, пауза и +10 в кругах жидкого стекла; снизу — название и шкала на стеклянной панели.
    /// Показывается и прячется плавно: панель всегда в иерархии, меняется прозрачность и масштаб — стекло при
    /// вставке и удалении вида не анимируется.
    private var overlay: some View {
        let shown = controlsVisible
        return ZStack {
            // Затемнение краёв под кнопками.
            VStack {
                LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom).frame(height: 130)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom).frame(height: 190)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .buttonStyle(CircleGlassButtonStyle(size: 44, tint: accent))
                        .accessibilityLabel(L("Закрыть"))
                        .accessibilityIdentifier("player-close")
                    Spacer()
                    HStack(spacing: 2) {
                        if WatchParty.shared.enabled && model.partyMedia != nil {
                            barButton(WatchParty.shared.active ? "person.2.fill" : "person.2", label: L("Смотреть вместе")) { partyOpen = true }
                        }
                        if let pip = model.pipURL {
                            barButton("pip.enter", label: L("Картинка в картинке")) {
                                let position = model.position
                                let request = model.request
                                model.stop()
                                PictureInPicture.shared.start(url: pip, at: position, request: request)
                                dismiss()
                            }
                        }
                        if model.next != nil {
                            barButton("forward.end.fill", label: L("Следующая серия")) { playNext() }
                        }
                        if model.phase == .playing { tracksMenu }
                    }
                    .padding(.horizontal, 4)
                    .glass(in: Capsule(), tint: accent?.opacity(0.45))
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .offset(y: shown ? 0 : -16)
                Spacer()
                if model.phase == .playing && model.started {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.request.title).font(.aerial(.headline)).lineLimit(1)
                                Text(model.request.subtitle).font(.aerial(.caption)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                            }
                            Spacer(minLength: 12)
                            if model.rate != 1 {
                                Text(String(format: "%g×", model.rate)).font(.aerial(.caption, .semibold)).foregroundStyle(.white.opacity(0.8))
                            }
                        }
                        .foregroundStyle(.white)
                        timeline
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 6)
                    .glass(in: RoundedRectangle(cornerRadius: 26, style: .continuous), tint: accent?.opacity(0.3))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .offset(y: shown ? 0 : 20)
                }
            }

            // Перемотка и пауза — по центру экрана, то есть по центру видео (оно вписано по центру).
            if model.phase == .playing && model.started {
                HStack(spacing: 36) {
                    transport("gobackward.10", size: 64, label: L("Назад на 10 с")) { model.skip(-10) }
                    transport(model.paused ? "play.fill" : "pause.fill", size: 84, label: model.paused ? L("Смотреть") : L("Пауза")) {
                        model.togglePause()
                    }
                    .accessibilityIdentifier("player-pause")
                    transport("goforward.10", size: 64, label: L("Вперёд на 10 с")) { model.skip(10) }
                }
                .scaleEffect(shown ? 1 : 0.9)
            }
        }
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .animation(.smooth(duration: 0.3), value: shown)
    }

    /// Панель на виду: касанием, а на паузе, при подготовке и ошибке — всегда.
    private var controlsVisible: Bool { controls || model.phase != .playing || model.paused }

    private func barButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            scheduleHide()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// Кнопка в круге жидкого стекла; значок паузы сменяется анимацией символа.
    private func transport(_ symbol: String, size: CGFloat, label: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            scheduleHide()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(.white)
                // На светлом кадре белый значок терялся: стекло чуть темнее, у значка — тень.
                .shadow(color: .black.opacity(0.35), radius: 4)
                .frame(width: size, height: size)
                .glass(in: Circle(), tint: (accent ?? .black).opacity(0.35))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(label)
    }

    private var timeline: some View {
        VStack(spacing: 6) {
            Scrubber(position: model.position, duration: model.duration, color: accent.map { $0.mix(with: .white, by: 0.35) } ?? .white,
                     scrub: $scrub) { target in
                model.seek(to: target)
                scheduleHide()
            }
            HStack {
                Text(Format.clock(scrub ?? model.position)).accessibilityIdentifier("player-time")
                Spacer()
                Text("−" + Format.clock(max(0, model.duration - (scrub ?? model.position))))
            }
            .font(.aerial(.caption).monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))
        }
    }

    private var tracksMenu: some View {
        Menu {
            Section(L("Звук")) {
                ForEach(model.audioTracks) { track in
                    Button { model.selectAudio(track) } label: { choice(track.label, track.selected) }
                }
            }
            Section(L("Скорость")) {
                Picker(L("Скорость"), selection: Binding(get: { model.rate }, set: { model.setRate($0) })) {
                    ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { value in
                        Text(value == 1 ? L("Обычная") : String(format: "%g×", value)).tag(value)
                    }
                }
                .pickerStyle(.menu)
            }
            Section(L("Субтитры")) {
                Button { model.selectSubtitle(nil) } label: {
                    choice(L("Выключены"), !model.subtitleTracks.contains(where: \.selected))
                }
                ForEach(model.subtitleTracks) { track in
                    Button { model.selectSubtitle(track) } label: { choice(track.label, track.selected) }
                }
                if !settings.openSubsKey.isEmpty {
                    Button { findingSubtitles = true } label: { Label(L("Найти субтитры…"), systemImage: "magnifyingglass") }
                }
            }
        } label: {
            Image(systemName: "captions.bubble")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(L("Звук, субтитры и скорость"))
    }

    @ViewBuilder
    private func choice(_ title: String, _ selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func toggleControls() {
        withAnimation(.smooth(duration: 0.3)) { controls.toggle() }
        if controls { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        // В UI-тестах панель не прячется: по её часам тест видит, что видео пошло.
        guard !UITestHooks.active else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4), tolerance: .milliseconds(500))
            guard !Task.isCancelled, model.phase == .playing, !model.paused, scrub == nil else { return }
            withAnimation(.smooth(duration: 0.4)) { controls = false }
        }
    }
}

/// Подготовка: запуск сервера, метаданные раздачи, подкачка начала — с долей и скоростью.
private struct PreparingView: View {
    let text: String
    let progress: Double?
    let peers: Int
    let speed: Int64

    var body: some View {
        VStack(spacing: 14) {
            if let progress {
                ProgressView(value: progress)
                    .tint(.white)
                    .frame(width: 220)
                Text("\(text) · \(Int(progress * 100)) %")
            } else {
                ProgressView().controlSize(.large).tint(.white)
                Text(text)
            }
            if peers > 0 || speed > 0 {
                Text(L("%@/с · пиров: %@", Format.bytes(speed), "\(peers)"))
                    .font(.aerial(.footnote).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .font(.aerial(.subheadline))
        .foregroundStyle(.white)
        .padding(.horizontal, 26)
        .padding(.vertical, 20)
        .glass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .allowsHitTesting(false)
    }
}

/// Шкала времени: тянется пальцем, при отпускании — переход.
private struct Scrubber: View {
    let position: Double
    let duration: Double
    let color: Color
    @Binding var scrub: Double?
    let onCommit: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let shown = scrub ?? position
            let fraction = duration > 0 ? min(1, max(0, shown / duration)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(color).frame(width: geometry.size.width * fraction)
            }
            .frame(height: scrub == nil ? 5 : 9)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        scrub = min(1, max(0, value.location.x / geometry.size.width)) * duration
                    }
                    .onEnded { _ in
                        if let target = scrub { onCommit(target) }
                        scrub = nil
                    }
            )
            .animation(.easeOut(duration: 0.15), value: scrub == nil)
        }
        .frame(height: 28)
    }
}

struct MPVVideoView: UIViewControllerRepresentable {
    let layer: MPVMetalLayer
    var onResize: () -> Void = {}

    func makeUIViewController(context: Context) -> MPVViewController {
        let controller = MPVViewController(layer: layer)
        controller.onResize = onResize
        return controller
    }

    func updateUIViewController(_ controller: MPVViewController, context: Context) {
        controller.onResize = onResize
    }
}

/// Ориентация на iPhone, как у Apple TV: каталог — книжная, плеер открывается альбомным, но поворачивается
/// и в книжную ([PlayerHostingController]).
/// На iPad — как держат. Разрешённые приложению ориентации отдаёт [AppDelegate].
@MainActor
enum Orientation {
    private(set) static var mask: UIInterfaceOrientationMask = UIDevice.current.userInterfaceIdiom == .phone ? .portrait : .all

    /// Перед показом плеера — разрешить альбомную; после закрытия — вернуть книжную.
    static func allowLandscape(_ allow: Bool) {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        mask = allow ? .allButUpsideDown : .portrait
        guard !allow, let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.windows.forEach { $0.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { error in
            Log.note("ПОВОРОТ", error.localizedDescription)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Orientation.mask
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let keys = launchOptions?.keys.map(\.rawValue).sorted().joined(separator: ", ") ?? ""
        Log.note("ЗАПУСК", "состояние \(application.applicationState == .background ? "в фоне" : "на экране")"
            + (keys.isEmpty ? "" : ", причина: \(keys)"))
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        CrashGuard.mark("terminated")
        Log.note("ЖИЗНЬ", "закрыто")
    }
}

/// «Найти субтитры…»: выдача OpenSubtitles по фильму или серии; выбор — файл скачивается и сразу включается.
private struct SubtitleSearch: View {
    let item: VodItem
    let episode: VodEpisode?
    let key: String
    let languages: String
    let onPick: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var results: [OpenSubtitles.Result] = []
    @State private var loading = true
    @State private var busy: Int?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            List {
                if let failure { Text(failure).foregroundStyle(Theme.secondaryText) }
                ForEach(results) { result in
                    Button {
                        Task { await pick(result) }
                    } label: {
                        HStack(spacing: 12) {
                            Text(result.language.uppercased())
                                .font(.aerial(.caption, .bold))
                                .frame(width: 34, height: 24)
                                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.release).font(.aerial(.subheadline)).foregroundStyle(.white).lineLimit(2)
                                Text(L("Скачиваний: %@", "\(result.downloads)")).font(.aerial(.caption2)).foregroundStyle(Theme.secondaryText)
                            }
                            Spacer(minLength: 0)
                            if busy == result.fileId { ProgressView() }
                        }
                    }
                    .disabled(busy != nil)
                }
            }
            .overlay {
                if loading { ProgressView(L("Ищу на OpenSubtitles…")) }
                else if results.isEmpty && failure == nil { ContentUnavailableView(L("Субтитров не нашлось"), systemImage: "captions.bubble") }
            }
            .navigationTitle(episode.map { L("Субтитры · %@", $0.code) } ?? L("Субтитры"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Отмена")) { dismiss() } } }
        }
        .task {
            do {
                results = try await OpenSubtitles.search(key: key, item: item, episode: episode, languages: languages)
            } catch {
                failure = error.localizedDescription
            }
            loading = false
        }
    }

    private func pick(_ result: OpenSubtitles.Result) async {
        busy = result.fileId
        defer { busy = nil }
        do {
            onPick(try await OpenSubtitles.download(key: key, result))
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// Нажатие — лёгкое сжатие, как у кнопок системного плеера.
private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
