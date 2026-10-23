import Foundation
import Testing
@testable import Aerial

/// Разбор раздач, файлов, адресов и ответов TMDb — на тех же примерах, что у ТВ.
struct ReleaseInfoTests {
    private func info(_ title: String, height: Int = 0, hdr: Bool = false) -> ReleaseInfo {
        Release(title: title, link: "magnet:?xt=urn:btih:\(String(repeating: "a", count: 40))", tracker: "t",
                bytes: 0, seeds: 0, height: height, hdr: hdr).info
    }

    @Test func quality() {
        #expect(info("Dune.Part.Two.2024.2160p.WEB-DL.HDR10+.DV.HEVC").quality == "4K")
        #expect(info("Фильм (2023) WEB-DLRip 1080p").quality == "1080p")
        #expect(info("Film 1920x800 BDRip").quality == "1080p")
        #expect(info("Сериал 720p HDTV").quality == "720p")
        #expect(info("Old Movie DVDRip").quality == "SD")
        #expect(info("Без качества", height: 2160).quality == "4K")
    }

    @Test func rangeAndCodec() {
        let full = info("Dune.Part.Two.2024.2160p.WEB-DL.HDR10+.DV.HEVC")
        #expect(full.range == "HDR10+")
        #expect(full.dolbyVision)
        #expect(full.codec == "HEVC")
        #expect(full.source == "WEB-DL")
        #expect(info("Film 1080p x264 BDRemux").source == "Remux")
        #expect(info("Film 1080p WEB-DLRip").source == "WEB-DLRip")
    }

    @Test func season() {
        #expect(ReleaseInfo.season("Show S01E01-E06 1080p") == "Сезон 1 · 6 серий")
        #expect(ReleaseInfo.season("Сериал / Сезон: 1 / Серии: 1-8 из 8") == "Сезон 1 · 8 серий")
        #expect(ReleaseInfo.season("Сериал (2 сезон: 1-8 из 8)") == "Сезон 2 · 8 серий")
        #expect(ReleaseInfo.season("Show S01-S03 Complete") == "Сезоны 1–3")
        #expect(ReleaseInfo.season("Show S02E05 720p") == "Сезон 2 · серия 5")
        #expect(ReleaseInfo.season("Фильм 2024 1080p") == nil)
    }

    @Test func voices() {
        let release = Release(title: "Сериал LostFilm HDRezka RUS", link: "x", tracker: "t", bytes: 0, seeds: 0, voices: ["LostFilm"])
        #expect(release.info.audio == ["LostFilm", "HDRezka", "RUS"])
    }
}

struct EpisodeMatchTests {
    @Test func coordinates() {
        #expect(EpisodeMatch.coordinates("Show/Season 1/Show.S01E03.1080p.mkv").map { [$0.season, $0.episode] } == [1, 3])
        #expect(EpisodeMatch.coordinates("show.2x07.mkv").map { [$0.season, $0.episode] } == [2, 7])
        #expect(EpisodeMatch.coordinates("Сезон 3/Серия 12.mkv").map { [$0.season, $0.episode] } == [3, 12])
        #expect(EpisodeMatch.coordinates("Movie.2024.1080p.mkv") == nil)
    }

    @Test func pick() {
        let files = [
            TorrentFile(index: 1, path: "Show.S01E01.mkv", bytes: 900),
            TorrentFile(index: 2, path: "Show.S01E02.mkv", bytes: 950),
        ]
        let episode = VodEpisode(season: 1, number: 2, title: "")
        #expect(EpisodeMatch.pick(files, episode: episode)?.index == 2)
        // Фильм: самый большой файл, только если он заметно больше остальных (остальное — допматериалы).
        let movie = [TorrentFile(index: 1, path: "Movie.mkv", bytes: 8_000), TorrentFile(index: 2, path: "Sample.mkv", bytes: 100)]
        #expect(EpisodeMatch.pick(movie, episode: nil)?.index == 1)
        #expect(EpisodeMatch.pick(files, episode: nil) == nil)
    }
}

struct TorrServerTests {
    @Test func normalize() {
        #expect(TorrServerClient.normalize("192.168.1.10:8090")?.absoluteString == "http://192.168.1.10:8090/")
        #expect(TorrServerClient.normalize("https://ts.example.com/base")?.absoluteString == "https://ts.example.com/base/")
        #expect(TorrServerClient.normalize("user:pass@host") == nil)
        #expect(TorrServerClient.normalize("host?x=1") == nil)
        #expect(TorrServerClient.normalize("") == nil)
    }

    @Test func links() {
        let hash = String(repeating: "ab", count: 20)
        #expect(TorrServerClient.validLink("magnet:?xt=urn:btih:\(hash)&dn=x"))
        #expect(!TorrServerClient.validLink("magnet:?xt=urn:btih:zzz"))
        #expect(TorrServerClient.validLink("https://example.com/file.torrent"))
        #expect(TorrServerClient.infoHash("magnet:?xt=urn:btih:\(hash.uppercased())&dn=x") == hash)
    }

    @Test func parse() throws {
        let row: [String: Any] = [
            "hash": String(repeating: "C", count: 40), "title": "Фильм", "active_peers": 12, "download_speed": 1_500_000.5,
            "file_stats": [
                ["id": 1, "path": "Film/Film.mkv", "length": 4_000_000_000],
                ["id": 2, "path": "Film/Film.srt", "length": 50_000],
            ],
        ]
        let info = try TorrServerClient.parse(row)
        #expect(info.hash == String(repeating: "c", count: 40))
        #expect(info.files.map(\.index) == [1])
        #expect(info.files.first?.name == "Film.mkv")
        #expect(info.peers == 12)
        #expect(info.metadataReady)
    }

    @Test func streamURL() throws {
        let client = try TorrServerClient(address: "127.0.0.1:18090")
        let url = client.streamURL(hash: "abc", file: TorrentFile(index: 3, path: "Dir/Мой фильм.mkv", bytes: 1))
        #expect(url.absoluteString.hasPrefix("http://127.0.0.1:18090/stream/"))
        #expect(url.absoluteString.contains("link=abc"))
        #expect(url.absoluteString.contains("index=3"))
        #expect(url.absoluteString.hasSuffix("&play"))
    }

    @Test func bitrate() {
        // Двухчасовой фильм на 10 ГБ: ~1.6 МБ/с с запасом 15 %.
        let bitrate = TorrServerClient.estimatedBitrate(fileBytes: 10_000_000_000, duration: 7200)
        #expect(bitrate > 1_500_000 && bitrate < 1_700_000)
        #expect(TorrServerClient.earlyStartBytes(100_000) == 8 << 20)
    }
}

struct CatalogueTests {
    @Test func titleParsing() throws {
        let json = """
        {"page":1,"total_pages":3,"results":[
          {"id":603,"title":"Матрица","original_title":"The Matrix","release_date":"1999-03-30","poster_path":"/p.jpg",
           "backdrop_path":"/b.jpg","vote_average":8.2,"vote_count":26000,"genre_ids":[28,878],"overview":"…"},
          {"id":1,"title":"Взрослое","adult":true},
          {"id":2,"name":"Без вида","media_type":"person"}
        ]}
        """
        let page = try TMDb.decoder.decode(TMDbPage.self, from: Data(json.utf8))
        #expect(page.totalPages == 3)
        // Взрослое отсеивается, у «персоны» нет названия фильма.
        let items = page.results.compactMap { $0.item(kind: .movie, genres: [28: "боевик", 878: "фантастика"]) }
        #expect(items.count == 1)
        #expect(items[0].id == "tmdb:movie:603")
        #expect(items[0].genres == ["боевик", "фантастика"])
        #expect(items[0].year == "1999")
        #expect(page.results[2].item(kind: nil, genres: [:]) == nil)
    }

    @Test func shelves() {
        let cartoon = VodItem(id: "a", remoteId: 1, kind: .movie, title: "Мульт", genreIds: [16])
        let film = VodItem(id: "b", remoteId: 2, kind: .movie, title: "Фильм", genreIds: [28])
        let series = VodItem(id: "c", remoteId: 3, kind: .series, title: "Сериал", genreIds: [18])
        #expect(VodShelf.movies.accepts(film) && !VodShelf.movies.accepts(cartoon))
        #expect(VodShelf.cartoons.accepts(cartoon) && !VodShelf.cartoons.accepts(film))
        #expect(VodShelf.series.accepts(series) && !VodShelf.cartoonSeries.accepts(series))
    }

    @Test func certification() throws {
        let json = """
        {"id":1,"release_dates":{"results":[
          {"iso_3166_1":"US","release_dates":[{"certification":"PG-13"}]},
          {"iso_3166_1":"RU","release_dates":[{"certification":""},{"certification":"16"}]}
        ]}}
        """
        let body = try TMDb.decoder.decode(TMDbDetails.self, from: Data(json.utf8))
        #expect(Catalogue.certification(body, kind: .movie) == "16+")
    }

    @Test func relevance() {
        #expect(SearchText.relevance("матрица", title: "Матрица") == 100)
        #expect(SearchText.relevance("ёлки", title: "Елки 2") == 80)
        #expect(SearchText.relevance("war star", title: "Star Wars") == 60)
        #expect(SearchText.normalized("Ёлки-2: Возвращение!") == "елки 2 возвращение")
    }
}

struct LibraryTests {
    @Test func resumable() {
        let item = VodItem(id: "x", remoteId: 1, kind: .movie, title: "x")
        func entry(_ position: Double, _ duration: Double) -> WatchEntry {
            WatchEntry(key: "x", item: item, position: position, duration: duration, updated: .now)
        }
        #expect(!entry(3, 6000).resumable)
        #expect(entry(600, 6000).resumable)
        #expect(!entry(5900, 6000).resumable)
        #expect(!entry(5995, 6000).resumable)
    }
}
