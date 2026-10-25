import SwiftUI
import WebKit

/// Трейлер внутри приложения, как `VodTrailer` ТВ: встроенный плеер YouTube во весь экран, без перехода в YouTube.
/// Страница с `iframe` грузится со своим адресом-источником: без него YouTube отказывает встроенному плееру.
struct TrailerView: View {
    let key: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            YouTubePlayer(key: key).ignoresSafeArea(edges: .horizontal)
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(CircleGlassButtonStyle(size: 44))
                .padding(16)
                .accessibilityLabel(L("Закрыть"))
        }
        .statusBarHidden(true)
    }
}

private struct YouTubePlayer: UIViewRepresentable {
    let key: String

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsPictureInPictureMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;height:100%;background:#000}iframe{position:absolute;inset:0;width:100%;height:100%;border:0}</style>
        </head><body><iframe src="https://www.youtube.com/embed/\(key)?autoplay=1&playsinline=1&rel=0&modestbranding=1"
        allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen></iframe></body></html>
        """
        view.loadHTMLString(html, baseURL: URL(string: "https://aerial.app"))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}
