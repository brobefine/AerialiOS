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
    private let dismiss: () -> Void

    init(request: PlaybackRequest, onClose: @escaping () -> Void) {
        _model = State(initialValue: PlayerModel(request: request))
        dismiss = onClose
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MPVVideoView(layer: model.layer).ignoresSafeArea()
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { toggleControls() }
            status
            if controls || model.phase != .playing || model.paused {
                overlay.transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: controls)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .task { await model.start(settings: settings, library: library) }
        .onAppear { scheduleHide() }
        .onDisappear { model.stop() }
        .onChange(of: model.finished) { _, finished in if finished { dismiss() } }
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

    private var overlay: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(CircleGlassButtonStyle(size: 42))
                    .accessibilityLabel("Закрыть")
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.request.title).font(.headline).lineLimit(1)
                    Text(model.request.subtitle).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
                }
                .foregroundStyle(.white)
                Spacer()
                if model.phase == .playing { tracksMenu }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            Spacer()
            if model.phase == .playing && model.started {
                HStack(spacing: 56) {
                    Button { model.skip(-10); scheduleHide() } label: { Image(systemName: "gobackward.10") }
                        .font(.system(size: 30, weight: .medium))
                    Button { model.togglePause(); scheduleHide() } label: {
                        Image(systemName: model.paused ? "play.fill" : "pause.fill")
                    }
                    .font(.system(size: 44, weight: .semibold))
                    .accessibilityIdentifier("player-pause")
                    Button { model.skip(10); scheduleHide() } label: { Image(systemName: "goforward.10") }
                        .font(.system(size: 30, weight: .medium))
                }
                .foregroundStyle(.white)
                .shadow(radius: 8)
                Spacer()
                timeline.padding(.horizontal, 24).padding(.bottom, 18)
            } else {
                Spacer()
            }
        }
        .background {
            VStack {
                LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom).frame(height: 140)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom).frame(height: 160)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
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
                    .tint(Theme.accent)
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
