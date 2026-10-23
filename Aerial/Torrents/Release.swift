import Foundation

/// Раздача из поиска. [height] — разрешение от самого парсера (класс качества JacRed или кадр ffprobe), 0 — неизвестно.
struct Release: Hashable, Identifiable, Sendable {
    var title: String
    var link: String
    var tracker: String
    var bytes: Int64
    var seeds: Int
    var leechers: Int? = nil
    var published: String = ""
    var height: Int = 0
    var hdr: Bool = false
    var voices: [String] = []

    var id: String { link }
    /// Одна раздача из разных источников (JacRed и Torrentio) — один хэш.
    var hash: String? { TorrServerClient.infoHash(link) }
    var info: ReleaseInfo { ReleaseInfo(self) }
}

/// Разбор названия раздачи — перенос `ReleaseInfo.kt` ТВ: качество, HDR и Dolby Vision, кодек, источник, сезон и серии, озвучки.
struct ReleaseInfo: Hashable, Sendable {
    var quality: String?
    var range: String?
    var dolbyVision: Bool
    var codec: String?
    var source: String?
    var season: String?
    var audio: [String]
    var subtitles: Bool

    /// Плашки карточки раздачи по порядку.
    var tags: [String] {
        [quality, range, dolbyVision ? "Dolby Vision" : nil, codec, source].compactMap { $0 }
    }

    private static let res4k = Rx("(?i)\\b(2160p|4k|uhd)\\b|3840\\s*[x×]\\s*2160")
    private static let res1080 = Rx("(?i)(?<!\\d)1080[pi]?(?!\\d)|1920\\s*[x×]\\s*\\d{3,4}|\\bfull\\s*hd\\b|\\bfhd\\b")
    private static let res720 = Rx("(?i)(?<!\\d)720p?(?!\\d)|1280\\s*[x×]\\s*\\d{3}")
    private static let resSd = Rx("(?i)(?<!\\d)(480|576)[pi]?(?!\\d)|\\b(DVDRip|DVD5|DVD9|SATRip|TVRip|VHSRip|CAMRip|HDRip|WEB-?DLRip)\\b")
    private static let hdrTitle = Rx("(?i)\\bHDR(10\\+?)?\\b")
    private static let hdr10Plus = Rx("(?i)HDR10\\+")
    private static let hdr10 = Rx("(?i)HDR10")
    private static let sdrWord = Rx("(?i)\\bSDR\\b")
    private static let dvTitle = Rx("(?i)Dolby[ .]Vision|\\bDV\\b")
    private static let hevcTitle = Rx("(?i)H[ .-]?265|HEVC|x265")
    private static let avcTitle = Rx("(?i)H[ .-]?264|AVC|x264")
    private static let subtitleWords = Rx("(?iu)\\b(?:subs?|subtitles?)\\b|субтитры")
    private static let audioNames = Rx("(?i)\\b(?:LostFilm|HDRezka|Red Head Sound|TVShows|LE-Production|NewStudio|AlexFilm|BaibaKo|ColdFilm|Jaskier|Videofilm|DVO|MVO|AVO|VO|DUB|RUS|ENG)\\b")
    private static let seasonCode = Rx("(?i)\\bS(\\d{1,2})(?:[ ._-]?E(\\d{1,3})(?:[-–](?:E)?(\\d{1,3}))?)?")
    private static let seasonWords = Rx("(?iu)(?:сезон(?:ы|а)?|season)\\s*[:.]?\\s*(\\d{1,2})(?:[\\s,/|]*(?:серии|серия|episodes?)\\s*[:.]?\\s*(\\d{1,3}(?:\\s*[-–]\\s*\\d{1,3})?))?")
    private static let seasonBefore = Rx("(?iu)(\\d{1,2})\\s*(?:-?(?:й|ый))?\\s*сезон")
    private static let seasonRange = Rx("(?iu)\\bS(\\d{1,2})\\s*[-–]\\s*S?(\\d{1,2})\\b(?!\\s*[EЕ]\\d)|сезон(?:ы|ов)?\\s*[:.]?\\s*(\\d{1,2})\\s*[-–]\\s*(\\d{1,2})\\b(?!\\s*(?:сери|из))|(?<![\\d-])(\\d{1,2})\\s*[-–]\\s*(\\d{1,2})\\s*сезон")
    private static let episodeRange = Rx("(?iu)(?<![\\d.])(\\d{1,3})\\s*[-–]\\s*(\\d{1,3})(?=\\s*(?:сери[йия]|эп|из\\s*\\d))")
    // Порядок важен: «WEB-DLRip» раньше «WEB-DL», «BDRemux» раньше «BDRip».
    private static let sources: [(Rx, String)] = [
        (Rx("(?i)\\b(?:BD|BluRay|Blu-Ray)[ .-]?Remux\\b|\\bRemux\\b"), "Remux"),
        (Rx("(?i)\\bWEB[ .-]?DLRip\\b"), "WEB-DLRip"),
        (Rx("(?i)\\bWEB[ .-]?DL\\b"), "WEB-DL"),
        (Rx("(?i)\\bWEB[ .-]?Rip\\b"), "WEBRip"),
        (Rx("(?i)\\b(?:BDRip|BRRip|BluRay|Blu-Ray)\\b"), "BDRip"),
        (Rx("(?i)\\bHDTV(?:Rip)?\\b"), "HDTV"),
        (Rx("(?i)\\bHDRip\\b"), "HDRip"),
        (Rx("(?i)\\bDVD(?:Rip|5|9)?\\b"), "DVD"),
        (Rx("(?i)\\b(?:SAT|TV)Rip\\b"), "TVRip"),
        (Rx("(?i)\\b(?:CAMRip|TeleSync)\\b"), "CAM"),
    ]

    static func quality(height: Int) -> String? {
        switch height {
        case 1800...: "4K"
        case 900...: "1080p"
        case 650...: "720p"
        case 1...: "SD"
        default: nil
        }
    }

    init(_ release: Release) {
        let title = release.title
        let fromTitle: String? = Self.res4k.matches(title) ? "4K" : Self.res1080.matches(title) ? "1080p"
            : Self.res720.matches(title) ? "720p" : Self.resSd.matches(title) ? "SD" : nil
        quality = Self.quality(height: release.height) ?? fromTitle
        let hdr = release.hdr || Self.hdrTitle.matches(title)
        // HDR и Dolby Vision — разные вещи (диапазон и формат метаданных): отдельными плашками.
        range = hdr ? (Self.hdr10Plus.matches(title) ? "HDR10+" : Self.hdr10.matches(title) ? "HDR10" : "HDR")
            : Self.sdrWord.matches(title) ? "SDR" : nil
        dolbyVision = Self.dvTitle.matches(title)
        codec = Self.hevcTitle.matches(title) ? "HEVC" : Self.avcTitle.matches(title) ? "AVC" : nil
        source = Self.sources.first { $0.0.matches(title) }?.1
        subtitles = Self.subtitleWords.matches(title)
        var seen = Set<String>()
        audio = (release.voices + Self.audioNames.all(title)).filter { seen.insert($0.lowercased()).inserted }
        season = Self.season(title)
    }

    /// Сезон и серии одной плашкой: «Сезоны 1–3», «Сезон 1 · 8 серий», «Сезон 2 · серия 5», «Сезон 3».
    static func season(_ title: String) -> String? {
        if let span = seasonRange.groups(title)?.dropFirst().filter({ !$0.isEmpty }).compactMap({ Int($0) }),
           span.count == 2, span[1] > span[0] {
            return "Сезоны \(span[0])–\(span[1])"
        }
        let code = seasonCode.groups(title)
        let words = seasonWords.groups(title)
        // «2 сезон: 1-8» — число перед словом «сезон» главнее числа после него (там уже серии).
        var number = code?[1]
        if number == nil, let before = seasonBefore.groups(title),
           words == nil || (seasonBefore.location(title) ?? 0) < (seasonWords.location(title) ?? Int.max) {
            number = before[1]
        }
        if number == nil { number = words?[1] }
        guard let number, let season = Int(number) else { return nil }
        var episodes: (String, String)?
        if let code, !code[2].isEmpty {
            episodes = (code[2], code[3])
        } else if let words, !words[2].isEmpty {
            let parts = words[2].components(separatedBy: CharacterSet(charactersIn: "-–")).map { $0.trimmingCharacters(in: .whitespaces) }
            episodes = (parts[0], parts.count > 1 ? parts[1] : "")
        } else if let range = episodeRange.groups(title) {
            episodes = (range[1], range[2])
        }
        let head = "Сезон \(season)"
        guard let episodes, let from = Int(episodes.0) else { return head }
        guard let to = Int(episodes.1), to > from else { return "\(head) · серия \(from)" }
        let count = to - from + 1
        return "\(head) · \(count) \(Format.plural(count, "серия", "серии", "серий"))"
    }
}

/// Сезон и серия файла раздачи — только по явным координатам, как `torrentEpisodeCoordinates` ТВ.
enum EpisodeMatch {
    private static let patterns = [
        Rx("(?i)(?:^|[^a-z0-9])s(\\d{1,3})[ ._-]*e(\\d{1,3})(?!\\d)"),
        Rx("(?i)(?:^|[^0-9])(\\d{1,2})x(\\d{1,3})(?!\\d)"),
        Rx("(?iu)сезон[ ._-]*(\\d{1,3}).*?сери[яи][ ._-]*(\\d{1,3})(?!\\d)"),
    ]

    static func coordinates(_ path: String) -> (season: Int, episode: Int)? {
        for pattern in patterns {
            if let groups = pattern.groups(path), let season = Int(groups[1]), let episode = Int(groups[2]), episode > 0 {
                return (season, episode)
            }
        }
        return nil
    }

    /// Файл для просмотра: единственный видеофайл; для серии — файл с её сезоном и номером; для фильма — самый большой,
    /// если он заметно больше остальных (остальное — допматериалы). Иначе nil — выбирает зритель.
    static func pick(_ files: [TorrentFile], episode: VodEpisode?) -> TorrentFile? {
        if files.count == 1 { return files[0] }
        if let episode {
            return files.first { file in
                guard let found = coordinates(file.path) else { return false }
                return found.season == episode.season && found.episode == episode.number
            }
        }
        let sorted = files.sorted { $0.bytes > $1.bytes }
        guard sorted.count >= 2 else { return sorted.first }
        return sorted[0].bytes > sorted[1].bytes * 3 ? sorted[0] : nil
    }
}
