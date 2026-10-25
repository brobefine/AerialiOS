import SwiftUI
import UIKit

/// Вселенная — раздел кинотеки целиком: ~2000 самых известных работ по числу голосов TMDb.
enum Universe: String, CaseIterable, Identifiable {
    case movies, series, cartoons
    case cartoonSeries = "cartoon-series"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .movies: L("Фильмы")
        case .series: L("Сериалы")
        case .cartoons: L("Мультфильмы")
        case .cartoonSeries: L("Мультсериалы")
        }
    }
    var kind: VodKind { self == .movies || self == .cartoons ? .movie : .series }
}

/// Готовые стены — те же, что у ТВ (`VodWall.remoteBase`): ветка `universes-data` репозитория релизов, сборщик
/// `tools/universes/build.py` в `F:\Aerial`. На вселенную — картинка мозаики 1728×1008 (72×28 клеток 24×36) и список
/// работ по клеткам. Список держится на устройстве неделю.
enum UniverseStore {
    static let base = "https://raw.githubusercontent.com/brobefine/Aerial/universes-data/universes"
    static let columns = 72
    static let rows = 28
    static let cell = CGSize(width: 24, height: 36)
    static var size: CGSize { CGSize(width: CGFloat(columns) * cell.width, height: CGFloat(rows) * cell.height) }

    static func atlas(_ universe: Universe) -> URL? { URL(string: "\(base)/\(universe.rawValue).ru.webp") }

    static func films(_ universe: Universe) async throws -> [VodItem?] {
        let key = "universe:\(universe.rawValue):ru"
        let data: Data
        if let cached = DiskCache.api.get(key, ttl: 7 * DiskCache.day) {
            data = cached
        } else {
            guard let url = URL(string: "\(base)/\(universe.rawValue).ru.json") else { return [] }
            do {
                data = try await HTTP.get(url, timeout: 30)
                DiskCache.api.put(key, data)
            } catch {
                guard let stale = DiskCache.api.stale(key) else { throw error }
                data = stale
            }
        }
        let rows = (try HTTP.json(data)["films"] as? [Any]) ?? []
        return rows.map { row in (row as? [String: Any]).flatMap { film($0, kind: universe.kind) } }
    }

    /// Картинки у ТВ — полные адреса TMDb; здесь хранятся пути («/abc.jpg»), размер выбирает место показа.
    private static func path(_ url: String) -> String {
        guard let range = url.range(of: "/t/p/") else { return url }
        let tail = url[range.upperBound...]
        guard let slash = tail.firstIndex(of: "/") else { return "" }
        return String(tail[slash...])
    }

    private static func film(_ row: [String: Any], kind: VodKind) -> VodItem? {
        guard let id = row["id"] as? String, let remote = Int(row["remote"] as? String ?? "") else { return nil }
        let rating = Double(Rx("\\d+(?:\\.\\d+)?").groups(row["rating"] as? String ?? "")?[0] ?? "") ?? 0
        let genres = (row["genre"] as? String ?? "").components(separatedBy: " / ").filter { !$0.isEmpty }
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return VodItem(id: id, remoteId: remote, kind: kind, title: row["title"] as? String ?? "", overview: row["about"] as? String ?? "",
                       poster: path(row["poster"] as? String ?? ""), backdrop: path(row["backdrop"] as? String ?? ""),
                       releaseDate: row["year"] as? String ?? "", genres: genres, rating: rating, votes: rating > 0 ? 1000 : 0)
    }
}

/// «Вселенные»: шары разделов — каждый из мозаики своих постеров, медленно вращается; шар → стена раздела.
struct UniversesView: View {
    @State private var spin = false

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 20), GridItem(.flexible(), spacing: 20)], spacing: 28) {
                ForEach(Universe.allCases) { universe in
                    NavigationLink { WallView(universe: universe) } label: {
                        VStack(spacing: 12) {
                            UniverseBall(universe: universe, spin: spin)
                            Text(universe.title).font(.aerial(.headline)).foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
            Text(L("Самые известные работы каждого раздела — стеной постеров. Сведите пальцы, чтобы отдалить, разведите — чтобы рассмотреть; касание — карточка."))
                .font(.aerial(.footnote))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 24)
        }
        .background(Color(hex: 0x050507))
        .navigationTitle(L("Вселенные"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { spin = true }
    }
}

/// Шар: мозаика стены на сфере — едет слева направо (оборот за минуту), края затенены, сверху блик.
private struct UniverseBall: View {
    let universe: Universe
    let spin: Bool

    @State private var atlas: UIImage?

    var body: some View {
        GeometryReader { geometry in
            let side = geometry.size.width
            let width = side * UniverseStore.size.width / UniverseStore.size.height
            ZStack {
                Circle().fill(Color(hex: 0x14171C))
                if let atlas {
                    HStack(spacing: 0) {
                        Image(uiImage: atlas).resizable().frame(width: width, height: side)
                        Image(uiImage: atlas).resizable().frame(width: width, height: side)
                    }
                    .offset(x: spin ? -width / 2 : width / 2)
                    .animation(.linear(duration: 60).repeatForever(autoreverses: false), value: spin)
                    .frame(width: side, height: side)
                }
                // Объём: тень к краям и блик слева сверху.
                Circle().fill(RadialGradient(colors: [.clear, .black.opacity(0.75)], center: .center, startRadius: side * 0.2, endRadius: side * 0.55))
                Circle().fill(RadialGradient(colors: [.white.opacity(0.25), .clear], center: UnitPoint(x: 0.3, y: 0.25),
                                             startRadius: 0, endRadius: side * 0.4))
            }
            .clipShape(Circle())
            .overlay(Circle().stroke(Theme.accent.opacity(0.25), lineWidth: 1))
            .shadow(color: Theme.accent.opacity(0.25), radius: 18)
        }
        .aspectRatio(1, contentMode: .fit)
        .task {
            guard atlas == nil, let url = UniverseStore.atlas(universe) else { return }
            atlas = await ImageLoader.shared.image([url], pixelWidth: 1728)
        }
    }
}

/// Стена раздела: мозаика целиком, зум пальцами; вблизи клетки становятся чёткими постерами; касание — карточка работы.
struct WallView: View {
    let universe: Universe

    @State private var films: [VodItem?] = []
    @State private var atlas: UIImage?
    @State private var selected: VodItem?
    @State private var failed = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(hex: 0x050507).ignoresSafeArea()
            if let atlas, !films.isEmpty {
                WallScroll(atlas: atlas, films: films) { selected = $0 }.ignoresSafeArea(edges: .bottom)
            } else if failed {
                ContentUnavailableView(L("Стена не загрузилась"), systemImage: "wifi.exclamationmark",
                                       description: Text(L("Проверьте сеть и откройте снова.")))
            } else {
                ProgressView(L("Собираю вселенную…")).tint(.white)
            }
            if let selected {
                WallCard(item: selected) { self.selected = nil }
                    .padding(16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: selected?.id)
        .navigationTitle(universe.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard films.isEmpty else { return }
            async let list = UniverseStore.films(universe)
            if let url = UniverseStore.atlas(universe) { atlas = await ImageLoader.shared.image([url], pixelWidth: 1728) }
            do {
                films = try await list
            } catch {
                failed = true
            }
            if atlas == nil { failed = true }
        }
    }
}

/// Карточка работы под линзой: постер, название, год, жанры, оценка — и переход на страницу.
private struct WallCard: View {
    let item: VodItem
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            PosterCard(item: item, width: 84)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title).font(.aerial(.headline)).lineLimit(2)
                Text([item.year, item.genres.prefix(2).joined(separator: ", ")].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.aerial(.caption)).foregroundStyle(Theme.secondaryText)
                Text(item.overview).font(.aerial(.caption)).foregroundStyle(.white.opacity(0.8)).lineLimit(3)
                NavigationLink(value: Route.details(item)) {
                    Text(L("Открыть")).font(.aerial(.subheadline, .semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 16).frame(height: 34).background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            Button(action: onClose) { Image(systemName: "xmark").foregroundStyle(.white.opacity(0.7)) }
        }
        .padding(14)
        .frame(maxWidth: 520)
        .glass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/// UIScrollView с зумом: мозаика — одна картинка; при клетке шире 56 pt поверх видимых клеток встают постеры w185.
private struct WallScroll: UIViewRepresentable {
    let atlas: UIImage
    let films: [VodItem?]
    let onSelect: (VodItem) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(films: films, onSelect: onSelect) }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.backgroundColor = .clear
        scroll.delegate = context.coordinator
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.bouncesZoom = true
        let content = UIImageView(image: atlas)
        content.frame = CGRect(origin: .zero, size: UniverseStore.size)
        content.isUserInteractionEnabled = true
        scroll.addSubview(content)
        scroll.contentSize = UniverseStore.size
        context.coordinator.content = content
        context.coordinator.scroll = scroll
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        content.addGestureRecognizer(tap)
        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        content.addGestureRecognizer(double)
        tap.require(toFail: double)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.layout()
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        let films: [VodItem?]
        let onSelect: (VodItem) -> Void
        weak var content: UIImageView?
        weak var scroll: UIScrollView?
        private var sharp: [Int: UIImageView] = [:]
        private var fitted = CGSize.zero

        init(films: [VodItem?], onSelect: @escaping (VodItem) -> Void) {
            self.films = films
            self.onSelect = onSelect
        }

        /// Издалека — вся стена по высоте экрана; вблизи — клетка до 220 pt.
        func layout() {
            guard let scroll, scroll.bounds.size != fitted, scroll.bounds.height > 0 else { return }
            fitted = scroll.bounds.size
            let fit = min(scroll.bounds.width / UniverseStore.size.width, scroll.bounds.height / UniverseStore.size.height)
            scroll.minimumZoomScale = fit
            scroll.maximumZoomScale = 220 / UniverseStore.cell.width
            // Старт — с середины стены, где самые известные, крупно.
            let start = max(fit, 90 / UniverseStore.cell.width)
            scroll.zoomScale = start
            let size = UniverseStore.size
            scroll.contentOffset = CGPoint(x: max(0, size.width * start / 2 - scroll.bounds.width / 2),
                                           y: max(0, size.height * start / 2 - scroll.bounds.height / 2))
            center()
            refresh()
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            center()
            refresh()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) { refresh() }

        private func center() {
            guard let scroll, let content else { return }
            let x = max(0, (scroll.bounds.width - content.frame.width) / 2)
            let y = max(0, (scroll.bounds.height - content.frame.height) / 2)
            scroll.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        }

        private func cell(at point: CGPoint) -> Int? {
            let column = Int(point.x / UniverseStore.cell.width)
            let row = Int(point.y / UniverseStore.cell.height)
            guard (0..<UniverseStore.columns).contains(column), (0..<UniverseStore.rows).contains(row) else { return nil }
            return row * UniverseStore.columns + column
        }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let content, let index = cell(at: gesture.location(in: content)), index < films.count, let film = films[index] else { return }
            onSelect(film)
        }

        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let scroll, let content else { return }
            let point = gesture.location(in: content)
            if scroll.zoomScale > scroll.minimumZoomScale * 1.5 {
                scroll.setZoomScale(scroll.minimumZoomScale, animated: true)
            } else {
                let scale = min(scroll.maximumZoomScale, 140 / UniverseStore.cell.width)
                let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
                            animated: true)
            }
        }

        /// Видимые клетки при крупном масштабе — чёткими постерами; остальные снимаются, чтобы не держать сотни картинок.
        private func refresh() {
            guard let scroll, let content else { return }
            let scale = scroll.zoomScale
            guard UniverseStore.cell.width * scale >= 56 else {
                sharp.values.forEach { $0.removeFromSuperview() }
                sharp = [:]
                return
            }
            let visible = scroll.convert(scroll.bounds, to: content).insetBy(dx: -UniverseStore.cell.width, dy: -UniverseStore.cell.height)
            let firstColumn = max(0, Int(visible.minX / UniverseStore.cell.width))
            let lastColumn = min(UniverseStore.columns - 1, Int(visible.maxX / UniverseStore.cell.width))
            let firstRow = max(0, Int(visible.minY / UniverseStore.cell.height))
            let lastRow = min(UniverseStore.rows - 1, Int(visible.maxY / UniverseStore.cell.height))
            guard firstColumn <= lastColumn, firstRow <= lastRow else { return }
            var wanted = Set<Int>()
            for row in firstRow...lastRow {
                for column in firstColumn...lastColumn { wanted.insert(row * UniverseStore.columns + column) }
            }
            for (index, view) in sharp where !wanted.contains(index) {
                view.removeFromSuperview()
                sharp[index] = nil
            }
            let pixel = Int(UniverseStore.cell.width * scale * UIScreen.main.scale)
            let size = pixel > 260 ? "w342" : "w185"
            for index in wanted where sharp[index] == nil && index < films.count {
                guard let film = films[index], !film.poster.isEmpty else { continue }
                let column = index % UniverseStore.columns
                let row = index / UniverseStore.columns
                let frame = CGRect(x: CGFloat(column) * UniverseStore.cell.width, y: CGFloat(row) * UniverseStore.cell.height,
                                   width: UniverseStore.cell.width, height: UniverseStore.cell.height).insetBy(dx: 1.5, dy: 1.5)
                let view = UIImageView(frame: frame)
                view.contentMode = .scaleAspectFill
                view.clipsToBounds = true
                view.layer.cornerRadius = 4
                view.alpha = 0
                content.addSubview(view)
                sharp[index] = view
                let urls = TMDbImage.urls(film.poster, size)
                let width = size == "w342" ? 342 : 185
                Task { [weak view] in
                    guard let image = await ImageLoader.shared.image(urls, pixelWidth: width) else { return }
                    view?.image = image
                    UIView.animate(withDuration: 0.2) { view?.alpha = 1 }
                }
            }
        }
    }
}
