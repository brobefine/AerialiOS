import SwiftUI

/// Раздачи фильма или серии в стиле iOS 26: карточки на тёмном фоне, фильтр качества капсулами сверху и свайпом по
/// странице, сортировка в стеклянной кнопке. Касание — раздача в TorrServer, затем файл и плеер.
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
    @State private var sort: Sort = .seeds
    @State private var opening: Release?
    @State private var picking: Picking?
    @State private var failure: String?

    enum Sort: String, CaseIterable, Identifiable {
        case seeds = "По сидам"
        case size = "По размеру"
        case date = "По дате"
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
        let filtered = filter == Self.all ? releases : releases.filter { infos[$0.id]?.quality == filter }
        let sorted: [Release] = switch sort {
        case .seeds: filtered.sorted { $0.seeds > $1.seeds }
        case .size: filtered.sorted { $0.bytes > $1.bytes }
        case .date: filtered.sorted { $0.published > $1.published }
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
        TabView(selection: $filter) {
            ForEach(filters, id: \.self) { value in
                page(value).tag(value)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(Theme.background)
        .safeAreaInset(edge: .top, spacing: 0) {
            if !releases.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(filters, id: \.self) { value in
                            Chip(title: value, selected: filter == value) { withAnimation(.snappy) { filter = value } }
                                .accessibilityIdentifier("quality-\(value)")
                        }
                    }
                }
                .contentMargins(.horizontal, 16, for: .scrollContent)
                .scrollIndicators(.hidden)
                .padding(.vertical, 8)
            }
        }
        .navigationTitle(episode.map { "\(item.title) · \($0.code)" } ?? item.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
        .sheet(item: $picking) { picking in
            FilesSheet(info: picking.info, episode: episode) { file in
                self.picking = nil
                play(picking.release, file)
            }
        }
        .alert("Не удалось открыть раздачу", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
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
                    Text("\(list.count) \(Format.plural(list.count, "раздача", "раздачи", "раздач"))")
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
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .refreshable { await search() }
    }

    private func search() async {
        loading = releases.isEmpty
        let imdb = await Catalogue.shared.imdbId(item)
        let parser = ReleaseSearch.Parser(address: settings.parserAddress, key: settings.parserKey, torrentio: settings.torrentio)
        let found = await ReleaseSearch.search(item: item, episode: episode, imdbId: imdb, parser: parser)
        let parsed = await Task.detached(priority: .userInitiated) {
            Dictionary(found.map { ($0.id, $0.info) }, uniquingKeysWith: { first, _ in first })
        }.value
        guard !Task.isCancelled else { return }
        infos = parsed
        releases = found
        loading = false
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
                if let file = EpisodeMatch.pick(info.files, episode: episode) {
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

    private func play(_ release: Release, _ file: TorrentFile) {
        let entry = library.entry(item, episode)
        playback.play(PlaybackRequest(item: item, episode: episode, link: release.link, fileIndex: file.index,
                                      releaseTitle: release.title, startAt: entry?.resumable == true ? entry?.position ?? 0 : 0,
                                      runtimeMinutes: runtime))
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

/// Выбор файла раздачи, когда он не очевиден: сериал без координат серии или фильм с несколькими частями.
private struct FilesSheet: View {
    let info: TorrentInfo
    let episode: VodEpisode?
    let onPick: (TorrentFile) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(info.files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) { file in
                Button { onPick(file) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(file.name).font(.subheadline).foregroundStyle(.white).lineLimit(3)
                        HStack(spacing: 8) {
                            Text(Format.bytes(file.bytes))
                            if let found = EpisodeMatch.coordinates(file.path) {
                                Text("\(found.season)x\(found.episode)")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                    }
                }
            }
            .navigationTitle(episode.map { "Файл для \($0.code)" } ?? "Выберите файл")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
