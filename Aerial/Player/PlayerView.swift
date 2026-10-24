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
            MPVVideoView(layer: model.layer).ignoresSafeArea()
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
            status
            if controls || model.phase != .playing || model.paused {
                overlay.transition(.opacity)
            }
            corner
        }
        .animation(.easeOut(duration: 0.2), value: controls)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .task { await model.start(settings: settings, library: library) }
        .onAppear { scheduleHide() }
        .onDisappear { model.stop() }
        .onChange(of: model.finished) { _, finished in
            if finished && (model.next == nil || nextDismissed) { dismiss() }
        }
        .task(id: model.finished) { await autoplay() }
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
                        Label(skip.kind == .recap ? "Пропустить «Ранее в сериале»" : "Пропустить заставку", systemImage: "forward.end.fill")
                            .font(.subheadline.weight(.semibold))
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
                Text("Далее").font(.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                Spacer()
                Button {
                    nextDismissed = true
                    if model.finished { dismiss() }
                } label: {
                    Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.8))
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel("Скрыть")
            }
            if let episode = next.episode {
                Text("\(episode.code) · \(episode.title)").font(.headline).foregroundStyle(.white).lineLimit(2)
            }
            if model.finished && settings.autoplayNext {
                Text("Начнётся через \(countdown) с").font(.caption).foregroundStyle(Theme.secondaryText)
            }
            Button { playNext() } label: { Label("Смотреть", systemImage: "play.fill") }
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
            PreparingView(text: "Подготовка к просмотру", progress: value, peers: model.peers, speed: model.speed)
        case .failed(let message):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
                Text(message).multilineTextAlignment(.center).foregroundStyle(.white)
                Button("Закрыть") { dismiss() }.buttonStyle(PrimaryButtonStyle()).frame(maxWidth: 220)
            }
            .padding(32)
        case .playing:
            if model.buffering || !model.started {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large).tint(.white)
                    if model.peers > 0 { Text(rate).font(.footnote.monospacedDigit()).foregroundStyle(.white.opacity(0.8)) }
                }
                .allowsHitTesting(false)
            }
        }
    }

    private var rate: String { "\(Format.bytes(model.speed))/с · пиров: \(model.peers)" }

    // MARK: Панель

    /// Панель как у системного плеера iOS 26: сверху — закрыть и звук/субтитры, по центру — перемотка и пауза
    /// на стеклянных кругах, снизу — название над тонкой шкалой времени.
    private var overlay: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(CircleGlassButtonStyle(size: 44))
                    .accessibilityLabel("Закрыть")
                Spacer()
                if model.next != nil {
                    Button { playNext() } label: { Image(systemName: "forward.end.fill") }
                        .buttonStyle(CircleGlassButtonStyle(size: 42))
                        .accessibilityLabel("Следующая серия")
                }
                if model.phase == .playing { tracksMenu }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            Spacer()
            if model.phase == .playing && model.started {
                HStack(spacing: 44) {
                    transport("gobackward.10", size: 56) { model.skip(-10) }
                    transport(model.paused ? "play.fill" : "pause.fill", size: 76) { model.togglePause() }
                        .accessibilityIdentifier("player-pause")
                    transport("goforward.10", size: 56) { model.skip(10) }
                }
                Spacer()
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.request.title).font(.headline).lineLimit(1)
                        Text(model.request.subtitle).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    timeline
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
            } else {
                Spacer()
            }
        }
        .background {
            VStack {
                LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom).frame(height: 120)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom).frame(height: 170)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    private func transport(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button {
            action()
            scheduleHide()
        } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(CircleGlassButtonStyle(size: size))
    }

    private var timeline: some View {
        VStack(spacing: 6) {
            Scrubber(position: model.position, duration: model.duration, scrub: $scrub) { target in
                model.seek(to: target)
                scheduleHide()
            }
            HStack {
                Text(Format.clock(scrub ?? model.position)).accessibilityIdentifier("player-time")
                Spacer()
                Text("−" + Format.clock(max(0, model.duration - (scrub ?? model.position))))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))
        }
    }

    private var tracksMenu: some View {
        Menu {
            Section("Звук") {
                ForEach(model.audioTracks) { track in
                    Button { model.selectAudio(track) } label: { choice(track.label, track.selected) }
                }
            }
            Section("Субтитры") {
                Button { model.selectSubtitle(nil) } label: {
                    choice("Выключены", !model.subtitleTracks.contains(where: \.selected))
                }
                ForEach(model.subtitleTracks) { track in
                    Button { model.selectSubtitle(track) } label: { choice(track.label, track.selected) }
                }
            }
        } label: {
            Image(systemName: "captions.bubble")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .glass(in: Circle(), interactive: true)
        }
        .accessibilityLabel("Звук и субтитры")
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
        controls.toggle()
        if controls { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        // В UI-тестах панель не прячется: по её часам тест видит, что видео пошло.
        guard !UITestHooks.active else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, model.phase == .playing, !model.paused, scrub == nil else { return }
            controls = false
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
                Text("\(Format.bytes(speed))/с · пиров: \(peers)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .font(.subheadline)
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
    @Binding var scrub: Double?
    let onCommit: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let shown = scrub ?? position
            let fraction = duration > 0 ? min(1, max(0, shown / duration)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white).frame(width: geometry.size.width * fraction)
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

    func makeUIViewController(context: Context) -> MPVViewController { MPVViewController(layer: layer) }
    func updateUIViewController(_ controller: MPVViewController, context: Context) {}
}

/// Ориентация на iPhone, как у Apple TV: каталог — книжная, плеер — альбомная ([PlayerHostingController]).
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
}
