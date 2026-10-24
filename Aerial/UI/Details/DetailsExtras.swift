import SwiftUI

// Разделы страницы фильма из ТВ: «Духовные родственники» и «Разбор фильма» (ИИ), отзывы TMDb со сводкой и переводом,
// «История создания» из Википедии.

/// Работа и чем она связана с открытой («why» от ИИ).
struct Relative: Identifiable {
    var item: VodItem
    var why: String
    var id: String { item.id }
}

/// «Духовные родственники»: связанные темой, настроением, вопросами — не жанром. Что ИИ уже советовал трём и более
/// разным фильмам, идёт в «не предлагать» и отсеивается (против «ленивых» повторов одного канона).
struct RelativesSection: View {
    let details: VodDetails

    @Environment(Library.self) private var library
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var items: [Relative] = []
    @State private var failure: String?
    @State private var loading = false

    private static let logKey = "ai.relativeLog"

    var body: some View {
        Group {
            if !items.isEmpty || loading || failure != nil {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        ShelfHeader(title: "Духовные родственники")
                        Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                    }
                    if let failure, items.isEmpty {
                        Text(failure).font(.footnote).foregroundStyle(Theme.secondaryText).padding(.horizontal, 16)
                    } else if items.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().tint(.white)
                            Text("ИИ подбирает фильмы по темам…").font(.footnote).foregroundStyle(Theme.secondaryText)
                        }
                        .padding(.horizontal, 16)
                    } else {
                        let width = Theme.posterWidth(sizeClass)
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 12) {
                                ForEach(items) { row in
                                    NavigationLink(value: Route.details(row.item)) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            PosterCard(item: row.item, width: width)
                                            Text(row.why).font(.caption2).foregroundStyle(Theme.secondaryText)
                                                .lineLimit(3, reservesSpace: true).frame(width: width, alignment: .leading)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu { PosterMenu(item: row.item) }
                                }
                            }
                        }
                        .contentMargins(.horizontal, 16, for: .scrollContent)
                        .scrollIndicators(.hidden)
                    }
                }
            }
        }
        .task(id: details.item.id) { await load() }
    }

    private func load() async {
        guard AI.enabled, items.isEmpty else { return }
        loading = true
        defer { loading = false }
        let log = UserDefaults.standard.dictionary(forKey: Self.logKey) as? [String: [String]] ?? [:]
        var counts: [String: Int] = [:]
        for titles in log.values { for title in titles { counts[title, default: 0] += 1 } }
        let overused = Set(counts.filter { $0.value >= 3 }.keys)
        // Сбой — ещё одна попытка через 5 с; отказ по стране повтором не лечится.
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(5)) }
            do {
                let picks = try await AI.relatives(details, avoid: Array(overused.prefix(40)))
                let franchise = Set(details.collection.map(\.id))
                let rejected = library.rejected
                var found: [Relative] = []
                var seen = Set<String>()
                let resolved = await Taste.resolve(picks)
                for item in resolved where item.id != details.item.id && !rejected.contains(item.id) && !franchise.contains(item.id)
                    && seen.insert(item.id).inserted {
                    let why = picks.first { SearchText.normalized($0.title) == SearchText.normalized(item.title)
                        || SearchText.normalized($0.original) == SearchText.normalized(item.originalTitle) }?.why ?? ""
                    found.append(Relative(item: item, why: why))
                }
                let fresh = found.filter { !overused.contains($0.item.title) }
                if fresh.count >= 5 { found = fresh }
                guard !found.isEmpty else { continue }
                var updated = log
                updated[details.item.id] = found.map(\.item.title)
                if updated.count > 60, let first = updated.keys.sorted().first { updated[first] = nil }
                UserDefaults.standard.set(updated, forKey: Self.logKey)
                items = found
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

/// «Разбор фильма» — открыт после просмотра: фильм досмотрен до 98 %, у сериала — хотя бы одна серия (разбор до неё).
struct RecapCard: View {
    let details: VodDetails

    @Environment(Library.self) private var library
    @State private var open = false

    private var latest: WatchEntry? { library.latest(for: details.item) }

    private var unlocked: Bool {
        if details.item.kind == .series { return latest?.episode != nil }
        return (library.entry(details.item)?.fraction ?? 0) >= 0.98
    }

    var body: some View {
        if AI.enabled {
            Button { open = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: unlocked ? "text.book.closed" : "lock")
                        .font(.title3)
                        .frame(width: 40, height: 40)
                        .background(Theme.accent.opacity(0.18), in: Circle())
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(details.item.kind == .series ? "Разбор сериала" : "Разбор фильма").font(.headline)
                        Text(unlocked ? subtitle : "Откроется после просмотра — в нём спойлеры")
                            .font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").foregroundStyle(Theme.secondaryText)
                }
                .padding(14)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!unlocked)
            .padding(.horizontal, 16)
            .sheet(isPresented: $open) {
                RecapSheet(details: details, season: latest?.episode?.season ?? 0, episode: latest?.episode?.number ?? 0)
            }
        }
    }

    private var subtitle: String {
        if let episode = latest?.episode { return "Сюжет, мотивы, скрытые детали — до \(episode.code) включительно" }
        return "Сюжет, мотивы, отношения, скрытые детали и открытые вопросы"
    }
}

private struct RecapSheet: View {
    let details: VodDetails
    let season: Int
    let episode: Int

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
                            Text("ИИ разбирает \(details.item.kind == .series ? "сериал" : "фильм")…").foregroundStyle(Theme.secondaryText)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    }
                    if let message {
                        Text(message).foregroundStyle(Theme.secondaryText)
                    }
                    ForEach(sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title).font(.title3.weight(.bold))
                            Text(section.text).font(.body).foregroundStyle(.white.opacity(0.9)).textSelection(.enabled)
                        }
                    }
                }
                .padding(20)
            }
            .background(Theme.background)
            .navigationTitle(details.item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            // Опора — раздел «Сюжет» Википедии; только у фильмов: у сериалов там сюжет всех сезонов — спойлеры.
            var plot = ""
            if details.item.kind == .movie { plot = await Wiki.plot(details.item)?.text ?? "" }
            if let found = try await AI.recap(details, season: season, episode: episode, plot: plot) {
                sections = found
            } else {
                message = "ИИ не знает именно эту работу достаточно хорошо — разбора нет, чтобы не пересказывать другую."
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
        Group {
            if !reviews.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        ShelfHeader(title: "Отзывы · \(reviews.count)")
                        Spacer()
                        Menu {
                            Picker("Порядок", selection: $sort) {
                                Text("Сначала с высокой оценкой").tag("rating")
                                Text("Сначала новые").tag("new")
                                Text("Сначала подробные").tag("long")
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down").font(.subheadline.weight(.semibold))
                        }
                        .padding(.trailing, 16)
                    }
                    if let summary {
                        Label { Text(summary).font(.subheadline) } icon: { Image(systemName: "sparkles").foregroundStyle(Theme.accent) }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .padding(.horizontal, 16)
                    } else if summaryPending {
                        HStack(spacing: 8) {
                            ProgressView().tint(.white)
                            Text("ИИ читает отзывы…").font(.footnote).foregroundStyle(Theme.secondaryText)
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
                Text(review.author).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if review.rating > 0 { RatingRing(value: review.rating, size: 28) }
            }
            Text(review.text).font(.footnote).foregroundStyle(.white.opacity(0.85)).lineLimit(6, reservesSpace: true)
            if !review.date.isEmpty { Text(Format.date(review.date)).font(.caption2).foregroundStyle(Theme.secondaryText) }
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
                        Text(review.author).font(.headline)
                        Spacer()
                        if review.rating > 0 { RatingRing(value: review.rating, size: 34) }
                    }
                    if translating { HStack(spacing: 8) { ProgressView().tint(.white); Text("Перевожу…").foregroundStyle(Theme.secondaryText) } }
                    if let failure { Text(failure).font(.footnote).foregroundStyle(Theme.secondaryText) }
                    Text(showOriginal ? review.text : translated ?? review.text).font(.body).textSelection(.enabled)
                }
                .padding(20)
            }
            .background(Theme.background)
            .navigationTitle("Отзыв")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
                if AI.enabled && AI.needsTranslation(review.text) {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(translated == nil || showOriginal ? "Перевести" : "Оригинал") {
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
            ShelfHeader(title: "Интересные факты")
            VStack(alignment: .leading, spacing: 10) {
                if let story {
                    Text(story.text)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(expanded ? nil : 8)
                        .onTapGesture { withAnimation(.easeOut) { expanded.toggle() } }
                    HStack {
                        if !expanded { Button("Ещё") { withAnimation(.easeOut) { expanded = true } }.font(.subheadline.weight(.semibold)) }
                        Spacer()
                        Button { openURL(story.source) } label: {
                            Label("Википедия · \(story.heading)", systemImage: "book").font(.caption)
                        }
                        .foregroundStyle(Theme.secondaryText)
                    }
                } else {
                    Text(loading ? "Загружаем интересные факты…" : "История создания пока недоступна в Википедии")
                        .font(.subheadline)
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
