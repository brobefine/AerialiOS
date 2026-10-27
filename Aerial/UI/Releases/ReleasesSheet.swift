import SwiftUI

/// Что открыть в окне раздач со страницы фильма.
struct ReleasesTarget: Identifiable {
    let id = UUID()
    let item: VodItem
    let episode: VodEpisode?
    let runtime: Int
    /// Автовыбор (`AutoPick`): раздача уже подобрана — окно сразу на её фильме или сезонах с сериями.
    var picked: (release: Release, info: TorrentInfo)? = nil
}

/// Окно раздач поверх страницы фильма (27 октября, как на ТВ и ПК): без автовыбора — список раздач, выбор раздачи
/// переходом в том же окне открывает сезон и серию; с автовыбором — сразу «Смотреть» подобранной раздачи.
/// [close] закрывает окно и после закрытия запускает плеер.
struct ReleasesSheet: View {
    let target: ReleasesTarget
    let close: (@escaping () -> Void) -> Void

    @Environment(Library.self) private var library
    @Environment(Playback.self) private var playback

    var body: some View {
        NavigationStack {
            if let picked = target.picked {
                WatchPane(item: target.item, info: picked.info, episode: target.episode) { file, chosen in
                    let request = releaseRequest(library: library, item: target.item, episode: chosen ?? target.episode,
                                                 release: picked.release, file: file, runtime: target.runtime)
                    close { playback.play(request) }
                }
            } else {
                ReleasesView(item: target.item, episode: target.episode, runtime: target.runtime, close: close)
            }
        }
        .presentationDetents(target.picked == nil ? [.large] : [.medium, .large])
    }
}
