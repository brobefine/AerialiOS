import SwiftUI

/// «Торренты», как на ТВ: раздачи в базе TorrServer и «Добавить торрент» — магнет-ссылка, хэш или адрес .torrent.
/// Касание — окно «Смотреть» (серия или файл), смахивание — удалить из сервера.
struct TorrentsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Playback.self) private var playback

    @State private var torrents: [TorrentInfo] = []
    @State private var loading = true
    @State private var link = ""
    @State private var adding = false
    @State private var opening: String?
    @State private var picking: Picking?
    @State private var failure: String?
    @State private var afterSheet: (() -> Void)?

    struct Picking: Identifiable {
        let item: VodItem
        let info: TorrentInfo
        var id: String { info.hash }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Магнет-ссылка или адрес .torrent", text: $link)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onSubmit(add)
                    if adding {
                        ProgressView()
                    } else {
                        Button("Добавить", action: add)
                            .disabled(!TorrServerClient.validLink(link))
                    }
                }
            } header: {
                Text("Добавить торрент")
            }
            Section {
                ForEach(torrents, id: \.hash) { info in
                    Button { open(info) } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(info.title).font(.aerial(.subheadline)).foregroundStyle(.white).lineLimit(2)
                                Text(info.files.isEmpty ? "Метаданные ещё не получены"
                                     : "\(info.files.count) \(Format.plural(info.files.count, "видеофайл", "видеофайла", "видеофайлов")) · \(Format.bytes(info.files.reduce(0) { $0 + $1.bytes }))")
                                    .font(.aerial(.caption)).foregroundStyle(Theme.secondaryText)
                            }
                            Spacer(minLength: 0)
                            if opening == info.hash { ProgressView() }
                        }
                    }
                    .disabled(opening != nil)
                }
                .onDelete { offsets in
                    let gone = offsets.map { torrents[$0] }
                    torrents.remove(atOffsets: offsets)
                    Task {
                        guard let client = try? await Torrents.client(settings) else { return }
                        for info in gone { try? await client.remove(info.hash) }
                    }
                }
            } header: {
                Text("В TorrServer")
            } footer: {
                Text("Здесь раздачи, которые уже открывались. Смахните влево, чтобы удалить.")
            }
        }
        .overlay {
            if loading && torrents.isEmpty { ProgressView() }
        }
        .navigationTitle("Торренты")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .sheet(item: $picking, onDismiss: {
            afterSheet?()
            afterSheet = nil
        }) { picking in
            WatchSheet(item: picking.item, info: picking.info, voices: [], episode: nil) { file, episode, voice in
                var request = PlaybackRequest(item: picking.item, episode: episode, link: "magnet:?xt=urn:btih:\(picking.info.hash)",
                                              fileIndex: file.index, releaseTitle: picking.info.title)
                request.voice = voice
                afterSheet = { playback.play(request) }
                self.picking = nil
            }
        }
        .alert("Не удалось", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func load() async {
        defer { loading = false }
        do {
            torrents = try await Torrents.client(settings).list()
        } catch {
            if !HTTP.isCancellation(error) { failure = error.localizedDescription }
        }
    }

    private func add() {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TorrServerClient.validLink(text), !adding else { return }
        adding = true
        Task {
            defer { adding = false }
            do {
                let client = try await Torrents.client(settings)
                let info = try await client.awaitFiles(client.add(link: text))
                link = ""
                torrents.removeAll { $0.hash == info.hash }
                torrents.insert(info, at: 0)
                show(info)
            } catch {
                if !HTTP.isCancellation(error) { failure = error.localizedDescription }
            }
        }
    }

    private func open(_ info: TorrentInfo) {
        opening = info.hash
        Task {
            defer { opening = nil }
            do {
                let client = try await Torrents.client(settings)
                show(try await client.awaitFiles(client.get(info.hash)))
            } catch {
                if !HTTP.isCancellation(error) { failure = error.localizedDescription }
            }
        }
    }

    /// Серии в файлах — сериал (окно предложит сезон и серию), иначе фильм.
    private func show(_ info: TorrentInfo) {
        let series = info.files.filter { EpisodeMatch.coordinates($0.path) != nil }.count > 1
        let item = VodItem(id: "torrent:\(info.hash)", remoteId: 0, kind: series ? .series : .movie, title: info.title)
        if info.files.count == 1, let file = info.files.first {
            playback.play(PlaybackRequest(item: item, link: "magnet:?xt=urn:btih:\(info.hash)", fileIndex: file.index,
                                          releaseTitle: info.title))
        } else {
            picking = Picking(item: item, info: info)
        }
    }
}
