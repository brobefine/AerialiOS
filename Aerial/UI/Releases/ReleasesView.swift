import SwiftUI

/// Раздачи фильма или серии в стиле iOS 26: карточки на тёмном фоне, фильтр качества капсулами сверху и свайпом по
/// странице, сортировка в стеклянной кнопке. Касание — раздача в TorrServer, затем файл и плеер; удержание — «Скачать».
/// Сортировка и выбранное качество запоминаются между страницами, как `releasePrefs` ТВ.
struct ReleasesView: View {
    let item: VodItem
    let episode: VodEpisode?
    let runtime: Int

    @Environment(AppSettings.self) private var settings
    @Environment(Library.self) private var library
    @Environment(Playback.self) private var playback

    @State private var releases: [Release] = []
    /// Разбор названий — регулярными выражениями, поэтому один раз на раздачу и не в потоке интерфейса.
    @State private var infos: [String: ReleaseInfo] = [:]
    @State private var loading = true
    @State private var filter = ReleasesView.all
    @AppStorage("releases.sort") private var sort: Sort = .seeds
    @AppStorage("releases.quality") private var preferredQuality = ""
    @State private var notice: String?
    @State private var opening: Release?
    @State private var picking: Picking?
    /// Плеер после закрытия окна «Смотреть»: показ поверх ещё закрывающегося листа iOS молча отклоняла.
    @State private var afterSheet: (() -> Void)?
    @State private var failure: String?
    /// Фильтры раздач, как на ТВ (`ReleaseFilter`): перевод, HDR, Dolby Vision, субтитры, трекер; пусто — любое.
    @State private var voiceFilter = ""
    @State private var trackerFilter = ""
    @State private var hdrOnly = false
    @State private var dvOnly = false
    @State private var subsOnly = false
    @State private var languageFilter = ""
    @State private var seasonFilter = ""
    @State private var yearFilter = ""
    @State private var threeDOnly = false
    @State private var facts: [String: ReleaseFacts] = [:]

    enum Sort: String, CaseIterable, Identifiable {
        case seeds = "По сидам"
        case size = "По размеру"
        case date = "По дате"
        case name = "По названию"
        case tracker = "По источнику"
        case viewed = "Просмотренные"
        var id: String { rawValue }
    }

    struct Picking: Identifiable {
        let release: Release
        let info: TorrentInfo
        var id: String { release.id }
    }

    private static let all = "Все"
    private static let qualities = ["4K", "1080p", "720p", "SD"]

    /// Страницы фильтра: «Все» и те качества, что есть в выдаче.
    private var filters: [String] {
        [Self.all] + Self.qualities.filter { wanted in infos.values.contains { $0.quality == wanted } }
    }

    private func shown(_ filter: String) -> [Release] {
        let filtered = (filter == Self.all ? releases : releases.filter { infos[$0.id]?.quality == filter }).filter { release in
            let info = infos[release.id] ?? release.info
            let fact = facts[release.id]
            return (voiceFilter.isEmpty || info.audio.contains(voiceFilter))
                && (trackerFilter.isEmpty || (fact?.trackers.contains(trackerFilter) ?? (release.tracker == trackerFilter)))
                && (languageFilter.isEmpty || fact?.languages.contains(languageFilter) == true)
                && (seasonFilter.isEmpty || info.season == seasonFilter)
                && (yearFilter.isEmpty || fact?.year == yearFilter)
                && (!threeDOnly || fact?.threeD == true)
                && (!hdrOnly || info.range != nil) && (!dvOnly || info.dolbyVision) && (!subsOnly || info.subtitles)
        }
        let sorted: [Release] = switch sort {
        case .seeds: filtered.sorted { $0.seeds > $1.seeds }
        case .size: filtered.sorted { $0.bytes > $1.bytes }
        case .date: filtered.sorted { $0.published > $1.published }
        case .name: filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .tracker: filtered.sorted { ($0.tracker.lowercased(), -$0.seeds) < ($1.tracker.lowercased(), -$1.seeds) }
        case .viewed:
            // Сначала раздачи, которые уже смотрели (их ссылка в прогрессе медиатеки), затем по сидам.
            filtered.sorted { (viewed.contains($0.link) ? 0 : 1, -$0.seeds) < (viewed.contains($1.link) ? 0 : 1, -$1.seeds) }
        }
        // Для серии — сначала раздачи с её сезоном, затем без указания сезона, в конце — другие сезоны.
        guard let episode else { return sorted }
        func rank(_ release: Release) -> Int {
            guard let seasons = infos[release.id]?.seasons else { return 1 }
            return seasons.contains(episode.season) ? 0 : 2
        }
        return sorted.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    var body: some View {
        // Страницы во весь экран, как на главной: `TabView` со страницами обрезался по безопасной зоне — сверху и
        // снизу были чёрные полосы. Отступы под панель, капсулы качества и пилюлю — полями прокрутки.
        GeometryReader { geometry in
            let chips: CGFloat = releases.isEmpty ? 0 : 52
            ZStack(alignment: .top) {
                TabView(selection: $filter) {
                    ForEach(filters, id: \.self) { value in
                        page(value)
                            .contentMargins(.top, geometry.safeAreaInsets.top + chips, for: .scrollContent)
                            .contentMargins(.bottom, geometry.safeAreaInsets.bottom + 8, for: .scrollContent)
                            .tag(value)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()
                if !releases.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(filters, id: \.self) { value in
                                Chip(title: value, selected: filter == value) {
                                    withAnimation(.snappy) { filter = value }
                                }
                                .accessibilityIdentifier("quality-\(value)")
                            }
                        }
                    }
                    .contentMargins(.horizontal, 16, for: .scrollContent)
                    .scrollIndicators(.hidden)
                    .frame(height: 36)
                    .padding(.vertical, 8)
                }
            }
        }
        .background(Theme.background)
        .navigationTitle(episode.map { "\(item.title) · \($0.code)" } ?? item.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    let voices = Dictionary(grouping: infos.values.flatMap(\.audio), by: { $0 })
                        .sorted { $0.value.count > $1.value.count }.map(\.key)
                    if !voices.isEmpty {
                        Picker("Перевод", selection: $voiceFilter) {
                            Text("Любой").tag("")
                            ForEach(voices, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.menu)
                    }
                    let languages = [ReleaseFacts.ru, ReleaseFacts.uk, ReleaseFacts.en].filter { code in facts.values.contains { $0.languages.contains(code) } }
                    if !languages.isEmpty {
                        Picker("Язык", selection: $languageFilter) {
                            Text("Любой").tag("")
                            ForEach(languages, id: \.self) { Text(ReleaseFacts.languageTitle($0)).tag($0) }
                        }
                        .pickerStyle(.menu)
                    }
                    let seasons = Array(Set(infos.values.compactMap(\.season))).sorted()
                    if !seasons.isEmpty {
                        Picker("Сезон", selection: $seasonFilter) {
                            Text("Любой").tag("")
                            ForEach(seasons, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.menu)
                    }
                    let years = Array(Set(facts.values.map(\.year).filter { !$0.isEmpty })).sorted(by: >)
                    if years.count > 1 {
                        Picker("Год", selection: $yearFilter) {
                            Text("Любой").tag("")
                            ForEach(years, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.menu)
                    }
                    let trackers = Array(Set(facts.values.flatMap(\.trackers))).sorted()
                    if trackers.count > 1 {
                        Picker("Трекер", selection: $trackerFilter) {
                            Text("Любой").tag("")
                            ForEach(trackers, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.menu)
                    }
                    Toggle("HDR", isOn: $hdrOnly)
                    Toggle("Dolby Vision", isOn: $dvOnly)
                    Toggle("С субтитрами", isOn: $subsOnly)
                    if facts.values.contains(where: \.threeD) { Toggle("3D", isOn: $threeDOnly) }
                    if filtersActive {
                        Button("Сбросить фильтры", role: .destructive) {
                            voiceFilter = ""; trackerFilter = ""; hdrOnly = false; dvOnly = false; subsOnly = false
                            languageFilter = ""; seasonFilter = ""; yearFilter = ""; threeDOnly = false
                        }
                    }
                } label: {
                    Image(systemName: filtersActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Фильтры")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Сортировка", selection: $sort) {
                        ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
        }
        .overlay {
            if loading {
                ProgressView("Ищу раздачи…").tint(.white)
            } else if releases.isEmpty {
                ContentUnavailableView("Раздач не нашлось", systemImage: "magnifyingglass",
                                       description: Text("Попробуйте другой сервер поиска в настройках."))
            }
        }
        .task { await search() }
        .onChange(of: filter) { _, value in
            // Свайп и капсула — выбор зрителя: в следующий раз страница откроется на этом качестве.
            if !releases.isEmpty { preferredQuality = value == Self.all ? "" : value }
        }
        .sheet(item: $picking, onDismiss: {
            afterSheet?()
            afterSheet = nil
        }) { picking in
            WatchSheet(item: item, info: picking.info, voices: (infos[picking.release.id] ?? picking.release.info).audio,
                       episode: episode) { file, chosen, voice in
                afterSheet = { play(picking.release, file, episode: chosen, voice: voice) }
                self.picking = nil
            }
        }
        .alert("Не удалось открыть раздачу", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
        .alert("Загрузка", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }

    private func page(_ filter: String) -> some View {
        let list = shown(filter)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let entry = library.entry(item, episode), entry.resumable, let source = entry.source {
                    Button { playback.resume(entry) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "play.fill").font(.title3)
                                .frame(width: 44, height: 44)
                                .background(.white, in: Circle())
                                .foregroundStyle(.black)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Продолжить с \(Format.clock(entry.position))").font(.headline)
                                Text(source.releaseTitle).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .glass(in: RoundedRectangle(cornerRadius: 24, style: .continuous), interactive: true)
                    }
                    .buttonStyle(.plain)
                }
                if !list.isEmpty {
                    Text("\(list.count) \(Format.plural(list.count, "раздача", "раздачи", "раздач")) · удерживайте, чтобы скачать")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 4)
                }
                ForEach(list) { release in
                    Button { open(release) } label: {
                        ReleaseCard(release: release, info: infos[release.id] ?? release.info, busy: opening?.id == release.id)
                    }
                    .buttonStyle(.plain)
                    .disabled(opening != nil)
                    .accessibilityIdentifier("release")
                    .contextMenu {
                        Button { download(release, all: false) } label: {
                            Label(episode == nil ? "Скачать" : "Скачать серию", systemImage: "arrow.down.circle")
                        }
                        if item.kind == .series {
                            Button { download(release, all: true) } label: {
                                Label("Скачать все серии раздачи", systemImage: "square.and.arrow.down.on.square")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .refreshable { await search() }
    }

    private var filtersActive: Bool {
        !voiceFilter.isEmpty || !trackerFilter.isEmpty || hdrOnly || dvOnly || subsOnly
            || !languageFilter.isEmpty || !seasonFilter.isEmpty || !yearFilter.isEmpty || threeDOnly
    }

    /// Ссылки раздач, которые уже смотрели, — для сортировки «Просмотренные».
    private var viewed: Set<String> { Set(library.entries.values.compactMap { $0.source?.link }) }

    private func search() async {
        loading = releases.isEmpty
        let imdb = await Catalogue.shared.imdbId(item)
        let parser = ReleaseSearch.Parser(address: settings.parserAddress, key: settings.parserKey, torrentio: settings.torrentio)
        let found = await ReleaseSearch.search(item: item, episode: episode, imdbId: imdb, parser: parser)
        let (parsed, extra) = await Task.detached(priority: .userInitiated) {
            (Dictionary(found.map { ($0.id, $0.info) }, uniquingKeysWith: { first, _ in first }),
             Dictionary(found.map { ($0.id, ReleaseFacts($0)) }, uniquingKeysWith: { first, _ in first }))
        }.value
        guard !Task.isCancelled else { return }
        infos = parsed
        facts = extra
        releases = found
        loading = false
        if !preferredQuality.isEmpty, parsed.values.contains(where: { $0.quality == preferredQuality }) {
            filter = preferredQuality
        }
    }

    /// Скачать: фильм — главный файл, серия — её файл, «все серии» — все видеофайлы раздачи (серии подписаны по TMDb).
    private func download(_ release: Release, all: Bool) {
        opening = release
        Task {
            defer { opening = nil }
            do {
                let client = try await Torrents.client(settings)
                let poster = TMDbImage.urls(item.poster, "w342").first?.absoluteString ?? ""
                var info = try await client.add(link: release.link, title: item.title, poster: poster)
                info = try await client.awaitFiles(info)
                let chosen: [TorrentFile]
                if all {
                    chosen = info.files
                } else if let file = EpisodeMatch.pick(info.files, episode: episode)
                            ?? (episode == nil ? info.files.max(by: { $0.bytes < $1.bytes }) : nil) {
                    chosen = [file]
                } else {
                    notice = "В раздаче не нашёлся файл серии \(episode?.code ?? ""). Можно скачать все серии раздачи."
                    return
                }
                var seasons: [Int: [VodEpisode]] = [:]
                if item.kind == .series {
                    for season in Set(chosen.compactMap { EpisodeMatch.coordinates($0.path)?.season }) {
                        seasons[season] = (try? await Catalogue.shared.season(item, season)) ?? []
                    }
                }
                let files = chosen.map { file -> DownloadFile in
                    var meta: VodEpisode?
                    if let place = EpisodeMatch.coordinates(file.path) {
                        meta = seasons[place.season]?.first { $0.number == place.episode }
                            ?? VodEpisode(season: place.season, number: place.episode, title: "Серия \(place.episode)")
                    } else if !all {
                        meta = episode
                    }
                    return DownloadFile(index: file.index, path: file.path, bytes: file.bytes, episode: meta)
                }
                notice = Downloads.shared.add(item: item, link: release.link, releaseTitle: release.title, info: info, files: files)
                    ?? "Загрузка началась — она в Медиатеке. Качается, пока приложение открыто."
            } catch {
                if !HTTP.isCancellation(error) { failure = error.localizedDescription }
            }
        }
    }

    private func open(_ release: Release) {
        opening = release
        Task {
            defer { opening = nil }
            do {
                let client = try await Torrents.client(settings)
                let poster = TMDbImage.urls(item.poster, "w342").first?.absoluteString ?? ""
                var info = try await client.add(link: release.link, title: item.title, poster: poster)
                info = try await client.awaitFiles(info)
                // Окно «Смотреть», как на ТВ: озвучка, сезон и серия из файлов раздачи (у фильма — файл, если их
                // несколько). Выбирать нечего — сразу в плеер.
                let voices = (infos[release.id] ?? release.info).audio
                if voices.count < 2 && info.files.count < 2, let file = info.files.first {
                    play(release, file)
                } else {
                    picking = Picking(release: release, info: info)
                }
            } catch {
                if !HTTP.isCancellation(error) {
                    Log.note("РАЗДАЧИ", "открыть «\(release.title)»: \(error.localizedDescription)")
                    failure = error.localizedDescription
                }
            }
        }
    }

    private func play(_ release: Release, _ file: TorrentFile, episode chosen: VodEpisode? = nil, voice: String? = nil) {
        let target = chosen ?? episode
        let entry = library.entry(item, target)
        var request = PlaybackRequest(item: item, episode: target, link: release.link, fileIndex: file.index,
                                      releaseTitle: release.title, startAt: entry?.resumable == true ? entry?.position ?? 0 : 0,
                                      runtimeMinutes: target.map { $0.runtimeMinutes > 0 ? $0.runtimeMinutes : runtime } ?? runtime)
        request.voice = voice
        playback.play(request)
    }
}

/// Карточка раздачи: название, плашки качества, затем размер, сиды и трекер, озвучки.
private struct ReleaseCard: View {
    let release: Release
    let info: ReleaseInfo
    let busy: Bool

    private var seedColor: Color {
        release.seeds >= 10 ? Color(hex: 0x3DDC84) : release.seeds > 0 ? Color(hex: 0xFFC83D) : Color(hex: 0xFF5A4E)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Text(release.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if busy { ProgressView().tint(.white) }
            }
            let tags = info.tags + [info.season].compactMap { $0 }
            if !tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(Array(tags.enumerated()), id: \.offset) { index, tag in
                        TagLabel(text: tag, highlighted: index == 0 && tag == info.quality)
                    }
                }
            }
            HStack(spacing: 14) {
                Label(Format.bytes(release.bytes), systemImage: "internaldrive")
                Label("\(release.seeds)", systemImage: "arrow.up").foregroundStyle(seedColor)
                Text(release.tracker).lineLimit(1)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Theme.secondaryText)
            .labelStyle(TightLabel())
            if !info.audio.isEmpty {
                Label(info.audio.joined(separator: ", "), systemImage: "waveform")
                    .font(.caption2)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
                    .labelStyle(TightLabel())
            }
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

/// Окно «Смотреть» перед плеером, как на ТВ: озвучка из названия раздачи, сезон и серия — из файлов раздачи
/// (серии подписаны по TMDb); у фильма из нескольких файлов — выбор файла. Лист на стекле снизу.
struct WatchSheet: View {
    let item: VodItem
    let info: TorrentInfo
    let voices: [String]
    let episode: VodEpisode?
    let onPlay: (TorrentFile, VodEpisode?, String?) -> Void

    @State private var voice = ""
    @State private var season = 0
    @State private var fileIndex = -1
    @State private var titles: [Int: [VodEpisode]] = [:]

    private struct Placed: Identifiable {
        let file: TorrentFile
        let season: Int
        let number: Int
        var id: Int { file.index }
    }

    private var placed: [Placed] {
        info.files.compactMap { file in
            EpisodeMatch.coordinates(file.path).map { Placed(file: file, season: $0.season, number: $0.episode) }
        }
        .sorted { ($0.season, $0.number) < ($1.season, $1.number) }
    }

    private var series: Bool { item.kind == .series && !placed.isEmpty }
    private var seasons: [Int] { Array(Set(placed.map(\.season))).sorted() }
    private var files: [TorrentFile] { info.files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending } }

    private func meta(_ place: Placed) -> VodEpisode {
        titles[place.season]?.first { $0.number == place.number }
            ?? VodEpisode(season: place.season, number: place.number, title: "Серия \(place.number)")
    }

    var body: some View {
        NavigationStack {
            Form {
                if voices.count > 1 {
                    Picker("Озвучка", selection: $voice) {
                        Text("Как в раздаче").tag("")
                        ForEach(voices, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                if series {
                    Section {
                        if seasons.count > 1 {
                            Picker("Сезон", selection: $season) {
                                ForEach(seasons, id: \.self) { Text("Сезон \($0)").tag($0) }
                            }
                        }
                        Picker("Серия", selection: $fileIndex) {
                            ForEach(placed.filter { $0.season == season }) { place in
                                Text("\(place.number). \(meta(place).title)").tag(place.file.index)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                } else if files.count > 1 {
                    Section("Файл") {
                        Picker("Файл", selection: $fileIndex) {
                            ForEach(files) { file in
                                VStack(alignment: .leading) {
                                    Text(file.name).lineLimit(2)
                                    Text(Format.bytes(file.bytes)).font(.caption).foregroundStyle(Theme.secondaryText)
                                }
                                .tag(file.index)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }
                Section {
                    Button(action: play) {
                        Label("Смотреть", systemImage: "play.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .accessibilityIdentifier("watch-sheet-play")
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Смотреть")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .onAppear(perform: preselect)
        .onChange(of: season) { _, value in
            if placed.first(where: { $0.file.index == fileIndex })?.season != value {
                fileIndex = placed.first { $0.season == value }?.file.index ?? fileIndex
            }
        }
        .task(id: season) {
            guard series, season > 0, titles[season] == nil else { return }
            titles[season] = (try? await Catalogue.shared.season(item, season)) ?? []
        }
    }

    private func play() {
        guard let file = info.files.first(where: { $0.index == fileIndex }) ?? info.files.first else { return }
        let place = placed.first { $0.file.index == file.index }
        onPlay(file, place.map(meta) ?? episode, voice.isEmpty ? nil : voice)
    }

    /// Начальный выбор: нужная серия (или первая), у фильма — самый большой файл.
    private func preselect() {
        if series {
            let wanted = EpisodeMatch.pick(info.files, episode: episode).flatMap { file in placed.first { $0.file.index == file.index } }
                ?? placed.first
            season = wanted?.season ?? 0
            fileIndex = wanted?.file.index ?? -1
        } else {
            fileIndex = info.files.max(by: { $0.bytes < $1.bytes })?.index ?? -1
        }
    }
}
