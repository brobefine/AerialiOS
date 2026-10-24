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
    @Environment(AppSettings.self) private var settings
    @State private var shelf: VodShelf = .all
    @State private var models: [VodShelf: HomeModel] =
        Dictionary(uniqueKeysWithValues: VodShelf.allCases.map { ($0, HomeModel()) })

    var body: some View {
        NavigationStack {
            TabView(selection: $shelf) {
                ForEach(VodShelf.allCases) { item in
                    ShelfPage(shelf: item, model: models[item] ?? HomeModel()).tag(item)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(Theme.background)
            .safeAreaInset(edge: .top, spacing: 0) {
                ShelfPicker(selection: $shelf).padding(.vertical, 8)
            }
            .toolbar(.hidden, for: .navigationBar)
            .aerialDestinations()
        }
        // Соседи TMDb для подбора — при новых оценках и просмотрах.
        .onChange(of: library.tasteRevision, initial: true) { taste.refresh(library, useHistory: settings.tasteHistory) }
    }
}

private struct ShelfPage: View {
    let shelf: VodShelf
    let model: HomeModel

    @Environment(Library.self) private var library
    @Environment(Taste.self) private var taste
    @Environment(AppSettings.self) private var settings
    @State private var forYou: [VodItem] = []
    @State private var because: [BecauseRow] = []

    private var tasteKey: String {
        "\(library.tasteRevision)|\(taste.related.count)|\(model.version)|\(settings.tasteHistory)"
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                let continuing = library.continueWatching.filter { shelf.accepts($0.item) }
                if !continuing.isEmpty { ContinueShelf(entries: continuing) }
                if !forYou.isEmpty {
                    PosterShelf(title: "Вам понравится?", items: forYou)
                }
                ForEach(because) { row in
                    PosterShelf(title: "Потому что вам понравилось «\(row.seed.title)»", items: row.items)
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
