import SwiftUI

/// Переходы внутри вкладки: каждая вкладка держит свой NavigationStack с этими адресами.
enum Route: Hashable {
    case details(VodItem)
    case section(CinemaSection, VodShelf)
    case person(VodPerson)
    case releases(VodItem, VodEpisode?, runtime: Int)
    case download(String)
}

extension View {
    func aerialDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .details(let item): DetailsView(item: item)
            case .section(let section, let shelf): SectionView(section: section, shelf: shelf)
            case .person(let person): PersonView(person: person)
            case .releases(let item, let episode, let runtime): ReleasesView(item: item, episode: episode, runtime: runtime)
            case .download(let hash): DownloadView(hash: hash)
            }
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
                .font(.system(size: size * 0.32, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Оценка \(String(format: "%.1f", value))")
    }
}

/// Постер 2:3. Без ширины — тянется по ячейке сетки.
struct PosterCard: View {
    let item: VodItem
    var width: CGFloat?
    var showTitle = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay { CachedImage(path: item.poster, size: "w342", pixelWidth: 420) }
                .overlay {
                    if item.poster.isEmpty {
                        Text(item.title).font(.caption.weight(.semibold)).multilineTextAlignment(.center).padding(8)
                    }
                }
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if item.rating > 0 && item.votes >= 10 { RatingRing(value: item.rating, size: 26).padding(5) }
                }
            if showTitle {
                Text(item.title).font(.footnote.weight(.medium)).lineLimit(1)
                Text([item.year, item.kindLabel].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.title)
    }
}

/// Оценка работы, как у ТВ: «Обожаю», «Нравится», «Не моё». Повторный выбор снимает оценку.
enum TasteLevel: Int, CaseIterable, Identifiable {
    case loved = 2, liked = 1, rejected = -1

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .loved: "Обожаю"
        case .liked: "Нравится"
        case .rejected: "Не моё"
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

/// Меню постера по долгому нажатию: «Мой список» и оценка.
struct PosterMenu: View {
    let item: VodItem

    @Environment(Library.self) private var library

    var body: some View {
        Button { library.toggleSaved(item) } label: {
            library.isSaved(item) ? Label("Убрать из списка", systemImage: "checkmark") : Label("В мой список", systemImage: "plus")
        }
        Section("Оценка") { TasteMenuItems(item: item) }
    }
}

/// Постер с номером — «Топ-10», как в ряду «В тренде сегодня».
struct RankedPoster: View {
    let rank: Int
    let item: VodItem
    let width: CGFloat

    var body: some View {
        HStack(alignment: .bottom, spacing: -width * 0.12) {
            Text("\(rank)")
                .font(.system(size: width * 0.95, weight: .black, design: .rounded))
                .foregroundStyle(LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.35)], startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.6), radius: 6)
                .offset(y: width * 0.14)
                .frame(minWidth: width * 0.5)
                .zIndex(0)
            PosterCard(item: item, width: width).zIndex(1)
        }
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
                        Image(systemName: "chevron.right").font(.subheadline.weight(.bold)).foregroundStyle(Theme.secondaryText)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("section-header")
            } else {
                Text(title)
            }
        }
        .font(.title3.weight(.bold))
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
                    Image(systemName: "play.fill").font(.title2).foregroundStyle(.white)
                        .frame(width: 44, height: 44).glass(in: Circle())
                }
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(entry.item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            if let episode = entry.episode {
                Text("\(episode.code) · \(episode.title)").font(.caption).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
            }
            Text(entry.remaining).font(.caption2).foregroundStyle(Theme.secondaryText).lineLimit(1)
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
            ShelfHeader(title: "Продолжить просмотр")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(entries) { entry in
                        Button { playback.resume(entry) } label: {
                            ContinueCard(entry: entry, width: Theme.landscapeWidth(sizeClass))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            NavigationLink(value: Route.details(entry.item)) { Label("Открыть страницу", systemImage: "info.circle") }
                            Button(role: .destructive) { library.forget(entry) } label: {
                                Label("Убрать из «Продолжить»", systemImage: "xmark")
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
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
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
