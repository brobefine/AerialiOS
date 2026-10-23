import MediaPlayer
import UIKit

/// Экран блокировки и «Пункт управления»: название, позиция, пауза, ±10 с и перемотка по шкале.
/// AVPlayer делает это сам; у mpv — вручную.
@MainActor
final class NowPlaying {
    private var targets: [(MPRemoteCommand, Any)] = []
    private var artwork: MPMediaItemArtwork?

    func activate(title: String, subtitle: String, poster: String,
                  toggle: @escaping @MainActor () -> Void, setPaused: @escaping @MainActor (Bool) -> Void,
                  skip: @escaping @MainActor (Double) -> Void, seek: @escaping @MainActor (Double) -> Void) {
        let center = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor (MPRemoteCommandEvent) -> Void) {
            command.isEnabled = true
            let target = command.addTarget { event in
                MainActor.assumeIsolated { action(event) }
                return .success
            }
            targets.append((command, target))
        }
        on(center.togglePlayPauseCommand) { _ in toggle() }
        on(center.playCommand) { _ in setPaused(false) }
        on(center.pauseCommand) { _ in setPaused(true) }
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.preferredIntervals = [10]
        on(center.skipBackwardCommand) { _ in skip(-10) }
        on(center.skipForwardCommand) { _ in skip(10) }
        on(center.changePlaybackPositionCommand) { event in
            if let event = event as? MPChangePlaybackPositionCommandEvent { seek(event.positionTime) }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: subtitle,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        Task { [weak self] in
            guard let image = await ImageLoader.shared.image(TMDbImage.urls(poster, "w342"), pixelWidth: 600) else { return }
            let artwork = Self.artwork(image)
            self?.artwork = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] = artwork
        }
    }

    func update(position: Double, duration: Double, paused: Bool) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = paused ? 0.0 : 1.0
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Картинку система запрашивает не с главного потока — замыкание не должно наследовать главный актор.
    private nonisolated static func artwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    func deactivate() {
        for (command, target) in targets { command.removeTarget(target) }
        targets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
