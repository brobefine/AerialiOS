import SwiftUI

/// Поиск фильмов и сериалов; пока запрос пуст — недавние запросы и «Популярно сейчас». Под полем — подсказки
/// с исправлением раскладки и опечаток ([Suggestions]).
struct SearchView: View {
    @Environment(Library.self) private var library
    @State private var query = ""
    @State private var results: [VodItem] = []
    @State private var popular: [VodItem] = []
    @State private var searching = false
    @AppStorage("search.recent") private var recentRaw = ""
    /// Что в выдаче подобрал ИИ по описанию.
    @State private var aiPicked: Set<String> = []
    @State private var aiThinking = false
    @State private var aiNote: String?

    /// Описание своими словами → до пяти работ TMDb.
    private static func describe(_ text: String) async -> Result<[VodItem], Error> {
        do {
            let titles = try await AI.find(text)
            return .success(await Taste.resolve(Array(titles.prefix(5))))
        } catch {
            return .failure(error)
        }
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var recent: [String] { recentRaw.split(separator: "\n").map(String.init) }

    /// Подсказки — только когда поиск ничего не нашёл (опечатка, не та раскладка): iOS показывает их вместо
    /// содержимого, и найденное иначе было бы не видно, пока открыта клавиатура.
    private var suggestions: [String] {
        guard !trimmed.isEmpty, results.isEmpty, !searching else { return [] }
        var seen = Set<String>()
        let titles = (results + popular + library.saved + library.likedItems + library.continueWatching.map(\.item))
            .filter { seen.insert($0.id).inserted }
            .map { Suggestions.Title(title: $0.title, original: $0.originalTitle) }
        return Suggestions.rank(trimmed, titles: titles, recent: recent).filter { Suggestions.key($0) != Suggestions.key(trimmed) }
    }

    /// Запрос отправлен — в начало недавних (до 10, без повторов).
    private func remember(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2 else { return }
        let rest = recent.filter { Suggestions.key($0) != Suggestions.key(value) }
        recentRaw = ([value] + rest).prefix(10).joined(separator: "\n")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if trimmed.isEmpty && !recent.isEmpty {
                        HStack {
                            Text(L("Недавние")).font(.aerial(.title3, .bold))
                            Spacer()
                            Button(L("Очистить")) { recentRaw = "" }.font(.aerial(.subheadline))
                        }
                        .padding(.horizontal, 16)
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(recent, id: \.self) { text in
                                    Chip(title: text, selected: false) { query = text }
                                }
                            }
                        }
                        .contentMargins(.horizontal, 16, for: .scrollContent)
                        .scrollIndicators(.hidden)
                        .padding(.bottom, 8)
                    }
                    if trimmed.isEmpty && !popular.isEmpty {
                        Text(L("Популярно сейчас")).font(.aerial(.title3, .bold)).padding(.horizontal, 16)
                    }
                    if !trimmed.isEmpty && (aiThinking || !aiPicked.isEmpty || aiNote != nil) {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                            Text(aiThinking ? L("ИИ ищет по описанию…") : aiNote ?? L("Первые %@ — найдены ИИ по описанию", "\(aiPicked.count)"))
                                .font(.aerial(.footnote))
                                .foregroundStyle(Theme.secondaryText)
                            if aiThinking { ProgressView().controlSize(.small).tint(.white) }
                        }
                        .padding(.horizontal, 16)
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
            .navigationTitle(L("Поиск"))
            .searchable(text: $query, prompt: L("Фильмы и сериалы"))
            .searchSuggestions {
                ForEach(suggestions, id: \.self) { text in
                    Label(text, systemImage: recent.contains(text) ? "clock.arrow.circlepath" : "magnifyingglass")
                        .searchCompletion(text)
                }
            }
            .onSubmit(of: .search) { remember(query) }
            .task(id: trimmed) {
                guard trimmed.count >= 2 else {
                    results = []
                    searching = false
                    return
                }
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                searching = true
                aiPicked = []
                aiNote = nil
                // Запрос из трёх слов и больше похож на описание («мужик застрял на Марсе»): параллельно обычному поиску
                // спрашиваем ИИ, его названия проверяются поиском TMDb и встают первыми (как `searchCinema` ТВ).
                let text = trimmed
                let described = AI.enabled && text.split(whereSeparator: \.isWhitespace).count >= 3
                async let ai: Result<[VodItem], Error>? = described ? Self.describe(text) : nil
                let found = (try? await Catalogue.shared.search(text)) ?? []
                guard !Task.isCancelled else { return }
                results = found
                searching = false
                if described {
                    aiThinking = true
                    let outcome = await ai
                    aiThinking = false
                    guard !Task.isCancelled else { return }
                    switch outcome {
                    case .success(let picks)?:
                        aiPicked = Set(picks.map(\.id))
                        var seen = Set<String>()
                        results = (picks + found).filter { seen.insert($0.id).inserted }
                    case .failure(let error)?:
                        aiNote = L("Поиск по описанию не сработал. ") + AI.failure(error)
                    case nil:
                        break
                    }
                }
                // Подсказку выбрали или запрос постоял и что-то нашёл — тоже в недавние.
                if !found.isEmpty, (try? await Task.sleep(for: .seconds(2))) != nil, !Task.isCancelled { remember(trimmed) }
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
                    PosterCard(item: item)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("poster")
                .contextMenu { PosterMenu(item: item) }
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

    @Environment(Library.self) private var library

    @State private var info: VodPersonInfo?
    @State private var expanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center, spacing: 16) {
                    // Фото круглое, как у актёров на странице фильма и в приложении для ТВ.
                    Color.clear
                        .frame(width: 120, height: 120)
                        .overlay { CachedImage(path: info?.photo ?? person.photo, size: "w342", pixelWidth: 360) }
                        .background(Theme.card)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 6) {
                        Text(info?.name ?? person.name).font(.aerial(.title2, .bold))
                        if let info {
                            if !info.birthday.isEmpty { Text(L("Дата рождения: %@", Format.date(info.birthday))).font(.aerial(.subheadline)) }
                            if !info.place.isEmpty { Text(info.place).font(.aerial(.subheadline)).foregroundStyle(Theme.secondaryText) }
                        }
                    }
                }
                .padding(.horizontal, 16)
                if let biography = info?.biography, !biography.isEmpty {
                    Text(biography)
                        .font(.aerial(.body))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(expanded ? nil : 6)
                        .onTapGesture { withAnimation(.easeOut) { expanded.toggle() } }
                        .padding(.horizontal, 16)
                }
                // Фильмография по видам, как разделы кинотеки: фильмы, сериалы, мультфильмы, мультсериалы.
                if let works = info?.works, !works.isEmpty {
                    ForEach(VodShelf.allCases.filter { $0 != .all }) { shelf in
                        let part = works.filter(shelf.accepts)
                        if !part.isEmpty {
                            ShelfHeader(title: "\(shelf.title) · \(part.count)")
                            PosterGrid(items: part)
                        }
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .background(Theme.background)
        .navigationTitle(person.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Подписка: новые работы человека — рядом «Новое с вашими актёрами» на главной.
                Button { library.toggleFollow(person) } label: {
                    Image(systemName: library.isFollowed(person) ? "bell.fill" : "bell")
                }
                .accessibilityLabel(library.isFollowed(person) ? L("Отписаться") : L("Подписаться"))
            }
        }
        .task { if info == nil { info = try? await Catalogue.shared.person(person) } }
    }
}

/// Медиатека: «Продолжить просмотр», загрузки, «Мой список» и «Нравится».
struct LibraryView: View {
    @Environment(Library.self) private var library

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    let continuing = library.continueWatching
                    if !continuing.isEmpty { ContinueShelf(entries: continuing) }
                    if !Downloads.shared.jobs.isEmpty { DownloadsShelf() }
                    if !library.saved.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            ShelfHeader(title: L("Смотреть позже"))
                            PosterGrid(items: library.saved)
                        }
                    }
                    let liked = library.likedItems
                    if !liked.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            ShelfHeader(title: L("Нравится"))
                            PosterGrid(items: liked)
                        }
                    }
                    // «История», как на ТВ: всё открытое и досмотренное, свежее первым.
                    let history = library.progressByItem.values.sorted { $0.updated > $1.updated }.map(\.item)
                    if !history.isEmpty {
                        PosterShelf(title: L("История"), items: history)
                    }
                }
                .padding(.vertical, 12)
            }
            .background(Theme.background)
            .overlay {
                if library.saved.isEmpty && library.continueWatching.isEmpty && library.likedItems.isEmpty && Downloads.shared.jobs.isEmpty {
                    ContentUnavailableView(L("Здесь пока пусто"), systemImage: "rectangle.stack",
                                           description: Text(L("Добавляйте фильмы кнопкой «+», а начатое появится в «Продолжить».")))
                }
            }
            .navigationTitle(L("Медиатека"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: Route.torrents) { Image(systemName: "arrow.down.doc") }
                        .accessibilityLabel(L("Торренты"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: Route.universes) { Image(systemName: "circle.grid.2x2") }
                        .accessibilityLabel(L("Вселенные"))
                }
                if Friends.shared.enabled {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink(value: Route.friends) { Image(systemName: "person.2") }
                            .accessibilityLabel(L("Друзья"))
                    }
                }
            }
            .aerialDestinations()
        }
    }
}
