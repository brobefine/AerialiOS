import SwiftUI

/// Загрузки в медиатеке: карточка на раздачу — кадр, название, ход загрузки; касание — файлы и просмотр с диска.
struct DownloadsShelf: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var downloads: Downloads { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ShelfHeader(title: L("Загрузки"))
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(downloads.jobs) { job in
                        NavigationLink(value: Route.download(job.hash)) {
                            DownloadCard(job: job, width: Theme.landscapeWidth(sizeClass))
                        }
                        .buttonStyle(.plain)
                        .contextMenu { DownloadMenu(job: job) }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned(limitBehavior: .never))
            .scrollIndicators(.hidden)
        }
    }
}

/// Пауза, повтор и удаление загрузки.
private struct DownloadMenu: View {
    let job: DownloadJob
    private var downloads: Downloads { .shared }

    var body: some View {
        if !downloads.complete(job) {
            if job.paused {
                Button { downloads.pause(job, false) } label: { Label(L("Продолжить"), systemImage: "arrow.down.circle") }
            } else if job.failure != nil {
                Button { downloads.pause(job, false) } label: { Label(L("Повторить"), systemImage: "arrow.clockwise") }
            } else {
                Button { downloads.pause(job, true) } label: { Label(L("Пауза"), systemImage: "pause.circle") }
            }
        }
        Button(role: .destructive) { downloads.delete(job) } label: { Label(L("Удалить загрузку"), systemImage: "trash") }
    }
}

/// Состояние загрузки одной строкой: «Скачано 1,2 ГБ из 4,5 ГБ · 3 МБ/с», «Пауза», «Готово · 4,5 ГБ».
@MainActor
private func downloadStatus(_ job: DownloadJob) -> String {
    let downloads = Downloads.shared
    let done = downloads.done[job.hash] ?? 0
    if downloads.complete(job) { return L("Готово · %@", Format.bytes(job.totalBytes)) }
    if let failure = job.failure { return failure }
    let amount = L("%@ из %@", Format.bytes(done), Format.bytes(job.totalBytes))
    if job.paused { return L("Пауза · %@", amount) }
    if downloads.active == job.hash { return L("%@ · %@/с", amount, Format.bytes(downloads.rate)) }
    return L("В очереди · %@", amount)
}

private struct DownloadCard: View {
    let job: DownloadJob
    let width: CGFloat

    var body: some View {
        let downloads = Downloads.shared
        let fraction = job.totalBytes > 0 ? min(1, Double(downloads.done[job.hash] ?? 0) / Double(job.totalBytes)) : 0
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay { CachedImage(path: job.item.backdrop.isEmpty ? job.item.poster : job.item.backdrop, size: "w780", pixelWidth: Int(width * 3)) }
                .overlay(alignment: .bottom) {
                    if !downloads.complete(job) {
                        ZStack(alignment: .bottomLeading) {
                            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.white.opacity(0.3))
                                    Capsule().fill(Theme.accent).frame(width: geometry.size.width * fraction)
                                }
                            }
                            .frame(height: 4)
                            .padding(10)
                        }
                    }
                }
                .overlay {
                    Image(systemName: downloads.complete(job) ? "play.fill" : job.paused ? "pause.fill" : "arrow.down")
                        .font(.aerial(.title2)).foregroundStyle(.white)
                        .frame(width: 44, height: 44).glass(in: Circle())
                }
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(job.item.title).font(.aerial(.subheadline, .semibold)).lineLimit(1)
            Text(job.files.count > 1 ? "\(job.files.count) \(Format.plural(job.files.count, "файл", "файла", "файлов"))" : job.releaseTitle)
                .font(.aerial(.caption)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
            Text(downloadStatus(job)).font(.aerial(.caption2)).foregroundStyle(Theme.secondaryText).lineLimit(1)
        }
        .frame(width: width)
    }
}

/// Загрузка: файлы раздачи с ходом каждого; готовый файл — сразу в плеер с диска.
struct DownloadView: View {
    let hash: String

    @Environment(Library.self) private var library
    @Environment(Playback.self) private var playback
    private var downloads: Downloads { .shared }

    var body: some View {
        Group {
            if let job = downloads.jobs.first(where: { $0.hash == hash }) {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.releaseTitle).font(.aerial(.footnote)).foregroundStyle(Theme.secondaryText)
                            Text(downloadStatus(job)).font(.aerial(.footnote, .semibold))
                        }
                        NavigationLink(value: Route.details(job.item)) { Label(L("Страница"), systemImage: "info.circle") }
                    }
                    Section(L("Файлы")) {
                        ForEach(job.files) { file in
                            row(job, file)
                                .swipeActions {
                                    Button(role: .destructive) { downloads.deleteFile(job, file) } label: { Label(L("Удалить"), systemImage: "trash") }
                                }
                        }
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu { DownloadMenu(job: job) } label: { Image(systemName: "ellipsis") }
                    }
                }
                .navigationTitle(job.item.title)
            } else {
                ContentUnavailableView(L("Загрузка удалена"), systemImage: "arrow.down.circle")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ job: DownloadJob, _ file: DownloadFile) -> some View {
        let complete = downloads.isComplete(job, file)
        let entry = library.entry(job.item, file.episode)
        return Button {
            playback.play(PlaybackRequest(item: job.item, episode: file.episode, link: job.link, fileIndex: file.index,
                                          releaseTitle: job.releaseTitle, startAt: entry?.resumable == true ? entry?.position ?? 0 : 0,
                                          runtimeMinutes: file.episode?.runtimeMinutes ?? 0))
        } label: {
            HStack(spacing: 12) {
                Image(systemName: complete ? "play.circle.fill" : "arrow.down.circle")
                    .font(.aerial(.title2))
                    .foregroundStyle(complete ? Theme.accent : Theme.secondaryText)
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.episode.map { "\($0.code) · \($0.title)" } ?? file.name)
                        .font(.aerial(.subheadline)).foregroundStyle(.white).lineLimit(2)
                    Text(complete ? Format.bytes(file.bytes) : L("%@ · ещё не скачан", Format.bytes(file.bytes)))
                        .font(.aerial(.caption)).foregroundStyle(Theme.secondaryText)
                    if let entry, entry.fraction > 0 {
                        ProgressView(value: entry.fraction).tint(.white)
                    }
                }
            }
        }
        // Недокачанный файл играет TorrServer — по сети, как обычно.
        .accessibilityLabel(file.name)
    }
}
