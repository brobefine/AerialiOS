import Observation
import SwiftUI

struct HomeRow: Identifiable {
    let section: CinemaSection
    var items: [VodItem] = []
    var id: String { section.id }
}

/// Ряды главной по разделу: все запросы сразу, ряд появляется, как только пришёл.
@MainActor @Observable
final class HomeModel {
    private(set) var rows: [HomeRow] = []
    private(set) var hero: [VodItem] = []
    private(set) var failed = false
    private var loaded: VodShelf?

    func load(_ shelf: VodShelf, force: Bool = false) async {
        if !force, loaded == shelf, !rows.isEmpty { return }
        let sections = Catalogue.sections(for: shelf)
        if loaded != shelf {
            rows = sections.map { HomeRow(section: $0) }
            hero = []
        }
        failed = false
        await withTaskGroup(of: (String, [VodItem]?).self) { group in
            for section in sections {
                group.addTask { (section.id, try? await Catalogue.shared.section(section).items) }
            }
            for await (id, items) in group {
                guard !Task.isCancelled else { break }
                guard let items, let index = rows.firstIndex(where: { $0.id == id }) else { continue }
                rows[index].items = items.filter(shelf.accepts)
                if index == 0 { hero = Array(rows[0].items.filter { !$0.backdrop.isEmpty }.prefix(6)) }
            }
        }
        guard !Task.isCancelled else { return }
        rows.removeAll { $0.items.isEmpty }
        if hero.isEmpty { hero = Array((rows.first?.items ?? []).filter { !$0.backdrop.isEmpty }.prefix(6)) }
        failed = rows.isEmpty
        loaded = shelf
    }
}

/// Главная в духе Apple TV: большая карусель сверху, под ней разделы и ряды.
struct HomeView: View {
    @Environment(Library.self) private var library
    @State private var model = HomeModel()
    @State private var shelf: VodShelf = .all
    @State private var settingsOpen = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    HeroCarousel(items: model.hero)
                    ShelfPicker(selection: $shelf)
                    let continuing = library.continueWatching
                    if !continuing.isEmpty && shelf == .all {
                        ContinueShelf(entries: continuing)
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
                .padding(.bottom, 24)
            }
            .ignoresSafeArea(edges: .top)
            .background(Theme.background)
            .refreshable { await model.load(shelf, force: true) }
            .task(id: shelf) { await model.load(shelf) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { settingsOpen = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Настройки")
                        .accessibilityIdentifier("settings")
                }
            }
            .clearNavigationBar()
            .sheet(isPresented: $settingsOpen) { SettingsView() }
            .aerialDestinations()
        }
    }
}

/// Разделы кинотеки капсулами: «Всё», «Фильмы», «Сериалы», «Мультфильмы», «Мультсериалы».
struct ShelfPicker: View {
    @Binding var selection: VodShelf

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(VodShelf.allCases) { shelf in
                    let selected = shelf == selection
                    Button {
                        withAnimation(.snappy) { selection = shelf }
                    } label: {
                        Text(shelf.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(selected ? .black : .white)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.12)), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("shelf-\(shelf.rawValue)")
                }
            }
        }
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .scrollIndicators(.hidden)
    }
}

/// Карусель-шапка: кадр во всю ширину, логотип, «Смотреть» и «+», точки страниц; листается сама каждые 7 с.
struct HeroCarousel: View {
    let items: [VodItem]

    @Environment(Library.self) private var library
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var index = 0
    @State private var logos: [String: String] = [:]

    private var height: CGFloat { sizeClass == .regular ? 600 : 520 }

    var body: some View {
        ZStack(alignment: .bottom) {
            if items.isEmpty {
                Theme.card.opacity(0.4)
            } else {
                TabView(selection: $index) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { position, item in
                        NavigationLink(value: Route.details(item)) {
                            HeroPage(item: item, logo: logos[item.id] ?? "")
                        }
                        .buttonStyle(.plain)
                        .tag(position)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                controls
            }
        }
        .frame(height: height)
        .task(id: items.map(\.id)) {
            index = 0
            await withTaskGroup(of: (String, String).self) { group in
                for item in items { group.addTask { (item.id, await Catalogue.shared.logo(item)) } }
                for await (id, logo) in group where !logo.isEmpty { logos[id] = logo }
            }
        }
        .task(id: items.count) {
            guard items.count > 1, !UITestHooks.active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(7))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.6)) { index = (index + 1) % items.count }
            }
        }
    }

    @ViewBuilder private var controls: some View {
        if items.indices.contains(index) {
            let item = items[index]
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    NavigationLink(value: item.kind == .movie ? Route.releases(item, nil, runtime: 0) : Route.details(item)) {
                        Label("Смотреть", systemImage: "play.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("hero-watch")
                    Button { library.toggleSaved(item) } label: {
                        Image(systemName: library.isSaved(item) ? "checkmark" : "plus")
                    }
                    .buttonStyle(CircleGlassButtonStyle())
                    .accessibilityLabel(library.isSaved(item) ? "Убрать из списка" : "В мой список")
                }
                .frame(maxWidth: 360)
                HStack(spacing: 6) {
                    ForEach(items.indices, id: \.self) { dot in
                        Capsule()
                            .fill(dot == index ? .white : .white.opacity(0.35))
                            .frame(width: dot == index ? 18 : 6, height: 6)
                    }
                }
                .animation(.snappy, value: index)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 14)
        }
    }
}

private struct HeroPage: View {
    let item: VodItem
    let logo: String

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
                .overlay { CachedImage(path: item.backdrop, size: "w1280", pixelWidth: 1600) }
                .clipped()
            LinearGradient(stops: [
                .init(color: .black.opacity(0.35), location: 0),
                .init(color: .clear, location: 0.25),
                .init(color: Theme.background.opacity(0.7), location: 0.62),
                .init(color: Theme.background, location: 1),
            ], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 8) {
                TitleArt(title: item.title, logo: logo, maxHeight: 90)
                Text([item.kindLabel, item.year, item.genres.prefix(2).joined(separator: ", ")].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 92)
        }
        .contentShape(Rectangle())
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
