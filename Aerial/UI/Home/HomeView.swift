import Observation
import SwiftUI

struct HomeRow: Identifiable {
    let section: CinemaSection
    var items: [VodItem] = []
    var id: String { section.id }
}

/// Ряды одного раздела: все запросы сразу, ряд появляется, как только пришёл.
@MainActor @Observable
final class HomeModel {
    private(set) var rows: [HomeRow] = []
    private(set) var failed = false
    /// Растёт с каждой загрузкой рядов — по нему пересчитывается «Вам понравится?».
    private(set) var version = 0
    private var loaded = false

    func load(_ shelf: VodShelf, force: Bool = false) async {
        if loaded && !force { return }
        let sections = Catalogue.sections(for: shelf)
        if rows.isEmpty { rows = sections.map { HomeRow(section: $0) } }
        failed = false
        await withTaskGroup(of: (String, [VodItem]?).self) { group in
            for section in sections {
                group.addTask { (section.id, try? await Catalogue.shared.section(section).items) }
            }
            for await (id, items) in group {
                guard let items, let index = rows.firstIndex(where: { $0.id == id }) else { continue }
                rows[index].items = items.filter(shelf.accepts)
            }
        }
        rows.removeAll { $0.items.isEmpty }
        failed = rows.isEmpty
        loaded = !failed
        version += 1
    }
}

/// Главная: разделы капсулами сверху; между разделами — свайпом влево-вправо по странице (ряды листаются своим
/// жестом, раздел переключает свайп по заголовкам и промежуткам между рядами).
struct HomeView: View {
    @Environment(Library.self) private var library
    @Environment(Taste.self) private var taste
    @Environment(Feeds.self) private var feeds
    @Environment(AppSettings.self) private var settings
    @State private var shelf: VodShelf = .all
    @State private var models: [VodShelf: HomeModel] =
        Dictionary(uniqueKeysWithValues: VodShelf.allCases.map { ($0, HomeModel()) })

    var body: some View {
        NavigationStack {
            // Страницы `TabView` обрезаются по безопасной зоне — сверху и снизу оставались чёрные полосы. Поэтому
            // страницы во весь экран, а отступы под капсулы разделов и нижнюю пилюлю — полями прокрутки. Капсулы —
            // отдельным слоем поверх, в безопасной зоне: наложение на растянутый `TabView` прыгало вниз при касании.
            GeometryReader { geometry in
                ZStack(alignment: .top) {
                    TabView(selection: $shelf) {
                        ForEach(VodShelf.allCases) { item in
                            ShelfPage(shelf: item, model: models[item] ?? HomeModel(),
                                      insets: EdgeInsets(top: geometry.safeAreaInsets.top + Self.pickerHeight, leading: 0,
                                                         bottom: geometry.safeAreaInsets.bottom, trailing: 0))
                                .tag(item)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .ignoresSafeArea()
                    LinearGradient(colors: [Theme.background, Theme.background.opacity(0.85), .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: geometry.safeAreaInsets.top + Self.pickerHeight + 12)
                        .ignoresSafeArea(edges: .top)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .allowsHitTesting(false)
                    ShelfPicker(selection: $shelf)
                        .padding(.vertical, 8)
                }
            }
            .background(Theme.background)
            .toolbar(.hidden, for: .navigationBar)
            .aerialDestinations()
        }
        // Соседи TMDb для подбора — при новых оценках и просмотрах.
        .onChange(of: library.tasteRevision, initial: true) {
            taste.refresh(library, useHistory: settings.tasteHistory)
            taste.refreshAI(library, useHistory: settings.tasteHistory, moods: settings.aiMoodShelves)
            feeds.refreshFourK(settings)
        }
        .task(id: library.tasteRevision) { await feeds.refreshUpcoming(library) }
        .task(id: library.followed.map(\.id)) { await feeds.refreshFollowed(library) }
    }

    /// Высота полосы капсул разделов с отступами.
    static let pickerHeight: CGFloat = 52
}

private struct ShelfPage: View {
    let shelf: VodShelf
    let model: HomeModel
    let insets: EdgeInsets

    @Environment(Library.self) private var library
    @Environment(Taste.self) private var taste
    @Environment(Feeds.self) private var feeds
    @Environment(AppSettings.self) private var settings
    @State private var forYou: [VodItem] = []
    @State private var because: [BecauseRow] = []

    private var tasteKey: String {
        "\(library.tasteRevision)|\(taste.related.count)|\(model.version)|\(settings.tasteHistory)|\(taste.aiPicks.count)"
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                let continuing = library.continueWatching.filter { shelf.accepts($0.item) }
                if !continuing.isEmpty { ContinueShelf(entries: continuing) }
                if !forYou.isEmpty {
                    PosterShelf(title: "Вам понравится?", items: forYou)
                }
                if settings.aiMoodShelves && AI.enabled {
                    ForEach(taste.aiShelves) { row in
                        let items = row.items.filter(shelf.accepts)
                        if items.count >= 3 { PosterShelf(title: row.title, items: items) }
                    }
                }
                let fourK = feeds.fourK.filter(shelf.accepts)
                if fourK.count >= 3 { PosterShelf(title: "Вышли в 4K", items: fourK) }
                ForEach(because) { row in
                    PosterShelf(title: "Потому что вам понравилось «\(row.seed.title)»", items: row.items)
                }
                let upcoming = feeds.upcoming.filter { shelf.accepts($0.item) }
                if !upcoming.isEmpty && (shelf == .all || shelf == .series || shelf == .cartoonSeries) {
                    UpcomingShelf(episodes: upcoming)
                }
                let followed = feeds.followed.filter(shelf.accepts)
                if !followed.isEmpty {
                    PosterShelf(title: "Новое с вашими актёрами", items: followed)
                }
                if model.failed {
                    ContentUnavailableView {
                        Label("Каталог не загрузился", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(TMDb.shared.configured ? "Проверьте сеть и потяните вниз, чтобы повторить." : "В сборке нет ключа TMDb.")
                    }
                }
                ForEach(model.rows) { row in
                    PosterShelf(title: row.section.title, items: row.items, ranked: row.section.ranked,
                                seeAll: .section(row.section, shelf))
                }
            }
            .padding(.vertical, 12)
        }
        .contentMargins(.top, insets.top, for: .scrollContent)
        .contentMargins(.bottom, insets.bottom + 12, for: .scrollContent)
        .contentMargins(.top, insets.top, for: .scrollIndicators)
        .refreshable { await model.load(shelf, force: true) }
        .task { await model.load(shelf) }
        .task(id: tasteKey) { updateTaste() }
    }

    /// «Вам понравится?» из рядов раздела и соседей TMDb; «Потому что…» не повторяет первое, что уже видно в нём.
    private func updateTaste() {
        let found = taste.forYou(shelf, pool: model.rows.flatMap(\.items), library: library, useHistory: settings.tasteHistory)
        let head = Set(found.prefix(10).map(\.id))
        forYou = found
        because = taste.because(library).compactMap { row in
            let items = row.items.filter { shelf.accepts($0) && !head.contains($0.id) }
            return items.count >= 5 ? BecauseRow(seed: row.seed, items: items) : nil
        }
    }
}

/// Разделы кинотеки капсулами: «Всё», «Фильмы», «Сериалы», «Мультфильмы», «Мультсериалы»; выбранный — всегда на виду.
struct ShelfPicker: View {
    @Binding var selection: VodShelf

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(VodShelf.allCases) { shelf in
                        Chip(title: shelf.title, selected: shelf == selection) {
                            withAnimation(.snappy) { selection = shelf }
                        }
                        .id(shelf)
                        .accessibilityIdentifier("shelf-\(shelf.rawValue)")
                    }
                }
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .scrollIndicators(.hidden)
            .onChange(of: selection) { _, value in
                withAnimation(.snappy) { proxy.scrollTo(value, anchor: .center) }
            }
        }
    }
}

/// Капсула выбора: выбранная — белая, остальные — на стекле.
struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            let label = Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? .black : .white)
                .padding(.horizontal, 16)
                .frame(height: 36)
            if selected {
                label.background(.white, in: Capsule())
            } else {
                label.glass(in: Capsule(), interactive: true)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Логотип-название TMDb; нет логотипа — название крупным шрифтом.
struct TitleArt: View {
    let title: String
    let logo: String
    var maxHeight: CGFloat = 100

    var body: some View {
        if logo.isEmpty {
            Text(title)
                .font(.system(size: 32, weight: .heavy))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.6)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 8)
        } else {
            CachedImage(path: logo, size: "w500", pixelWidth: 900, contentMode: .fit)
                .frame(maxWidth: 300, maxHeight: maxHeight)
                .shadow(color: .black.opacity(0.4), radius: 10)
                .accessibilityLabel(title)
        }
    }
}

/// «Скоро новые серии»: кадр серии (или сериала), дата и сколько ждать; касание — страница сериала.
struct UpcomingShelf: View {
    let episodes: [UpcomingEpisode]

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let width = Theme.landscapeWidth(sizeClass)
        VStack(alignment: .leading, spacing: 10) {
            ShelfHeader(title: "Скоро новые серии")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(episodes) { episode in
                        NavigationLink(value: Route.details(episode.item)) {
                            VStack(alignment: .leading, spacing: 6) {
                                Color.clear
                                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                                    .overlay {
                                        CachedImage(path: episode.still.isEmpty ? episode.item.backdrop : episode.still,
                                                    size: "w780", pixelWidth: Int(width * 3))
                                    }
                                    .overlay(alignment: .topLeading) {
                                        Text(Self.when(episode.date))
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(.black)
                                            .padding(.horizontal, 10)
                                            .frame(height: 26)
                                            .background(Theme.accent, in: Capsule())
                                            .padding(8)
                                    }
                                    .background(Theme.card)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                Text(episode.item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text([episode.code, episode.title].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                                Text(Format.date(episode.date)).font(.caption2).foregroundStyle(Theme.secondaryText)
                            }
                            .frame(width: width)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { PosterMenu(item: episode.item) }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned(limitBehavior: .never))
            .scrollIndicators(.hidden)
        }
    }

    /// «Сегодня», «Завтра», «Через 5 дн.».
    static func when(_ iso: String) -> String {
        let calendar = Calendar.current
        guard let date = ISO8601DateFormatter.day.date(from: String(iso.prefix(10))) else { return iso }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: .now), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case ..<1: return "Сегодня"
        case 1: return "Завтра"
        default: return "Через \(days) \(Format.plural(days, "день", "дня", "дней"))"
        }
    }
}
