import SwiftUI

/// Поиск фильмов и сериалов; пока запрос пуст — «Популярно сейчас».
struct SearchView: View {
    @State private var query = ""
    @State private var results: [VodItem] = []
    @State private var popular: [VodItem] = []
    @State private var searching = false

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if trimmed.isEmpty && !popular.isEmpty {
                        Text("Популярно сейчас").font(.title3.weight(.bold)).padding(.horizontal, 16)
                    }
                    PosterGrid(items: trimmed.isEmpty ? popular : results)
                }
                .padding(.vertical, 8)
            }
            .background(Theme.background)
            .overlay {
                if searching && results.isEmpty {
                    ProgressView().tint(.white)
                } else if !trimmed.isEmpty && !searching && results.isEmpty {
                    ContentUnavailableView.search(text: trimmed)
                }
            }
            .navigationTitle("Поиск")
            .searchable(text: $query, prompt: "Фильмы и сериалы")
            .task(id: trimmed) {
                guard trimmed.count >= 2 else {
                    results = []
                    return
                }
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                searching = true
                let found = (try? await Catalogue.shared.search(trimmed)) ?? []
                guard !Task.isCancelled else { return }
                results = found
                searching = false
            }
            .task {
                guard popular.isEmpty else { return }
                let trending = CinemaSection(id: "search-trending", title: "", path: "trending/all/day", kind: .movie)
                // Общий тренд смешивает фильмы и сериалы — вид берём из ответа.
                if let page = try? await TMDb.shared.decode(TMDbPage.self, trending.path, ttl: 6 * DiskCache.hour) {
                    popular = page.results.compactMap { $0.item(kind: nil, genres: [:]) }
                }
            }
            .aerialDestinations()
        }
    }
}

/// Сетка постеров с названиями.
struct PosterGrid: View {
    let items: [VodItem]
    var onAppearLast: (() -> Void)?

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let width = Theme.posterWidth(sizeClass)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: width - 12, maximum: width + 30), spacing: 12, alignment: .top)],
                  alignment: .leading, spacing: 18) {
            ForEach(items) { item in
                NavigationLink(value: Route.details(item)) {
                    PosterCard(item: item, showTitle: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("poster")
                .onAppear { if item.id == items.last?.id { onAppearLast?() } }
            }
        }
        .padding(.horizontal, 16)
    }
}

/// «Смотреть всё» для ряда: сетка со страницами TMDb по мере прокрутки.
struct SectionView: View {
    let section: CinemaSection
    let shelf: VodShelf

    @State private var items: [VodItem] = []
    @State private var page = 0
    @State private var pages = 1
    @State private var loading = false

    var body: some View {
        ScrollView {
            PosterGrid(items: items) { Task { await more() } }
                .padding(.vertical, 12)
            if loading { ProgressView().tint(.white).padding() }
        }
        .background(Theme.background)
        .navigationTitle(section.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { if items.isEmpty { await more() } }
    }

    private func more() async {
        guard !loading, page < min(pages, 20) else { return }
        loading = true
        defer { loading = false }
        guard let result = try? await Catalogue.shared.section(section, page: page + 1) else { return }
        page += 1
        pages = result.pages
        var seen = Set(items.map(\.id))
        items += result.items.filter { shelf.accepts($0) && seen.insert($0.id).inserted }
    }
}

/// Актёр или режиссёр: фото, сведения, биография и фильмография.
struct PersonView: View {
    let person: VodPerson

    @State private var info: VodPersonInfo?
    @State private var expanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 16) {
                    Color.clear
                        .frame(width: 110, height: 160)
                        .overlay { CachedImage(path: info?.photo ?? person.photo, size: "w342", pixelWidth: 360) }
                        .background(Theme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(info?.name ?? person.name).font(.title2.weight(.bold))
                        if let info {
                            if !info.birthday.isEmpty { Text("Дата рождения: \(Format.date(info.birthday))").font(.subheadline) }
                            if !info.place.isEmpty { Text(info.place).font(.subheadline).foregroundStyle(Theme.secondaryText) }
                        }
                    }
                }
                .padding(.horizontal, 16)
                if let biography = info?.biography, !biography.isEmpty {
                    Text(biography)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(expanded ? nil : 6)
                        .onTapGesture { withAnimation(.easeOut) { expanded.toggle() } }
                        .padding(.horizontal, 16)
                }
                if let works = info?.works, !works.isEmpty {
                    ShelfHeader(title: "Фильмография")
                    PosterGrid(items: works)
                }
            }
            .padding(.vertical, 12)
        }
        .background(Theme.background)
        .navigationTitle(person.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { if info == nil { info = try? await Catalogue.shared.person(person) } }
    }
}

/// Медиатека: «Продолжить просмотр» и «Мой список».
struct LibraryView: View {
    @Environment(Library.self) private var library

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    let continuing = library.continueWatching
                    if !continuing.isEmpty { ContinueShelf(entries: continuing) }
                    if !library.saved.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            ShelfHeader(title: "Мой список")
                            PosterGrid(items: library.saved)
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            .background(Theme.background)
            .overlay {
                if library.saved.isEmpty && library.continueWatching.isEmpty {
                    ContentUnavailableView("Здесь пока пусто", systemImage: "rectangle.stack",
                                           description: Text("Добавляйте фильмы кнопкой «+», а начатое появится в «Продолжить»."))
                }
            }
            .navigationTitle("Медиатека")
            .aerialDestinations()
        }
    }
}
