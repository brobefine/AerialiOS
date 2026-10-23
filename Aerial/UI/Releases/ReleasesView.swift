import SwiftUI

/// Раздачи фильма или серии: поиск, фильтр по качеству, сортировка; касание — раздача в TorrServer, затем файл и плеер.
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
    @State private var quality: String?
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

    private static let qualities = ["4K", "1080p", "720p", "SD"]

    private var shown: [Release] {
        let filtered = quality.map { wanted in releases.filter { infos[$0.id]?.quality == wanted } } ?? releases
        switch sort {
        case .seeds: return filtered.sorted { $0.seeds > $1.seeds }
        case .size: return filtered.sorted { $0.bytes > $1.bytes }
        case .date: return filtered.sorted { $0.published > $1.published }
        }
    }

    var body: some View {
        List {
            if let entry = library.entry(item, episode), entry.resumable, let source = entry.source {
                Section {
                    Button { playback.resume(entry) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Продолжить с \(Format.clock(entry.position))", systemImage: "play.fill").font(.headline)
                            Text(source.releaseTitle).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(2)
                        }
                    }
                }
            }
            if !releases.isEmpty {
                Section {
                    qualityPicker.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                Section {
                    ForEach(shown) { release in
                        Button { open(release) } label: {
                            ReleaseRow(release: release, info: infos[release.id] ?? release.info, busy: opening?.id == release.id)
                        }
                        .buttonStyle(.plain)
                        .disabled(opening != nil)
                        .accessibilityIdentifier("release")
                    }
                } header: {
                    Text("\(shown.count) \(Format.plural(shown.count, "раздача", "раздачи", "раздач"))")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
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
        .refreshable { await search() }
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

    private var qualityPicker: some View {
        let present = Self.qualities.filter { wanted in infos.values.contains { $0.quality == wanted } }
        return ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip("Все", selected: quality == nil) { quality = nil }
                ForEach(present, id: \.self) { value in
                    chip(value, selected: quality == value) { quality = value }
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? .black : .white)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.12)), in: Capsule())
        }
        .buttonStyle(.plain)
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

/// Карточка раздачи: название, плашки качества, размер, сиды, трекер, озвучки.
private struct ReleaseRow: View {
    let release: Release
    let info: ReleaseInfo
    let busy: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Text(release.title).font(.subheadline).foregroundStyle(.white).lineLimit(3)
                let tags = info.tags + [info.season].compactMap { $0 }
                if !tags.isEmpty {
                    FlowLayout(spacing: 5) {
                        ForEach(Array(tags.enumerated()), id: \.offset) { index, tag in
                            TagLabel(text: tag, highlighted: index == 0 && tag == info.quality)
                        }
                    }
                }
                HStack(spacing: 12) {
                    Label(Format.bytes(release.bytes), systemImage: "internaldrive")
                    Label("\(release.seeds)", systemImage: "arrow.up.circle")
                        .foregroundStyle(release.seeds >= 10 ? Color(hex: 0x3DDC84) : release.seeds > 0 ? Theme.secondaryText : Color(hex: 0xFF5A4E))
                    Text(release.tracker).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                if !info.audio.isEmpty {
                    Text(info.audio.joined(separator: ", ")).font(.caption2).foregroundStyle(Theme.secondaryText).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if busy { ProgressView().tint(.white) }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
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
                                Text("С\(found.season) Э\(found.episode)")
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
