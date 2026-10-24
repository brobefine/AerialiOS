import SwiftUI

/// Страница фильма или сериала. Как в Apple TV, содержимое скользит поверх постера: постер стоит на месте, под ним —
/// его зеркальное продолжение в размытии (вместо затемнения к низу — как у Aerial на ТВ). Под логотипом, кнопками
/// и описанием — живое размытие того, что позади, с плавным началом у логотипа; ниже — чёрный с резкой границей.
struct DetailsView: View {
    let item: VodItem

    @Environment(Library.self) private var library
    @Environment(Playback.self) private var playback
    @Environment(AppSettings.self) private var settings
    @Environment(\.openURL) private var openURL
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var details: VodDetails?
    @State private var failed = false
    @State private var season = 0
    @State private var episodes: [VodEpisode] = []
    @State private var expanded = false
    /// Оценки IMDb, RT, Metacritic из MDBList — если в настройках есть ключ.
    @State private var external = ""
    /// Цвет постера — им окрашены кнопки ([PosterPalette]).
    @State private var accent: Color?
    @State private var trailerOpen = false

    private var shown: VodItem { details?.item ?? item }
    private var art: String { shown.backdrop.isEmpty ? shown.poster : shown.backdrop }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let hero = min(geometry.size.height * 0.62, sizeClass == .regular ? 760 : 580)
            ZStack(alignment: .top) {
                Theme.background
                backdrop(width: width, height: hero)
                ScrollView {
                    VStack(spacing: 0) {
                        // Постер виден целиком; информация начинается у его нижней трети.
                        Color.clear.frame(height: hero * 0.62)
                        info
                            .padding(.top, 72)
                            .padding(.bottom, 40)
                            .frame(maxWidth: .infinity)
                            .background { frost }
                        sections
                            .padding(.top, 8)
                            // Под нижней пилюлей вкладок: без запаса последние разделы не долистывались.
                            .padding(.bottom, geometry.safeAreaInsets.bottom + 96)
                            // Чёрный начинается резкой границей сразу под размытием.
                            .background(Theme.background)
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .ignoresSafeArea(edges: .top)
        .clearNavigationBar()
        .navigationBarTitleDisplayMode(.inline)
        .task { if details == nil { await load() } }
        .task(id: season) { await loadSeason() }
        .fullScreenCover(isPresented: $trailerOpen) {
            if let key = details?.trailerKey, !key.isEmpty { TrailerView(key: key) }
        }
        .task(id: shown.poster) { accent = await PosterPalette.accent(shown.poster.isEmpty ? art : shown.poster) }
        .task(id: settings.mdblistKey) { external = await MdbList.ratings(item, key: settings.mdblistKey) }
    }

    private func load() async {
        failed = false
        do {
            let loaded = try await Catalogue.shared.details(item)
            details = loaded
            if item.kind == .series, season == 0 {
                season = library.latest(for: item)?.episode?.season ?? loaded.seasons.first ?? 1
            }
        } catch {
            if !HTTP.isCancellation(error) { failed = true }
        }
    }

    private func loadSeason() async {
        guard item.kind == .series, season > 0 else { return }
        episodes = (try? await Catalogue.shared.season(item, season)) ?? []
    }

    // MARK: Фон

    /// Постер и под ним его зеркальное продолжение в размытии; стоит на месте, пока страница листается.
    private func backdrop(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            CachedImage(path: art, size: "w1280", pixelWidth: 1600)
                .frame(width: width, height: height)
                .clipped()
                .overlay(alignment: .top) {
                    // Лёгкое затемнение под строкой состояния и кнопкой «назад».
                    LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom).frame(height: 110)
                }
            CachedImage(path: art, size: "w780", pixelWidth: 800)
                .frame(width: width, height: height)
                .clipped()
                .scaleEffect(x: 1, y: -1)
                .blur(radius: 36, opaque: true)
                .overlay(Color.black.opacity(0.2))
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.55),
                                             .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                .clipped()
        }
        .frame(width: width, alignment: .top)
        .allowsHitTesting(false)
    }

    /// Размытие под информацией: начинается плавно у логотипа и идёт до самого низа блока.
    private var frost: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 150)
                    // До самого низа без растворения: иначе при прокрутке под краем проступал резкий постер.
                    Color.black
                }
            }
    }

    // MARK: Информация

    private var info: some View {
        VStack(spacing: 14) {
            TitleArt(title: shown.title, logo: details?.logo ?? "", maxHeight: 100)
            Text(metaLine)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
            genreChips
            ratingsLine
            actions.frame(maxWidth: 480)
            if let tagline = details?.tagline, !tagline.isEmpty {
                // TMDb часто присылает слоган уже в кавычках.
                let quoted = ["«", "\"", "“", "„"].contains { tagline.hasPrefix($0) } ? tagline : "«\(tagline)»"
                Text(quoted)
                    .font(.subheadline.italic())
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            overview
            if failed && details == nil {
                Button("Повторить") { Task { await load() } }.buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: 720)
    }

    /// Оценки строкой, как на ТВ: знак источника и кольцо — TMDb, IMDb, Rotten Tomatoes, Metacritic, Letterboxd.
    @ViewBuilder private var ratingsLine: some View {
        let tmdb = shown.rating > 0 && shown.votes >= 10 ? shown.rating : 0
        if tmdb > 0 || (settings.mdblistShown && !external.isEmpty) {
            RatingsRow(tmdb: tmdb, external: settings.mdblistShown ? external : "", sources: settings.ratingSources)
        }
    }

    private var trailer: URL? {
        (details?.trailerKey).flatMap { $0.isEmpty ? nil : URL(string: "https://www.youtube.com/watch?v=\($0)") }
    }

    /// Жанры и студии капсулами, как `GenreChips` ТВ: жанр — его работы того же вида, студия — её работы.
    @ViewBuilder private var genreChips: some View {
        let genres = Array(zip(shown.genreIds, shown.genres).prefix(3))
        let studios = details?.studios ?? []
        if !genres.isEmpty || !studios.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(genres, id: \.0) { id, name in
                    NavigationLink(value: Route.section(genreSection(id, name), .all)) { chip(name, strong: true) }
                        .buttonStyle(.plain)
                }
                ForEach(studios, id: \.id) { studio in
                    NavigationLink(value: Route.section(studio.section(item.kind), .all)) { chip(studio.name, strong: false) }
                        .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 440)
        }
    }

    private func chip(_ title: String, strong: Bool) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(strong ? 0.95 : 0.75))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 10)
            .frame(height: 26)
            // Длинные названия студий («Tianjin Maoyan Weiying Culture Media …») растягивали всю страницу шире экрана —
            // съезжали название и кнопки.
            .frame(maxWidth: 200)
            .background(.white.opacity(strong ? 0.2 : 0.08), in: Capsule())
    }

    private func genreSection(_ id: Int, _ name: String) -> CinemaSection {
        CinemaSection(id: "genre-\(id)-\(item.kind)", title: name.prefix(1).uppercased() + name.dropFirst(),
                      path: item.kind == .series ? "discover/tv" : "discover/movie", kind: item.kind,
                      params: ["with_genres": String(id), "sort_by": "popularity.desc", "vote_count.gte": "50"])
    }

    private var metaLine: String {
        var year = shown.year
        if let details, !details.endYear.isEmpty, details.endYear != year { year += "–\(details.endYear)" }
        let parts: [String] = [
            shown.kindLabel, year, Format.runtime(minutes: details?.runtimeMinutes ?? 0), details?.certification ?? "",
            // Жанры — только капсулами ниже (их можно открыть), как на ТВ; в строке они повторялись.
            details?.status ?? "",
        ]
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Один абзац — целиком; несколько — первый, остальные по «Ещё».
    @ViewBuilder private var overview: some View {
        let paragraphs = shown.overview.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let first = paragraphs.first {
            VStack(alignment: .leading, spacing: 6) {
                Text(expanded ? paragraphs.joined(separator: "\n\n") : first)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
                if paragraphs.count > 1 && !expanded {
                    Button("Ещё") { withAnimation(.easeOut) { expanded = true } }
                        .font(.subheadline.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Фильм: недосмотрен с известной раздачей — «Продолжить» сразу в плеер; иначе — к выбору раздачи.
    /// Сериал: последняя серия (продолжить или выбрать раздачу), иначе первая серия сезона.
    @ViewBuilder private var actions: some View {
        let latest = library.latest(for: item)
        HStack(spacing: 12) {
            if let latest, latest.resumable, latest.source != nil {
                Button { playback.resume(latest) } label: {
                    WatchLabel(title: "Продолжить",
                               detail: [latest.episode?.code, latest.remaining].compactMap { $0 }.filter { !$0.isEmpty }
                                   .joined(separator: " · "))
                }
                .buttonStyle(PrimaryButtonStyle(fill: accent))
                .accessibilityIdentifier("details-watch")
                NavigationLink(value: Route.releases(item, latest.episode, runtime: details?.runtimeMinutes ?? 0)) {
                    Image(systemName: "list.bullet")
                }
                .buttonStyle(CircleGlassButtonStyle(tint: accent))
                .accessibilityLabel("Другая раздача")
            } else if item.kind == .movie {
                NavigationLink(value: Route.releases(item, nil, runtime: details?.runtimeMinutes ?? 0)) {
                    WatchLabel(title: "Смотреть")
                }
                .buttonStyle(PrimaryButtonStyle(fill: accent))
                .accessibilityIdentifier("details-watch")
            } else if let episode = latest?.episode ?? episodes.first {
                // Серия под «Смотреть» — только когда сериал уже начинали, как на ТВ.
                NavigationLink(value: Route.releases(item, episode, runtime: episode.runtimeMinutes)) {
                    WatchLabel(title: "Смотреть", detail: latest?.episode == nil ? "" : "\(episode.code) · \(episode.title)")
                }
                .buttonStyle(PrimaryButtonStyle(fill: accent))
                .accessibilityIdentifier("details-watch")
            } else {
                WatchLabel(title: "Смотреть").opacity(0.5)
                    .frame(maxWidth: .infinity).frame(height: 52).background(.white.opacity(0.3), in: Capsule())
            }
            if let trailer {
                Button { trailerOpen = true } label: { Image(systemName: "play.rectangle") }
                    .buttonStyle(CircleGlassButtonStyle(tint: accent))
                    .accessibilityLabel("Трейлер")
            }
            // «Мой список», как на ТВ: одна кнопка — «Смотреть позже» и оценка. Значок — выставленная оценка, иначе
            // закладка; что-то выбрано — кнопка залита цветом постера, как «Смотреть».
            let rating = library.rating(item)
            let marked = rating != 0 || library.isSaved(item)
            Menu { PosterMenu(item: shown) } label: {
                Image(systemName: rating != 0 ? TasteLevel.symbol(rating) : marked ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(marked && accent == nil ? .black : .white)
                    .frame(width: 48, height: 48)
                    .background {
                        if marked { Circle().fill(accent ?? .white) }
                    }
                    .glass(in: Circle(), tint: marked ? nil : accent?.opacity(0.55))
            }
            .accessibilityLabel("Мой список")
            .accessibilityIdentifier("details-rate")
        }
    }

    // MARK: Разделы

    @ViewBuilder private var sections: some View {
        if let details {
            VStack(alignment: .leading, spacing: 28) {
                // Порядок — как на странице фильма ТВ: актёры, серии, отзывы, интересные факты, франшиза, похожие,
                // «Духовные родственники», «Ещё от студии»; в конце — сведения.
                RecapCard(details: details)
                if !details.cast.isEmpty || !details.directors.isEmpty { peopleSection(details) }
                if item.kind == .series && !details.seasons.isEmpty { episodesSection(details) }
                ReviewsSection(item: details.item)
                WikiStorySection(item: details.item)
                if !details.collection.isEmpty { PosterShelf(title: details.collectionTitle, items: details.collection) }
                if !details.related.isEmpty { PosterShelf(title: "Похожие", items: details.related) }
                RelativesSection(details: details)
                if let studio = details.studios.first, !details.studioFilms.isEmpty {
                    PosterShelf(title: "Ещё от студии \(studio.name)", items: details.studioFilms,
                                seeAll: .section(studio.section(item.kind), .all))
                }
                if !details.facts.isEmpty { factsSection(details) }
            }
        } else {
            Color.clear.frame(height: 200)
        }
    }

    private func episodesSection(_ details: VodDetails) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Серии").font(.title3.weight(.bold))
                Spacer()
                Menu {
                    ForEach(details.seasons, id: \.self) { number in
                        Button("Сезон \(number)") { season = number }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Сезон \(season)")
                        Image(systemName: "chevron.up.chevron.down").font(.caption)
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .glass(in: Capsule(), interactive: true)
                }
            }
            .padding(.horizontal, 16)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(episodes) { episode in
                        NavigationLink(value: Route.releases(item, episode, runtime: episode.runtimeMinutes)) {
                            EpisodeCard(episode: episode, entry: library.entry(item, episode),
                                        width: Theme.landscapeWidth(sizeClass), overviews: settings.episodeOverviews,
                                        hideSpoilers: settings.hideSpoilers)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("episode")
                        // Меню должно быть всегда: без пунктов iOS не показывает и окно с описанием — так оно
                        // открывалось только у начатых серий.
                        .contextMenu {
                            if let entry = library.entry(item, episode), entry.fraction > 0 {
                                Button(role: .destructive) { library.forget(entry) } label: {
                                    Label("Убрать из «Продолжить»", systemImage: "eye.slash")
                                }
                            }
                            if library.entry(item, episode).map({ $0.fraction < 0.9 }) ?? true {
                                Button {
                                    library.record(item: item, episode: episode, position: 1, duration: 1, source: nil)
                                } label: {
                                    Label("Отметить просмотренной", systemImage: "checkmark.circle")
                                }
                            }
                        } preview: {
                            EpisodePreview(episode: episode, entry: library.entry(item, episode))
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

    private func peopleSection(_ details: VodDetails) -> some View {
        // Сначала актёры, затем режиссёры и авторы; режиссёр бывает и в ролях — один человек одной карточкой.
        var seen = Set<Int>()
        let people = (details.cast + details.directors).filter { seen.insert($0.id).inserted }
        return VStack(alignment: .leading, spacing: 10) {
            ShelfHeader(title: "Актёры и съёмочная группа")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(people) { person in
                        NavigationLink(value: Route.person(person)) { PersonBadge(person: person) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("person")
                            // Удержание — карточка человека, как на ТВ: фото, сведения, биография; подписка в меню,
                            // фильмография — касанием.
                            .contextMenu {
                                Button { library.toggleFollow(person) } label: {
                                    Label(library.isFollowed(person) ? "Вы подписаны" : "Подписаться",
                                          systemImage: library.isFollowed(person) ? "checkmark.circle.fill" : "person.badge.plus")
                                }
                            } preview: {
                                PersonPreview(person: person)
                            }
                    }
                }
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .scrollIndicators(.hidden)
        }
    }

    private func factsSection(_ details: VodDetails) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ShelfHeader(title: "Сведения")
            VStack(alignment: .leading, spacing: 12) {
                ForEach(details.facts, id: \.label) { fact in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fact.label).font(.caption).foregroundStyle(Theme.secondaryText)
                        Text(fact.value).font(.subheadline)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 16)
        }
    }
}

/// Надпись главной кнопки: «Смотреть» и, если есть, вторая строка — серия или сколько осталось.
private struct WatchLabel: View {
    let title: String
    var detail = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "play.fill")
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.headline)
                if !detail.isEmpty {
                    Text(detail).font(.caption2.weight(.medium)).opacity(0.7)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        }
    }
}

/// Карточка серии: кадр с полосой просмотра; под ним — тот же кадр зеркально и в размытии, поверх — номер,
/// название и описание.
private struct EpisodeCard: View {
    let episode: VodEpisode
    let entry: WatchEntry?
    let width: CGFloat
    /// «Описания серий» и «Скрывать спойлеры серий» из настроек, как на ТВ.
    var overviews = true
    var hideSpoilers = false

    var body: some View {
        let still = width * 9 / 16
        // Спойлер — серия, которую ещё не досмотрели: кадр размыт, описания нет.
        let spoiler = hideSpoilers && (entry?.fraction ?? 0) < 0.9
        VStack(alignment: .leading, spacing: 0) {
            CachedImage(path: episode.still, size: "w780", pixelWidth: Int(width * 3))
                .frame(width: width, height: still)
                .blur(radius: spoiler ? 18 : 0, opaque: true)
                .clipped()
                .overlay(alignment: .bottom) {
                    if let entry, entry.fraction > 0 {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.3))
                                Capsule().fill(Theme.accent).frame(width: geometry.size.width * entry.fraction)
                            }
                        }
                        .frame(height: 4)
                        .padding(8)
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                Text("\(episode.number). \(episode.title)").font(.subheadline.weight(.semibold)).lineLimit(1)
                Text([Format.runtime(minutes: episode.runtimeMinutes), episode.airDate.isEmpty ? "" : Format.date(episode.airDate)]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.white.opacity(0.7))
                if overviews {
                    Text(spoiler ? "Описание скрыто, чтобы не было спойлеров" : episode.overview.isEmpty ? " " : episode.overview)
                        .font(.caption).foregroundStyle(.white.opacity(spoiler ? 0.5 : 0.85))
                        .lineLimit(3, reservesSpace: true)
                }
            }
            .padding(12)
            .frame(width: width, alignment: .leading)
            .background(alignment: .top) {
                CachedImage(path: episode.still, size: "w300", pixelWidth: 300)
                    .frame(width: width, height: still)
                    .clipped()
                    .scaleEffect(x: 1, y: -1)
                    .blur(radius: 22, opaque: true)
                    .overlay(Color.black.opacity(0.3))
            }
            .clipped()
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(width: width)
    }
}

/// Долгое нажатие на серию: кадр крупно и описание целиком.
private struct EpisodePreview: View {
    let episode: VodEpisode
    let entry: WatchEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CachedImage(path: episode.still, size: "w780", pixelWidth: 1000)
                .frame(width: 340, height: 340 * 9 / 16)
                .clipped()
            VStack(alignment: .leading, spacing: 6) {
                Text("\(episode.code) · \(episode.title)").font(.headline)
                Text([Format.runtime(minutes: episode.runtimeMinutes), episode.airDate.isEmpty ? "" : Format.date(episode.airDate),
                      entry.map { $0.resumable ? $0.remaining : "" } ?? ""]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(Theme.secondaryText)
                if !episode.overview.isEmpty {
                    Text(episode.overview).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
        .frame(width: 340)
        .background {
            CachedImage(path: episode.still, size: "w300", pixelWidth: 300)
                .blur(radius: 30, opaque: true)
                .overlay(Color.black.opacity(0.35))
        }
        .glass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .foregroundStyle(.white)
    }
}

/// Удержание на актёре: фото, сведения и биография, как карточка человека на ТВ.
private struct PersonPreview: View {
    let person: VodPerson

    @State private var info: VodPersonInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Color.clear
                    .frame(width: 72, height: 72)
                    .overlay { CachedImage(path: info?.photo ?? person.photo, size: "w185", pixelWidth: 240) }
                    .background(Theme.card)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(info?.name ?? person.name).font(.headline)
                    let facts = [info.map { $0.birthday.isEmpty ? "" : Format.date($0.birthday) } ?? "", info?.place ?? ""]
                        .filter { !$0.isEmpty }.joined(separator: " · ")
                    if !facts.isEmpty { Text(facts).font(.caption).foregroundStyle(Theme.secondaryText) }
                    if !person.role.isEmpty { Text(person.role).font(.caption).foregroundStyle(Theme.secondaryText) }
                }
            }
            Text(info.map { $0.biography.isEmpty ? "Биографии на TMDb нет." : $0.biography } ?? "Загружаем…")
                .font(.subheadline)
                .lineLimit(12)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 340, alignment: .leading)
        .glass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .foregroundStyle(.white)
        .task { if info == nil { info = try? await Catalogue.shared.person(person) } }
    }
}

/// Актёр: фото, имя и фамилия всегда в две строки, роль.
private struct PersonBadge: View {
    let person: VodPerson

    private var name: String {
        guard let space = person.name.firstIndex(of: " ") else { return person.name }
        return person.name.replacingCharacters(in: space...space, with: "\n")
    }

    var body: some View {
        VStack(spacing: 6) {
            Color.clear
                .frame(width: Theme.actorPhoto, height: Theme.actorPhoto)
                .overlay {
                    if person.photo.isEmpty {
                        Image(systemName: "person.fill").font(.title).foregroundStyle(Theme.secondaryText)
                    } else {
                        CachedImage(path: person.photo, size: "w185", pixelWidth: 240)
                    }
                }
                .background(Theme.card)
                .clipShape(Circle())
            Text(name)
                .font(.caption.weight(.semibold))
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.center)
            Text(person.role).font(.caption2).foregroundStyle(Theme.secondaryText).lineLimit(1)
        }
        .frame(width: Theme.actorPhoto + 16)
    }
}
