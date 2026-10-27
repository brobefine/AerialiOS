import Foundation

/// Автовыбор раздачи — перенос `autoOpen`/`autoScore` ТВ (27 октября): поиск, оценка по предпочтениям из настроек
/// (качество, озвучка), затем три лучшие раздачи открываются разом — берётся первая, что отдала список файлов.
/// На открытие — не больше 20 с: по одной с ожиданием каждой выходили минуты на одной надписи.
@MainActor
enum AutoPick {
    enum Quality: String, CaseIterable, Identifiable {
        case best, fullHD = "1080", light
        var id: String { rawValue }
        var title: String {
            switch self {
            case .best: L("Лучшее")
            case .fullHD: "1080p"
            case .light: L("Экономно")
            }
        }
    }

    enum Failure: LocalizedError {
        case nothing, silent
        var errorDescription: String? {
            switch self {
            case .nothing: L("Не нашлось раздачи с раздающими.")
            case .silent: L("Раздачи не ответили за 20 секунд. Попробуйте ещё раз или выберите раздачу вручную в настройках.")
            }
        }
    }

    /// Раздача и её файлы; у сериала — с сезоном [episode].
    static func pick(item: VodItem, episode: VodEpisode?, settings: AppSettings) async throws -> (Release, TorrentInfo) {
        let imdb = await Catalogue.shared.imdbId(item)
        let parser = ReleaseSearch.Parser(address: settings.parserAddress, key: settings.parserKey, torrentio: settings.torrentio)
        let found = await ReleaseSearch.search(item: item, episode: episode, imdbId: imdb, parser: parser)
        let quality = Quality(rawValue: settings.releaseQuality) ?? .fullHD
        let voice = settings.releaseVoice
        let year = String(item.year.prefix(4))
        let ranked = await Task.detached(priority: .userInitiated) {
            found.filter { release in
                guard release.seeds > 0 else { return false }
                let info = release.info
                if let episode { return info.seasons.map { $0.contains(episode.season) } ?? true }
                return info.seasons == nil
            }
            .map { ($0, score($0, quality: quality, voice: voice, year: year)) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        }.value
        let tries = Array(ranked.prefix(3))
        guard !tries.isEmpty else {
            Log.note("АВТОВЫБОР", "\(item.title): раздач \(found.count), с сидами и сезоном — нет")
            throw Failure.nothing
        }
        let client = try await Torrents.client(settings)
        let poster = TMDbImage.urls(item.poster, "w342").first?.absoluteString ?? ""
        let title = item.title
        enum Outcome: Sendable { case hit(Release, TorrentInfo), miss, timeout }
        let winner = await withTaskGroup(of: Outcome.self) { group -> (Release, TorrentInfo)? in
            for release in tries {
                group.addTask {
                    let started = Date()
                    do {
                        let added = try await client.add(link: release.link, title: title, poster: poster)
                        let info = try await client.awaitFiles(added)
                        return info.files.isEmpty ? .miss : .hit(release, info)
                    } catch {
                        Log.note("АВТОВЫБОР", "через \(Int(Date().timeIntervalSince(started))) с: \(error.localizedDescription) — \(release.title.prefix(60))")
                        return .miss
                    }
                }
            }
            // Срок — отдельной задачей: вышел — остальные отменяются.
            group.addTask {
                try? await Task.sleep(for: .seconds(20))
                return .timeout
            }
            var misses = 0
            while let next = await group.next() {
                switch next {
                case .hit(let release, let info): group.cancelAll(); return (release, info)
                case .timeout: group.cancelAll(); return nil
                case .miss:
                    misses += 1
                    if misses == tries.count { group.cancelAll(); return nil }
                }
            }
            return nil
        }
        guard let winner else {
            Log.note("АВТОВЫБОР", "\(item.title): ни одна из \(tries.count) не ответила за 20 с")
            throw Failure.silent
        }
        Log.note("АВТОВЫБОР", "\(item.title): \(winner.0.seeds) сид., \(winner.1.files.count) файлов — \(winner.0.title.prefix(80))")
        return winner
    }

    /// Оценка раздачи: качество по предпочтению, сиды (логарифмом), озвучка или оригинал, год в названии. Как `autoScore` ТВ.
    nonisolated static func score(_ release: Release, quality: Quality, voice: Bool, year: String) -> Double {
        let info = release.info
        var q: Double
        switch quality {
        case .best:
            q = ["4K": 4.0, "1080p": 3.0, "720p": 1.5][info.quality ?? ""] ?? 0.5
            if let range = info.range, range != "SDR" { q += 0.4 }
        case .fullHD:
            q = ["1080p": 3.0, "4K": 2.2, "720p": 1.5][info.quality ?? ""] ?? 0.5
            if info.source == "Remux" { q -= 0.8 }
        case .light:
            q = ["720p": 3.0, "1080p": 2.6, "4K": 0.5][info.quality ?? ""] ?? 1.0
            let gb = Double(release.bytes) / 1_073_741_824
            q -= max(0, gb - 6) * 0.1
        }
        let dubbed = !release.voices.isEmpty || info.audio.contains { ["DUB", "MVO", "RUS"].contains($0.uppercased()) }
        let sound = voice ? (dubbed ? 0.8 : 0) : ((!dubbed || info.audio.contains { $0.uppercased() == "ENG" }) ? 0.6 : 0) + (info.subtitles ? 0.2 : 0)
        return q + sound + log(1 + Double(release.seeds)) * 1.2 + (!year.isEmpty && release.title.contains(year) ? 0.3 : 0)
    }
}
