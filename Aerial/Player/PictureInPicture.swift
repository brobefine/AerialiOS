import AVFoundation
import AVKit
import UIKit

/// «Картинка в картинке». mpv рисует в слой Metal, а системное окно PiP принимает только AVPlayer или поток
/// кадров, поэтому окно играет тот же поток TorrServer (или файл с диска) через AVPlayer — с той же позиции.
/// AVPlayer понимает MP4/MOV/M4V; MKV и AVI он не откроет — для них кнопки нет ([PlayerModel.pipURL]).
/// Развернули окно — плеер Aerial открывается снова с места, где остановилось окно; закрыли — прогресс в медиатеку.
@MainActor
final class PictureInPicture: NSObject, AVPictureInPictureControllerDelegate {
    static let shared = PictureInPicture()

    static let containers: Set<String> = ["mp4", "m4v", "mov"]

    /// Развернуть в плеер Aerial: запрос с позицией окна.
    var onRestore: ((PlaybackRequest) -> Void)?
    /// Окно закрыли: запрос и позиция — записать прогресс.
    var onClose: ((PlaybackRequest, Double, Double) -> Void)?

    private var player: AVPlayer?
    private var host: UIView?
    private var controller: AVPictureInPictureController?
    private var request: PlaybackRequest?
    private var possible: NSKeyValueObservation?
    private var restoring = false

    var active: Bool { controller?.isPictureInPictureActive == true }

    static var supported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    func start(url: URL, at position: Double, request: PlaybackRequest) {
        stop()
        guard Self.supported,
              let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
        let player = AVPlayer(url: url)
        player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        // Слой должен быть в окне, иначе PiP не стартует; крошечный и почти прозрачный — его не видно.
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
        host.alpha = 0.01
        host.isUserInteractionEnabled = false
        let layer = AVPlayerLayer(player: player)
        layer.frame = host.bounds
        host.layer.addSublayer(layer)
        window.addSubview(host)
        guard let controller = AVPictureInPictureController(playerLayer: layer) else {
            host.removeFromSuperview()
            return
        }
        controller.delegate = self
        self.player = player
        self.host = host
        self.controller = controller
        self.request = request
        restoring = false
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        possible = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { controller, _ in
            guard controller.isPictureInPicturePossible else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !controller.isPictureInPictureActive else { return }
                    controller.startPictureInPicture()
                }
            }
        }
        Log.note("PIP", "\(request.title): окно с \(Int(position)) с")
    }

    func stop() {
        possible = nil
        if controller?.isPictureInPictureActive == true { controller?.stopPictureInPicture() }
        player?.pause()
        host?.removeFromSuperview()
        player = nil
        host = nil
        controller = nil
        request = nil
    }

    private var current: (PlaybackRequest, Double, Double)? {
        guard let request, let player else { return nil }
        let position = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? 0
        return (request, position.isFinite ? position : 0, duration.isFinite ? duration : 0)
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completion: @escaping (Bool) -> Void) {
        MainActor.assumeIsolated {
            restoring = true
            if let now = current {
                var again = now.0
                again.startAt = now.1
                onRestore?(again)
            }
        }
        completion(true)
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            if !restoring, let now = current { onClose?(now.0, now.1, now.2) }
            stop()
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        MainActor.assumeIsolated {
            Log.note("PIP", "не открылось: \(error.localizedDescription)")
            if let now = current {
                var again = now.0
                again.startAt = now.1
                stop()
                onRestore?(again)
            }
        }
    }
}
