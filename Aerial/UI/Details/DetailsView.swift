import SwiftUI

/// Страница фильма или сериала в духе Apple TV: кадр во всю ширину, логотип, «Смотреть», описание,
/// сезоны и серии, актёры, франшиза, похожие и сведения.
struct DetailsView: View {
    let item: VodItem

    @Environment(Library.self) private var library
    @Environment(Playback.self) private var playback
    @Environment(\.openURL) private var openURL
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var details: VodDetails?
    @State private var failed = false
    @State private var season = 0
    @State private var episodes: [VodEpisode] = []
    @State private var expanded = false

    private var shown: VodItem { details?.item ?? item }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                overview
                if failed && details == nil {
                    Button("Повторить") { Task { await load() } }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                }
                if let details {
                    if item.kind == .series && !details.seasons.isEmpty { episodesSection(details) }
                    if !details.cast.isEmpty || !details.directors.isEmpty { peopleSection(details) }
                    if !details.collection.isEmpty { PosterShelf(title: details.collectionTitle, items: details.collection) }
                    if !details.related.isEmpty { PosterShelf(title: "Похожие", items: details.related) }
                    if !details.facts.isEmpty { factsSection(details) }
                }
            }
            .padding(.bottom, 32)
        }
        .ignoresSafeArea(edges: .top)
        .background(Theme.background)
        .clearNavigationBar()
        .navigationBarTitleDisplayMode(.inline)
        .task { if details == nil { await load() } }
        .task(id: season) { await loadSeason() }
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

    // MARK: Шапка

    private var header: some View {
        ZStack(alignment: .bottom) {
            Color.clear
                .overlay {
                    CachedImage(path: shown.backdrop.isEmpty ? shown.poster : shown.backdrop, size: "w1280", pixelWidth: 1600)
                }
                .clipped()
            LinearGradient(stops: [
                .init(color: .black.opacity(0.4), location: 0),
                .init(color: .clear, location: 0.2),
                .init(color: Theme.background.opacity(0.75), location: 0.6),
                .init(color: Theme.background, location: 1),
            ], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 12) {
                TitleArt(title: shown.title, logo: details?.logo ?? "", maxHeight: 100)
                Text(metaLine).font(.footnote.weight(.medium)).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
                actions.frame(maxWidth: 420)
                if shown.rating > 0 && shown.votes >= 10 {
                    HStack(spacing: 8) {
                        RatingRing(value: shown.rating, size: 34)
                        Text("TMDb · \(shown.votes) \(Format.plural(shown.votes, "голос", "голоса", "голосов"))")
                            .font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .frame(height: sizeClass == .regular ? 620 : 560)
    }

    private var metaLine: String {
        var year = shown.year
        if let details, !details.endYear.isEmpty, details.endYear != year { year += "–\(details.endYear)" }
        let parts: [String] = [
            shown.kindLabel, year, Format.runtime(minutes: details?.runtimeMinutes ?? 0), details?.certification ?? "",
            shown.genres.prefix(3).joined(separator: ", "), details?.status ?? "",
        ]
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Фильм: недосмотрен с известной раздачей — «Продолжить» сразу в плеер; иначе — к выбору раздачи.
    /// Сериал: последняя серия (продолжить или выбрать раздачу), иначе первая серия сезона.
    @ViewBuilder private var actions: some View {
        let latest = library.latest(for: item)
        HStack(spacing: 12) {
            if let latest, latest.resumable, latest.source != nil {
                Button { playback.resume(latest) } label: {
                    Label(latest.episode.map { "Продолжить \($0.code)" } ?? "Продолжить", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("details-watch")
                NavigationLink(value: Route.releases(item, latest.episode, runtime: details?.runtimeMinutes ?? 0)) {
                    Image(systemName: "list.bullet")
                }
                .buttonStyle(CircleGlassButtonStyle())
                .accessibilityLabel("Другая раздача")
            } else if item.kind == .movie {
                NavigationLink(value: Route.releases(item, nil, runtime: details?.runtimeMinutes ?? 0)) {
                    Label("Смотреть", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("details-watch")
            } else if let episode = latest?.episode ?? episodes.first {
                NavigationLink(value: Route.releases(item, episode, runtime: episode.runtimeMinutes)) {
                    Label("Смотреть \(episode.code)", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("details-watch")
            } else {
                Label("Смотреть", systemImage: "play.fill").opacity(0.5)
                    .frame(maxWidth: .infinity).frame(height: 48).background(.white.opacity(0.3), in: Capsule())
            }
            Button { library.toggleSaved(shown) } label: {
                Image(systemName: library.isSaved(item) ? "checkmark" : "plus")
            }
            .buttonStyle(CircleGlassButtonStyle())
            .accessibilityLabel(library.isSaved(item) ? "Убрать из списка" : "В мой список")
            if let key = details?.trailerKey, !key.isEmpty, let url = URL(string: "https://www.youtube.com/watch?v=\(key)") {
                Button { openURL(url) } label: { Image(systemName: "film") }
                    .buttonStyle(CircleGlassButtonStyle())
                    .accessibilityLabel("Трейлер")
            }
        }
    }

    @ViewBuilder private var overview: some View {
        let text = shown.overview
        if !text.isEmpty || !(details?.tagline ?? "").isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if let tagline = details?.tagline, !tagline.isEmpty {
                    // TMDb часто присылает слоган уже в кавычках.
                    let quoted = ["«", "\"", "“", "„"].contains { tagline.hasPrefix($0) } ? tagline : "«\(tagline)»"
                    Text(quoted).font(.subheadline.italic()).foregroundStyle(Theme.secondaryText)
                }
                if !text.isEmpty {
                    Text(text)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(expanded ? nil : 4)
                        .onTapGesture { withAnimation(.easeOut) { expanded.toggle() } }
                    if !expanded && text.count > 220 {
                        Button("Ещё") { withAnimation(.easeOut) { expanded = true } }
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: Сезоны и серии

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
                                        width: Theme.landscapeWidth(sizeClass))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
        }
    }

    // MARK: Люди и сведения

    private func peopleSection(_ details: VodDetails) -> some View {
        // Режиссёр бывает и в ролях — один человек одной карточкой.
        var seen = Set<Int>()
        let people = (details.directors + details.cast).filter { seen.insert($0.id).inserted }
        return VStack(alignment: .leading, spacing: 10) {
            ShelfHeader(title: "Актёры и съёмочная группа")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(people) { person in
                        NavigationLink(value: Route.person(person)) { PersonBadge(person: person) }
                            .buttonStyle(.plain)
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
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 16)
        }
    }
}

/// Карточка серии: кадр с полосой просмотра, номер и название, описание.
private struct EpisodeCard: View {
    let episode: VodEpisode
    let entry: WatchEntry?
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay { CachedImage(path: episode.still, size: "w780", pixelWidth: Int(width * 3)) }
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
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text("\(episode.number). \(episode.title)").font(.subheadline.weight(.semibold)).lineLimit(1)
            Text([Format.runtime(minutes: episode.runtimeMinutes), episode.airDate.isEmpty ? "" : Format.date(episode.airDate)]
                .filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption2).foregroundStyle(Theme.secondaryText)
            if !episode.overview.isEmpty {
                Text(episode.overview).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(3)
            }
        }
        .frame(width: width)
    }
}

private struct PersonBadge: View {
    let person: VodPerson

    var body: some View {
        VStack(spacing: 6) {
            Color.clear
                .frame(width: 76, height: 76)
                .overlay {
                    if person.photo.isEmpty {
                        Image(systemName: "person.fill").font(.title).foregroundStyle(Theme.secondaryText)
                    } else {
                        CachedImage(path: person.photo, size: "w185", pixelWidth: 240)
                    }
                }
                .background(Theme.card)
                .clipShape(Circle())
            Text(person.name).font(.caption.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
            Text(person.role).font(.caption2).foregroundStyle(Theme.secondaryText).lineLimit(1)
        }
        .frame(width: 92)
    }
}
