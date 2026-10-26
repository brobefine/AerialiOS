import SwiftUI

/// Переходы внутри вкладки: каждая вкладка держит свой NavigationStack с этими адресами.
enum Route: Hashable {
    case details(VodItem)
    case section(CinemaSection, VodShelf)
    case person(VodPerson)
    case releases(VodItem, VodEpisode?, runtime: Int)
    case download(String)
    case friends
    case universes
    case torrents
}

extension View {
    func aerialDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .details(let item): DetailsView(item: item)
            case .section(let section, let shelf): SectionView(section: section, shelf: shelf)
            case .person(let person): PersonView(person: person)
            case .torrents: TorrentsView()
            case .releases(let item, let episode, let runtime): ReleasesView(item: item, episode: episode, runtime: runtime)
            case .download(let hash): DownloadView(hash: hash)
            case .friends: FriendsView()
            case .universes: UniversesView()
            }
        }
    }
}

/// Картинка с прогрессивным размытием вниз (`ProgressiveBlur`): кадр серии или постер и его размытое продолжение —
/// одна готовая картинка из кэша, посчитанная в фоне. Пока не готова — чёткая картинка. Рисует и саму картинку: её низ
/// теряет фокус вместе с продолжением.
struct MirrorBackdrop: View {
    let path: String
    let size: String
    let pixelWidth: Int
    let width: CGFloat
    /// Высота картинки над подписью.
    let height: CGFloat

    @Environment(\.displayScale) private var scale
    @State private var baked: UIImage?

    var body: some View {
        let key = ProgressiveBlur.key(path, width, height)
        ZStack(alignment: .top) {
            if let image = baked ?? ProgressiveBlur.cached(key) {
                Image(uiImage: image).resizable().frame(width: width, height: height * 2)
            } else {
                CachedImage(path: path, size: size, pixelWidth: pixelWidth).frame(width: width, height: height).clipped()
            }
        }
        .frame(width: width, height: height * 2, alignment: .top)
        .clipped()
        .allowsHitTesting(false)
        .task(id: key) {
            guard ProgressiveBlur.cached(key) == nil,
                  let source = await ImageLoader.shared.image(TMDbImage.urls(path, size), pixelWidth: pixelWidth) else { return }
            let (w, h, s) = (width, height, scale)
            baked = await Task.detached(priority: .utility) {
                ProgressiveBlur.make(source, width: w, height: h, scale: s, key: key)
            }.value
        }
    }
}

/// Кольцо оценки TMDb с цветом по доле — как `RatingRing` ТВ.
struct RatingRing: View {
    let value: Double
    var size: CGFloat = 28

    var body: some View {
        let share = min(1, max(0, value / 10))
        let line = max(2, size * 0.09)
        ZStack {
            Circle().fill(.black.opacity(0.75))
            Circle().stroke(.white.opacity(0.15), lineWidth: line).padding(line / 2 + 1)
            Circle()
                .trim(from: 0, to: share)
                .stroke(Theme.rating(share), style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(line / 2 + 1)
            Text(String(format: "%.1f", value))
                .font(.aerial(size: size * 0.32, .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(L("Оценка %@", String(format: "%.1f", value)))
    }
}

/// Постер 2:3. Без ширины — тянется по ячейке сетки. Название и строка «год · Сериал» — на самом постере, как на ТВ
/// и ПК (`posterInfo`): низ постера прогрессивно размыт (`ProgressiveBlur`), значок сериала — наверху слева на тёмной плашке.
struct PosterCard: View {
    let item: VodItem
    var width: CGFloat?
    /// Сведения на постере; без них — только картинка.
    var info = true
    /// Картинку рисует подложка (`MirrorBackdrop`, постер с продолжением вниз): здесь — только сведения, без своего размытия.
    var artwork = true
    /// Скругление только сверху: под постером продолжается карточка (описание «Духовных родственников»).
    var squareBottom = false


    var body: some View {
        Color.clear
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay { if artwork { CachedImage(path: item.poster, size: "w342", pixelWidth: 420) } }
            .overlay { if info && !item.poster.isEmpty { infoBand } }
            .overlay {
                if item.poster.isEmpty {
                    Text(item.title).font(.aerial(.caption, .semibold)).multilineTextAlignment(.center).padding(8)
                }
            }
            .overlay(alignment: .topLeading) {
                if info && item.kind == .series {
                    Image(systemName: "tv").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 28, height: 24).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 6)).padding(6)
                }
            }
            .background(artwork ? Theme.card : .clear)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: squareBottom ? 0 : 10,
                                              bottomTrailingRadius: squareBottom ? 0 : 10, topTrailingRadius: 10,
                                              style: .continuous))
            .overlay(alignment: info ? .topTrailing : .bottomTrailing) {
                if item.rating > 0 && item.votes >= 10 { RatingRing(value: item.rating, size: 26).padding(5) }
            }
            .frame(width: width)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(item.title)
    }

    /// Размытый низ постера, затухающий вверх (плавно, полная сила к 70 % полосы — как `VodFrost.drawFading`), и подписи.
    private var infoBand: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            ZStack(alignment: .bottomLeading) {
                // Низ постера — то же прогрессивное размытие, что у серий (`ProgressiveBlur`, без продолжения вниз).
                if artwork { PosterProgressive(path: item.poster, width: geometry.size.width, height: height) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.aerial(.footnote, .semibold)).lineLimit(1)
                    let meta = [item.year, item.kind == .series ? L("Сериал") : ""].filter { !$0.isEmpty }.joined(separator: " · ")
                    if !meta.isEmpty { Text(meta).font(.aerial(.caption2)).foregroundStyle(.white.opacity(0.85)).lineLimit(1) }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.bottom, 9)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Постер с прогрессивно размытым низом (`ProgressiveBlur`, `mirror: false`) — готовой картинкой из кэша, посчитанной в
/// фоне; пока не готова — ничего (под ней чёткий постер).
private struct PosterProgressive: View {
    let path: String
    let width: CGFloat
    let height: CGFloat

    @Environment(\.displayScale) private var scale
    @State private var baked: UIImage?

    var body: some View {
        let key = ProgressiveBlur.key("poster|" + path, width, height)
        ZStack {
            if let image = baked ?? ProgressiveBlur.cached(key) {
                Image(uiImage: image).resizable().frame(width: width, height: height)
            }
        }
        .task(id: key) {
            guard width > 0, ProgressiveBlur.cached(key) == nil,
                  let source = await ImageLoader.shared.image(TMDbImage.urls(path, "w342"), pixelWidth: 420) else { return }
            let (w, h, s) = (width, height, scale)
            baked = await Task.detached(priority: .utility) {
                ProgressiveBlur.make(source, width: w, height: h, scale: s, key: key, mirror: false)
            }.value
        }
    }
}

/// Оценка работы, как у ТВ: «Обожаю», «Нравится», «Не моё». Повторный выбор снимает оценку.
enum TasteLevel: Int, CaseIterable, Identifiable {
    case loved = 2, liked = 1, rejected = -1

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .loved: L("Обожаю")
        case .liked: L("Нравится")
        case .rejected: L("Не моё")
        }
    }
    var symbol: String {
        switch self {
        case .loved: "heart"
        case .liked: "hand.thumbsup"
        case .rejected: "hand.thumbsdown"
        }
    }

    /// Значок кнопки оценки: выбранная — закрашенным, без оценки — пустой палец вверх.
    static func symbol(_ level: Int) -> String {
        TasteLevel(rawValue: level).map { $0.symbol + ".fill" } ?? "hand.thumbsup"
    }
}

/// Пункты оценки — для меню кнопки на странице фильма и меню постера.
struct TasteMenuItems: View {
    let item: VodItem

    @Environment(Library.self) private var library

    var body: some View {
        let current = library.rating(item)
        ForEach(TasteLevel.allCases) { level in
            Button {
                library.rate(item, current == level.rawValue ? 0 : level.rawValue)
            } label: {
                Label(level.title, systemImage: current == level.rawValue ? level.symbol + ".fill" : level.symbol)
            }
        }
    }
}

/// «Мой список», как на ТВ: «Смотреть позже» и оценка («Не моё», «Нравится», «Обожаю»); меню постера и кнопка страницы.
struct PosterMenu: View {
    let item: VodItem

    @Environment(Library.self) private var library

    var body: some View {
        Button { library.toggleSaved(item) } label: {
            Label(library.isSaved(item) ? L("Убрать из «Смотреть позже»") : L("Смотреть позже"),
                  systemImage: library.isSaved(item) ? "bookmark.fill" : "bookmark")
        }
        // Как на ТВ: сразу после «Смотреть позже» — убрать из «Продолжить».
        if let entry = library.latest(for: item), entry.resumable {
            Button(role: .destructive) { library.forget(entry) } label: {
                Label(L("Убрать из «Продолжить»"), systemImage: "xmark")
            }
        }
        Section(L("Оценка")) { TasteMenuItems(item: item) }
    }
}

/// Постер с номером — «Топ-10», как в ряду «В тренде сегодня».
struct RankedPoster: View {
    let rank: Int
    let item: VodItem
    let width: CGFloat

    /// Цвет постера; пока не посчитан — белый, как на ТВ.
    @State private var accent: Color?

    var body: some View {
        // Как `drawRanks` ТВ: цифра цветом постера — сверху сплошным, к низу тает (0.6 на середине, 0.1 у низа),
        // без контура и тени; правым краем на 14 % под постером.
        let color = accent ?? .white
        HStack(alignment: .bottom, spacing: -width * 0.14) {
            Text("\(rank)")
                .font(.aerial(size: width * 0.95, .black))
                .kerning(rank >= 10 ? -width * 0.06 : 0)
                .foregroundStyle(LinearGradient(stops: [.init(color: color, location: 0), .init(color: color.opacity(0.6), location: 0.55),
                                                        .init(color: color.opacity(0.1), location: 1)],
                                                startPoint: .top, endPoint: .bottom))
                .offset(y: width * 0.14)
                .frame(minWidth: width * 0.5)
                .zIndex(0)
            PosterCard(item: item, width: width).zIndex(1)
        }
        .task(id: item.poster) { accent = await PosterPalette.accent(item.poster) }
    }
}

/// Ряд постеров с заголовком-ссылкой «Смотреть всё»; пока данных нет — серые заглушки.
struct PosterShelf: View {
    let title: String
    let items: [VodItem]
    var ranked = false
    var seeAll: Route?

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let width = Theme.posterWidth(sizeClass)
        VStack(alignment: .leading, spacing: 10) {
            ShelfHeader(title: title, destination: seeAll)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .bottom, spacing: 12) {
                    if items.isEmpty {
                        ForEach(0..<6, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card)
                                .frame(width: width, height: width * 1.5)
                        }
                    }
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        NavigationLink(value: Route.details(item)) {
                            if ranked && index < 10 {
                                RankedPoster(rank: index + 1, item: item, width: width)
                            } else {
                                PosterCard(item: item, width: width)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("poster")
                        .contextMenu { PosterMenu(item: item) }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned(limitBehavior: .never))
            .scrollIndicators(.hidden)
        }
    }
}

struct ShelfHeader: View {
    let title: String
    var destination: Route?

    var body: some View {
        Group {
            if let destination {
                NavigationLink(value: destination) {
                    HStack(spacing: 4) {
                        Text(title)
                        Image(systemName: "chevron.right").font(.aerial(.subheadline, .bold)).foregroundStyle(Theme.secondaryText)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("section-header")
            } else {
                Text(title)
            }
        }
        .font(.aerial(.title3, .bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
    }
}

/// Карточка «Продолжить»: кадр, полоса просмотра, название и сколько осталось.
struct ContinueCard: View {
    let entry: WatchEntry
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay {
                    let still = entry.episode?.still ?? ""
                    CachedImage(path: still.isEmpty ? entry.item.backdrop : still, size: "w780", pixelWidth: Int(width * 3))
                }
                .overlay(alignment: .bottom) {
                    ZStack(alignment: .bottomLeading) {
                        LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.3))
                                Capsule().fill(.white).frame(width: geometry.size.width * entry.fraction)
                            }
                        }
                        .frame(height: 4)
                        .padding(10)
                    }
                }
                .overlay {
                    Image(systemName: "play.fill").font(.aerial(.title2)).foregroundStyle(.white)
                        .frame(width: 44, height: 44).glass(in: Circle())
                }
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(entry.item.title).font(.aerial(.subheadline, .semibold)).lineLimit(1)
            if let episode = entry.episode {
                Text("\(episode.code) · \(episode.title)").font(.aerial(.caption)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
            }
            Text(entry.remaining).font(.aerial(.caption2)).foregroundStyle(Theme.secondaryText).lineLimit(1)
        }
        .frame(width: width)
    }
}

/// Ряд «Продолжить»: касание — сразу в плеер с той же раздачей; меню — убрать или открыть страницу.
struct ContinueShelf: View {
    let entries: [WatchEntry]

    @Environment(Library.self) private var library
    @Environment(Playback.self) private var playback
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ShelfHeader(title: L("Продолжить просмотр"))
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(entries) { entry in
                        Button { playback.resume(entry) } label: {
                            ContinueCard(entry: entry, width: Theme.landscapeWidth(sizeClass))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            NavigationLink(value: Route.details(entry.item)) { Label(L("Открыть страницу"), systemImage: "info.circle") }
                            Button(role: .destructive) { library.forget(entry) } label: {
                                Label(L("Убрать из «Продолжить»"), systemImage: "xmark")
                            }
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned(limitBehavior: .never))
            .scrollIndicators(.hidden)
        }
    }
}

/// Раскладка «по строкам с переносом» — для плашек раздач и жанров.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: rows.map { $0.width }.max() ?? 0,
                      height: rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for index in row.indices {
                // Не шире строки: длинная капсула иначе вылезала за экран и раздвигала всю страницу.
                let size = clamped(subviews[index], bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func clamped(_ subview: LayoutSubview, _ width: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        guard width.isFinite, ideal.width > width else { return ideal }
        return subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = clamped(subviews[index], width)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = ([index], size.width, size.height)
            } else {
                current = (current.indices + [index], needed, max(current.height, size.height))
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
