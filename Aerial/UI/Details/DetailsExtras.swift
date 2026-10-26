import SwiftUI

// Разделы страницы фильма из ТВ: «Духовные родственники» и «Разбор фильма» (ИИ), отзывы TMDb со сводкой и переводом,
// «История создания» из Википедии.

/// Работа и чем она связана с открытой («why» от ИИ).
struct Relative: Identifiable {
    var item: VodItem
    /// Чем похожи — подпись из `RelativeCriteria` («Саундтрек и звук · психология»).
    var why: String
    var id: String { item.id }
}

/// Подборка «Духовных родственников» по одной стороне фильма (или общий ряд, если подборок по сторонам не набралось).
struct RelativeRow: Identifiable {
    let id: String
    let title: String
    let items: [Relative]
}

/// «Духовные родственники» (как на ТВ): подборки по сторонам фильма — «Тоже: давящий звуковой дизайн», «Тоже: психология на
/// грани»… Кандидаты — рекомендации TMDb, работы с её ключевыми словами и хиты жанра (`Catalogue.byKeywords`), идеи ИИ и второй
/// круг (рекомендации к лучшим); ИИ ставит им профили (`AI.profiles`), отбор — `RelativeRanker`. Под постером — метки самого
/// фильма (`RelativeShades`), первая — со стороны подборки.
struct RelativesSection: View {
    let details: VodDetails

    @Environment(Library.self) private var library
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var rows: [RelativeRow] = []
    @State private var failure: String?
    @State private var loading = false

    private static let logKey = "ai.relativeLog"

    var body: some View {
        // Не `Group`: у пустого `Group` модификаторы не срабатывают — `.task` не запускался.
        VStack(alignment: .leading, spacing: 18) {
            if rows.isEmpty && (loading || failure != nil) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        ShelfHeader(title: L("Духовные родственники"))
                        Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                    }
                    if let failure {
                        Text(failure).font(.aerial(.footnote)).foregroundStyle(Theme.secondaryText).padding(.horizontal, 16)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().tint(.white)
                            Text(L("ИИ подбирает фильмы по темам…")).font(.aerial(.footnote)).foregroundStyle(Theme.secondaryText)
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 10) {
                    ShelfHeader(title: row.title)
                    shelf(row.items)
                }
            }
        }
        .task(id: details.item.id) { await load() }
    }

    private func shelf(_ items: [Relative]) -> some View {
        let width = Theme.posterWidth(sizeClass)
        return ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(items) { row in
                    NavigationLink(value: Route.details(row.item)) {
                        // Метки — под постером в его прогрессивном размытии (`MirrorBackdrop`).
                        VStack(alignment: .leading, spacing: 0) {
                            PosterCard(item: row.item, width: width, artwork: false, squareBottom: true)
                                .frame(width: width, height: width * 1.5)
                            Text(row.why)
                                .font(.aerial(.caption2))
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(4)
                                .padding(8)
                                .frame(width: width, alignment: .leading)
                        }
                        .background(alignment: .top) {
                            MirrorBackdrop(path: row.item.poster, size: "w342", pixelWidth: 420, width: width, height: width * 1.5)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .contextMenu { PosterMenu(item: row.item) } preview: { RelativePreview(row: row) }
                }
            }
        }
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .scrollIndicators(.hidden)
    }

    private func load() async {
        guard AI.enabled, rows.isEmpty else { return }
        loading = true
        defer { loading = false }
        let log = UserDefaults.standard.dictionary(forKey: Self.logKey) as? [String: [String]] ?? [:]
        var counts: [String: Int] = [:]
        for titles in log.values { for title in titles { counts[title, default: 0] += 1 } }
        let seed = details.item
        let franchise = Set(details.collection.map(\.id))
        let rejected = library.rejected
        // Сбой — ещё одна попытка через 5 с; отказ по стране повтором не лечится.
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(5)) }
            do {
                let started = Date()
                async let ideas = AI.relativeIdeas(details)
                async let keywords = Catalogue.shared.byKeywords(seed)
                let fromIdeas = await Taste.resolve(try await ideas)
                var seen = Set<String>([seed.id])
                func fresh(_ list: [VodItem]) -> [VodItem] {
                    list.filter { $0.id.hasPrefix("tmdb:") && !rejected.contains($0.id) && !franchise.contains($0.id) && seen.insert($0.id).inserted }
                }
                var pool = Array(fresh(fromIdeas + details.related + (await keywords)).prefix(220))
                var profiles = await AI.profiles([seed] + pool)
                guard let seedProfile = profiles[seed.id] else { throw AiError.bad }
                func candidates() -> [RelativeRanker.Candidate] {
                    pool.map { RelativeRanker.Candidate(id: $0.id, profile: profiles[$0.id] ?? [:], votes: $0.votes, overused: counts[$0.title] ?? 0) }
                }
                // Второй круг — рекомендации TMDb к пяти лучшим: связи, которых нет ни у самой работы, ни по её словам.
                let first = RelativeRanker.rank(seedProfile, candidates(), count: 5)
                let byId = Dictionary(pool.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                var more: [VodItem] = []
                for pick in first {
                    if let item = byId[pick.id], let recs = try? await Catalogue.shared.recommendations(item) {
                        more += fresh(recs.filter { $0.votes >= 150 })
                    }
                }
                more = Array(more.prefix(60))
                if !more.isEmpty {
                    profiles.merge(await AI.profiles(more)) { $1 }
                    pool += more
                }
                let all = Dictionary(pool.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                let english = AppLanguage.english
                var found = RelativeRanker.sides(seedProfile, candidates()).map { group, picks in
                    let name = RelativeCriteria.groups.first { $0.key == group }?.ru ?? group
                    return RelativeRow(id: group, title: L("Тоже: %@", name), items: picks.compactMap { pick in
                        all[pick.id].map { Relative(item: $0, why: RelativeShades.label($0.id, profiles[$0.id] ?? [:], english: english, prefer: group)) }
                    })
                }
                if found.isEmpty {
                    let general = RelativeRanker.rank(seedProfile, candidates()).compactMap { pick in
                        all[pick.id].map { Relative(item: $0, why: RelativeShades.label($0.id, profiles[$0.id] ?? [:], english: english)) }
                    }
                    if !general.isEmpty { found = [RelativeRow(id: "all", title: L("Духовные родственники"), items: general)] }
                }
                Log.note("ИИ", String(format: "родственники «%@»: кандидатов %d, подборок %d, %.1f с", seed.title, pool.count, found.count,
                                      Date().timeIntervalSince(started)))
                guard !found.isEmpty else { continue }
                var updated = log
                updated[seed.id] = found.flatMap { $0.items.map(\.item.title) }
                if updated.count > 60, let firstKey = updated.keys.sorted().first { updated[firstKey] = nil }
                UserDefaults.standard.set(updated, forKey: Self.logKey)
                rows = found
                failure = nil
                return
            } catch {
                if HTTP.isCancellation(error) { return }
                failure = AI.failure(error)
                if AI.regionBlocked { return }
            }
        }
    }
}

/// «Разбор» круглой кнопкой в ряду с «Смотреть», как на ТВ: всей работы целиком. Не посмотрели — сначала
/// предупреждение о спойлерах.
struct RecapButton: View {
    let details: VodDetails
    var tint: Color?

    @Environment(Library.self) private var library
    @State private var open = false
    @State private var spoilerNote = false

    private var watched: Bool {
        if details.item.kind == .series { return library.latest(for: details.item)?.episode != nil }
        return (library.entry(details.item)?.fraction ?? 0) >= 0.98
    }

    var body: some View {
        if AI.enabled {
            Button { if watched { open = true } else { spoilerNote = true } } label: {
                Image(systemName: "text.book.closed")
            }
            .buttonStyle(CircleGlassButtonStyle(tint: tint))
            .accessibilityLabel(details.item.kind == .series ? L("Разбор сериала") : L("Разбор фильма"))
            .sheet(isPresented: $open) {
                RecapSheet(details: details)
            }
            .alert(details.item.kind == .series ? L("Разбор сериала") : L("Разбор фильма"), isPresented: $spoilerNote) {
                Button(L("Открыть")) { open = true }
                Button(L("Отмена"), role: .cancel) {}
            } message: {
                Text(details.item.kind == .series
                     ? L("В разборе спойлеры: весь сюжет сериала и концовка.")
                     : L("В разборе спойлеры: весь сюжет фильма и концовка."))
            }
        }
    }
}

private struct RecapSheet: View {
    let details: VodDetails

    @Environment(\.dismiss) private var dismiss
    @State private var sections: [AiSection] = []
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if sections.isEmpty && message == nil {
                        HStack(spacing: 10) {
                            ProgressView().tint(.white)
                            Text(details.item.kind == .series ? L("ИИ разбирает сериал…") : L("ИИ разбирает фильм…")).foregroundStyle(Theme.secondaryText)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    }
                    if let message {
                        Text(message).foregroundStyle(Theme.secondaryText)
                    }
                    ForEach(sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title).font(.aerial(.title3, .bold))
                            Text(section.text).font(.aerial(.body)).foregroundStyle(.white.opacity(0.9)).textSelection(.enabled)
                        }
                    }
                }
                .padding(20)
            }
            // Без своего фона — лист на системном жидком стекле.
            .navigationTitle(details.item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Готово")) { dismiss() } } }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            // Опора — раздел «Сюжет» Википедии; только у фильмов: у сериалов он часто по сезонам и неполный.
            var plot = ""
            if details.item.kind == .movie { plot = await Wiki.plot(details.item)?.text ?? "" }
            if let found = try await AI.recap(details, plot: plot) {
                sections = found
            } else {
                message = L("ИИ не знает именно эту работу достаточно хорошо — разбора нет, чтобы не пересказывать другую.")
            }
        } catch {
            if !HTTP.isCancellation(error) { message = AI.failure(error) }
        }
    }
}

/// Отзывы TMDb: сводка ИИ (от трёх отзывов), карточки; касание — отзыв целиком, с переводом на русский.
struct ReviewsSection: View {
    let item: VodItem

    @Environment(AppSettings.self) private var settings
    @State private var reviews: [VodReview] = []
    @State private var summary: String?
    @State private var summaryPending = false
    @State private var opened: VodReview?
    @AppStorage("reviews.sort") private var sort = "rating"

    private var shown: [VodReview] {
        switch sort {
        case "new": reviews.sorted { $0.date > $1.date }
        case "long": reviews.sorted { $0.text.count > $1.text.count }
        default: reviews.sorted { ($0.rating, $0.date) > ($1.rating, $1.date) }
        }
    }

    var body: some View {
        // Не `Group`: у пустого `Group` модификаторы не срабатывают — `.task` не запускался, и раздел
        // (отзывы, «Духовные родственники») не загружался никогда.
        VStack(alignment: .leading, spacing: 0) {
            if !reviews.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        ShelfHeader(title: L("Отзывы · %@", "\(reviews.count)"))
                        Spacer()
                        Menu {
                            Picker(L("Порядок"), selection: $sort) {
                                Text(L("Сначала с высокой оценкой")).tag("rating")
                                Text(L("Сначала новые")).tag("new")
                                Text(L("Сначала подробные")).tag("long")
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down").font(.aerial(.subheadline, .semibold))
                        }
                        .padding(.trailing, 16)
                    }
                    if let summary {
                        Label { Text(summary).font(.aerial(.subheadline)) } icon: { Image(systemName: "sparkles").foregroundStyle(Theme.accent) }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .padding(.horizontal, 16)
                    } else if summaryPending {
                        HStack(spacing: 8) {
                            ProgressView().tint(.white)
                            Text(L("ИИ читает отзывы…")).font(.aerial(.footnote)).foregroundStyle(Theme.secondaryText)
                        }
                        .padding(.horizontal, 16)
                    }
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(shown.prefix(20)) { review in
                                Button { opened = review } label: { ReviewCard(review: review) }.buttonStyle(.plain)
                            }
                        }
                    }
                    .contentMargins(.horizontal, 16, for: .scrollContent)
                    .scrollIndicators(.hidden)
                }
            }
        }
        .task(id: item.id) { await load() }
        .sheet(item: $opened) { review in ReviewSheet(review: review, translate: settings.translateReviews) }
    }

    private func load() async {
        guard reviews.isEmpty else { return }
        reviews = await Catalogue.shared.reviews(item)
        guard settings.summarizeReviews, AI.enabled, reviews.count >= 3 else { return }
        summaryPending = true
        defer { summaryPending = false }
        summary = try? await AI.summary(title: item.title, reviews: shown.prefix(15).map(\.text))
    }
}

private struct ReviewCard: View {
    let review: VodReview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(review.author).font(.aerial(.subheadline, .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if review.rating > 0 { RatingRing(value: review.rating, size: 28) }
            }
            Text(review.text).font(.aerial(.footnote)).foregroundStyle(.white.opacity(0.85)).lineLimit(6, reservesSpace: true)
            if !review.date.isEmpty { Text(Format.date(review.date)).font(.aerial(.caption2)).foregroundStyle(Theme.secondaryText) }
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct ReviewSheet: View {
    let review: VodReview
    let translate: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var translated: String?
    @State private var translating = false
    @State private var showOriginal = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(review.author).font(.aerial(.headline))
                        Spacer()
                        if review.rating > 0 { RatingRing(value: review.rating, size: 34) }
                    }
                    if translating { HStack(spacing: 8) { ProgressView().tint(.white); Text(L("Перевожу…")).foregroundStyle(Theme.secondaryText) } }
                    if let failure { Text(failure).font(.aerial(.footnote)).foregroundStyle(Theme.secondaryText) }
                    Text(showOriginal ? review.text : translated ?? review.text).font(.aerial(.body)).textSelection(.enabled)
                }
                .padding(20)
            }
            // Без своего фона — лист на системном жидком стекле.
            .scrollContentBackground(.hidden)
            .navigationTitle(L("Отзыв"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("Готово")) { dismiss() } }
                if AI.enabled && AI.needsTranslation(review.text) {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(translated == nil || showOriginal ? L("Перевести") : L("Оригинал")) {
                            if translated == nil { Task { await runTranslation() } } else { showOriginal.toggle() }
                        }
                        .disabled(translating)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { if translate { await runTranslation() } }
    }

    private func runTranslation() async {
        guard AI.enabled, AI.needsTranslation(review.text), translated == nil else { return }
        translating = true
        defer { translating = false }
        do {
            translated = try await AI.translate(review.text)
            showOriginal = false
        } catch {
            if !HTTP.isCancellation(error) { failure = AI.failure(error) }
        }
    }
}

/// «Интересные факты», как на ТВ: раздел Википедии о создании и съёмках, ссылка на статью. Блок есть всегда —
/// пока грузится и когда статьи нет, это написано в нём (прежде без статьи раздел пропадал, и его не находили).
struct WikiStorySection: View {
    let item: VodItem

    @Environment(\.openURL) private var openURL
    @State private var story: WikiStory?
    @State private var loading = true
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ShelfHeader(title: L("Интересные факты"))
            VStack(alignment: .leading, spacing: 10) {
                if let story {
                    Text(story.text)
                        .font(.aerial(.subheadline))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(expanded ? nil : 8)
                        .onTapGesture { withAnimation(.easeOut) { expanded.toggle() } }
                    HStack {
                        if !expanded { Button(L("Ещё")) { withAnimation(.easeOut) { expanded = true } }.font(.aerial(.subheadline, .semibold)) }
                        Spacer()
                        Button { openURL(story.source) } label: {
                            Label(L("Википедия · %@", story.heading), systemImage: "book").font(.aerial(.caption))
                        }
                        .foregroundStyle(Theme.secondaryText)
                    }
                } else {
                    Text(loading ? L("Загружаем интересные факты…") : L("История создания пока недоступна в Википедии"))
                        .font(.aerial(.subheadline))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 16)
        }
        .task(id: item.id) {
            guard story == nil else { return }
            story = await Wiki.story(item)
            loading = false
        }
    }
}

/// Предпросмотр «духовного родственника»: постер, название и год, весь текст «чем связан» — на стекле поверх
/// размытого постера, как предпросмотр серии.
private struct RelativePreview: View {
    let row: Relative

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            PosterCard(item: row.item, width: 110)
            VStack(alignment: .leading, spacing: 6) {
                Text(row.item.title).font(.aerial(.headline))
                Text([row.item.year, row.item.kindLabel].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.aerial(.caption)).foregroundStyle(Theme.secondaryText)
                Text(row.why)
                    .font(.aerial(.subheadline))
                    .frame(width: 186, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
        .background {
            CachedImage(path: row.item.poster, size: "w185", pixelWidth: 200)
                .blur(radius: 30, opaque: true)
                .overlay(Color.black.opacity(0.4))
        }
        .glass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .foregroundStyle(.white)
    }
}
