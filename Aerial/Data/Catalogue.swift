import Foundation

/// Каталог кинотеки поверх TMDb — перенос `VodTmdbClient` ТВ: ряды, страница фильма, сезоны, поиск, актёры.
final class Catalogue: Sendable {
    static let shared = Catalogue()

    private let genres = GenreStore()
    private var tmdb: TMDb { .shared }

    // MARK: Ряды

    /// Ряды раздела. Набор и названия — как `sections()` ТВ; «В тренде сегодня» — с номерами топ-10.
    static func sections(for shelf: VodShelf) -> [CinemaSection] {
        let tomorrow = ISO8601DateFormatter.day.string(from: .now.addingTimeInterval(24 * 3600))
        let trending = CinemaSection(id: "trending", title: L("В тренде сегодня"), path: "trending/movie/day", kind: .movie, ranked: true)
        let trendingWeek = CinemaSection(id: "trending-week", title: L("В тренде за неделю"), path: "trending/movie/week", kind: .movie)
        let popular = CinemaSection(id: "popular", title: L("Популярное"), path: "movie/popular", kind: .movie)
        let new = CinemaSection(id: "new", title: L("Сейчас в кино"), path: "movie/now_playing", kind: .movie)
        let soon = CinemaSection(id: "soon", title: L("Скоро в кино"), path: "discover/movie", kind: .movie,
                                 params: ["primary_release_date.gte": tomorrow, "sort_by": "popularity.desc"])
        let top = CinemaSection(id: "top", title: L("Высокие оценки"), path: "movie/top_rated", kind: .movie)
        let seriesTrending = CinemaSection(id: "series-trending", title: L("Сериалы в тренде сегодня"), path: "trending/tv/day", kind: .series)
        let series = CinemaSection(id: "series", title: L("Популярные сериалы"), path: "tv/popular", kind: .series)
        let seriesToday = CinemaSection(id: "series-today", title: L("Новые серии сегодня"), path: "tv/airing_today", kind: .series)
        let onAir = CinemaSection(id: "air", title: L("Сериалы в эфире"), path: "tv/on_the_air", kind: .series)
        let seriesTop = CinemaSection(id: "series-top", title: L("Лучшие сериалы"), path: "tv/top_rated", kind: .series)
        let seriesSoon = CinemaSection(id: "series-soon", title: L("Скоро премьера"), path: "discover/tv", kind: .series,
                                       params: ["first_air_date.gte": tomorrow, "sort_by": "popularity.desc"])
        let cartoons = CinemaSection(id: "cartoons", title: L("Популярные мультфильмы"), path: "discover/movie", kind: .movie,
                                     params: ["with_genres": "16", "sort_by": "popularity.desc"])
        let cartoonsNew = CinemaSection(id: "cartoons-new", title: L("Новые мультфильмы"), path: "discover/movie", kind: .movie,
                                        params: ["with_genres": "16", "sort_by": "primary_release_date.desc", "vote_count.gte": "30"])
        let cartoonSeries = CinemaSection(id: "cartoon-series", title: L("Популярные мультсериалы"), path: "discover/tv", kind: .series,
                                          params: ["with_genres": "16", "sort_by": "popularity.desc"])
        let cartoonSeriesNew = CinemaSection(id: "cartoon-series-new", title: L("Новые мультсериалы"), path: "discover/tv", kind: .series,
                                             params: ["with_genres": "16", "sort_by": "first_air_date.desc", "vote_count.gte": "30"])
        let cartoonSeriesTop = CinemaSection(id: "cartoon-series-top", title: L("Лучшие мультсериалы"), path: "discover/tv", kind: .series,
                                             params: ["with_genres": "16", "sort_by": "vote_average.desc", "vote_count.gte": "300"])
        switch shelf {
        case .all: return [trending, seriesTrending, new, popular, series, top, seriesTop, soon, cartoons]
        case .movies: return [trending, popular, new, trendingWeek, top, soon]
        case .series:
            var ranked = seriesTrending
            ranked.ranked = true
            return [ranked, series, seriesToday, onAir, seriesTop, seriesSoon]
        case .cartoons: return [cartoons, cartoonsNew]
        case .cartoonSeries: return [cartoonSeries, cartoonSeriesNew, cartoonSeriesTop]
        }
    }

    /// Одна страница ряда и число страниц. Тренды и подборки меняются за часы — срок 6 ч.
    func section(_ section: CinemaSection, page: Int = 1) async throws -> (items: [VodItem], pages: Int) {
        let body = try await tmdb.decode(TMDbPage.self, section.path, section.params.merging(["page": String(page)]) { $1 },
                                         ttl: 6 * DiskCache.hour)
        return (try await items(body.results, kind: section.kind), body.totalPages ?? 1)
    }

    private func items(_ rows: [TMDbTitle], kind: VodKind?) async throws -> [VodItem] {
        let names = await genres.names()
        var seen = Set<String>()
        return rows.compactMap { $0.item(kind: kind, genres: names) }.filter { seen.insert($0.id).inserted }
    }

    // MARK: Страница фильма

    func details(_ item: VodItem) async throws -> VodDetails {
        let type = item.tmdbType
        let extra = item.kind == .movie ? "release_dates" : "content_ratings"
        let body = try await tmdb.decode(TMDbDetails.self, "\(type)/\(item.remoteId)", [
            "append_to_response": "credits,recommendations,images,videos,external_ids,\(extra)",
            "include_image_language": "ru,en,null",
            "include_video_language": "ru,en",
        ], ttl: 12 * DiskCache.hour)
        let names = await genres.names()
        var fresh = item
        fresh.title = (item.kind == .movie ? body.title : body.name) ?? item.title
        fresh.originalTitle = (item.kind == .movie ? body.originalTitle : body.originalName) ?? item.originalTitle
        fresh.overview = body.overview.flatMap { $0.isEmpty ? nil : $0 } ?? item.overview
        fresh.poster = body.posterPath ?? item.poster
        fresh.backdrop = body.backdropPath ?? item.backdrop
        fresh.releaseDate = (item.kind == .movie ? body.releaseDate : body.firstAirDate) ?? item.releaseDate
        fresh.genres = body.genres?.compactMap(\.name) ?? item.genres
        fresh.genreIds = body.genres?.compactMap(\.id) ?? item.genreIds
        fresh.rating = body.voteAverage ?? item.rating
        fresh.votes = body.voteCount ?? item.votes

        var details = VodDetails(item: fresh)
        details.tagline = body.tagline ?? ""
        details.runtimeMinutes = item.kind == .movie ? (body.runtime ?? 0) : (body.episodeRunTime?.first ?? 0)
        details.certification = Self.certification(body, kind: item.kind)
        details.countries = Self.countries(body)
        details.logo = Self.logo(body.images?.logos ?? [])
        details.trailerKey = Self.trailer(body.videos?.results ?? [])
        details.imdbId = body.externalIds?.imdbId ?? ""
        details.cast = (body.credits?.cast ?? []).prefix(20).compactMap { person -> VodPerson? in
            guard let id = person.id, let name = person.name else { return nil }
            return VodPerson(id: id, name: name, role: person.character ?? "", photo: person.profilePath ?? "")
        }
        let creators = (body.createdBy ?? []).compactMap { person -> VodPerson? in
            guard let id = person.id, let name = person.name else { return nil }
            return VodPerson(id: id, name: name, role: L("Автор"), photo: person.profilePath ?? "")
        }
        let directors = (body.credits?.crew ?? []).filter { $0.job == "Director" }.compactMap { person -> VodPerson? in
            guard let id = person.id, let name = person.name else { return nil }
            return VodPerson(id: id, name: name, role: L("Режиссёр"), photo: person.profilePath ?? "")
        }
        var seenPeople = Set<Int>()
        details.directors = (creators + directors).filter { seenPeople.insert($0.id).inserted }
        details.related = (body.recommendations?.results ?? []).compactMap { $0.item(kind: item.kind, genres: names) }
        if item.kind == .series {
            details.seasons = (body.seasons ?? []).filter { ($0.episodeCount ?? 0) > 0 && ($0.seasonNumber ?? 0) > 0 }
                .compactMap(\.seasonNumber).sorted()
            details.status = switch body.status ?? "" {
            case "Returning Series": L("Продолжается")
            case "Ended": L("Завершён")
            case "Canceled", "Cancelled": L("Отменён")
            case "In Production": L("В производстве")
            case "Planned": L("Анонсирован")
            default: ""
            }
            if ["Ended", "Canceled", "Cancelled"].contains(body.status ?? "") {
                details.endYear = String((body.lastAirDate ?? "").prefix(4))
            }
        }
        if let collection = body.belongsToCollection?.id {
            // Франшиза необязательна: её сбой не мешает странице.
            if let parts = try? await tmdb.decode(TMDbCollection.self, "collection/\(collection)", ttl: 12 * DiskCache.hour),
               let rows = parts.parts {
                // Части по дате выхода; без даты (ещё не вышла) — в конец.
                func date(_ title: TMDbTitle) -> String { (title.releaseDate ?? "").isEmpty ? "9999" : title.releaseDate ?? "9999" }
                let films = rows.sorted { date($0) < date($1) }.compactMap { $0.item(kind: .movie, genres: names) }
                if films.count > 1 {
                    details.collectionTitle = parts.name ?? L("Франшиза")
                    details.collection = films
                }
            }
        }
        details.facts = Self.facts(body, kind: item.kind, countries: details.countries)
        details.studios = (body.productionCompanies ?? []).compactMap { company -> VodStudio? in
            guard let id = company.id, id > 0, let name = company.name, !name.isEmpty else { return nil }
            return VodStudio(id: id, name: name)
        }
        .prefix(4).map { $0 }
        // «Ещё от студии», как на ТВ: работы первой студии того же вида; сбой ряда не мешает странице.
        if let studio = details.studios.first {
            let films = (try? await section(studio.section(item.kind)).items) ?? []
            details.studioFilms = films.filter { $0.id != item.id }
        }
        return details
    }

    func season(_ item: VodItem, _ number: Int) async throws -> [VodEpisode] {
        let body = try await tmdb.decode(TMDbSeason.self, "tv/\(item.remoteId)/season/\(number)", ttl: DiskCache.day)
        return (body.episodes ?? []).compactMap { episode in
            guard let index = episode.episodeNumber, index > 0 else { return nil }
            return VodEpisode(season: episode.seasonNumber ?? number, number: index, title: episode.name ?? L("Серия %@", "\(index)"),
                              overview: episode.overview ?? "", still: episode.stillPath ?? "", airDate: episode.airDate ?? "",
                              runtimeMinutes: episode.runtime ?? 0)
        }
    }

    /// Рекомендации TMDb к работе — соседи для подбора «Вам понравится?» ([Taste]).
    func recommendations(_ item: VodItem) async throws -> [VodItem] {
        let body = try await tmdb.decode(TMDbPage.self, "\(item.tmdbType)/\(item.remoteId)/recommendations", ttl: 7 * DiskCache.day)
        return try await items(body.results, kind: item.kind)
    }

    /// Название от ИИ → работа TMDb. Строго: название (русское или оригинальное) совпадает целиком, год — с точностью до
    /// года; иначе nil (ИИ назвал «The Box» про запертых людей — первый результат поиска был бы корейской мелодрамой).
    func resolve(_ title: AiTitle) async -> VodItem? {
        let kind: VodKind = title.tv ? .series : .movie
        let type = title.tv ? "tv" : "movie"
        let yearKey = title.tv ? "first_air_date_year" : "primary_release_year"
        let wanted = Set([title.title, title.original].map(SearchText.normalized).filter { !$0.isEmpty })
        let names = await genres.names()
        var tried = Set<String>()
        for (query, year) in [(title.original, title.year), (title.title, title.year), (title.original, 0)] {
            guard !query.isEmpty, tried.insert("\(query)|\(year)").inserted else { continue }
            var params = ["query": query]
            if year > 0 { params[yearKey] = String(year) }
            guard let page = try? await tmdb.decode(TMDbPage.self, "search/\(type)", params, ttl: 7 * DiskCache.day) else { continue }
            for row in page.results {
                let candidates = [row.title, row.name, row.originalTitle, row.originalName].compactMap { $0 }.map(SearchText.normalized)
                guard candidates.contains(where: wanted.contains) else { continue }
                let found = Int(((title.tv ? row.firstAirDate : row.releaseDate) ?? "").prefix(4)) ?? 0
                if title.year > 0 && found > 0 && abs(found - title.year) > 1 { continue }
                if let item = row.item(kind: kind, genres: names) { return item }
            }
        }
        return nil
    }

    /// Отзывы TMDb: русские и английские вместе (русских почти нет), без повторов.
    func reviews(_ item: VodItem) async -> [VodReview] {
        struct Author: Decodable { var rating: Double? }
        struct Row: Decodable { var author: String?; var authorDetails: Author?; var content: String?; var createdAt: String? }
        struct Page: Decodable { var results: [Row]? }
        let path = "\(item.tmdbType)/\(item.remoteId)/reviews"
        async let local = tmdb.decode(Page.self, path, ttl: DiskCache.day)
        async let english = tmdb.decode(Page.self, path, ["language": "en-US"], ttl: DiskCache.day)
        var seen = Set<String>()
        let rows = ((try? await local)?.results ?? []) + ((try? await english)?.results ?? [])
        return rows
            .compactMap { row -> VodReview? in
                let text = (row.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return VodReview(author: row.author ?? "TMDb", rating: row.authorDetails?.rating ?? 0, text: text,
                                 date: String((row.createdAt ?? "").prefix(10)))
            }
            .filter { seen.insert("\($0.author)|\($0.date)").inserted }
    }

    /// Фильмы, вышедшие в онлайн или на диске за последние [days] дней (ряд «Вышли в 4K»), по популярности.
    func recentHomeReleases(days: Int = 120, pages: Int = 3) async -> [VodItem] {
        let today = ISO8601DateFormatter.day.string(from: .now)
        let from = ISO8601DateFormatter.day.string(from: .now.addingTimeInterval(-Double(days) * 86400))
        let params = ["with_release_type": "4|5", "release_date.gte": from, "release_date.lte": today,
                      "sort_by": "popularity.desc", "vote_count.gte": "80"]
        var all: [VodItem] = []
        for page in 1...pages {
            let section = CinemaSection(id: "home-\(page)", title: "", path: "discover/movie", kind: .movie, params: params)
            all += (try? await self.section(section, page: page).items) ?? []
        }
        var seen = Set<String>()
        return all.filter { seen.insert($0.id).inserted }
    }

    /// Следующая серия сериала — лёгкий запрос карточки без приложений (ряд «Скоро новые серии»).
    func upcoming(_ item: VodItem) async throws -> UpcomingEpisode? {
        struct Next: Decodable { var airDate: String?; var seasonNumber: Int?; var episodeNumber: Int?; var name: String?; var stillPath: String? }
        struct Body: Decodable { var nextEpisodeToAir: Next? }
        guard item.kind == .series else { return nil }
        let body = try await tmdb.decode(Body.self, "tv/\(item.remoteId)", ttl: 6 * DiskCache.hour)
        guard let next = body.nextEpisodeToAir, let date = next.airDate, date.count >= 10,
              let number = next.episodeNumber, number > 0 else { return nil }
        return UpcomingEpisode(item: item, date: date, season: next.seasonNumber ?? 0, number: number, title: next.name ?? "",
                               still: next.stillPath ?? "")
    }

    /// Номер IMDb — для Torrentio. Без языка: ответ один на все языки.
    func imdbId(_ item: VodItem) async -> String? {
        struct Ids: Decodable { var imdbId: String? }
        let ids = try? await tmdb.decode(Ids.self, "\(item.tmdbType)/\(item.remoteId)/external_ids", localize: false, ttl: 7 * DiskCache.day)
        return ids?.imdbId.flatMap { $0.hasPrefix("tt") ? $0 : nil }
    }

    /// Логотип-название для шапки: только русский, как у ТВ; нет — название текстом.
    func logo(_ item: VodItem) async -> String {
        let images = try? await tmdb.decode(TMDbDetails.Images.self, "\(item.tmdbType)/\(item.remoteId)/images", localize: false,
                                            ttl: 7 * DiskCache.day)
        return Self.logo(images?.logos ?? [])
    }

    // MARK: Поиск

    /// Фильмы и сериалы отдельными запросами (сериалы не тонут среди фильмов и людей); порядок — похожесть названия,
    /// затем популярность с учётом числа голосов, как у ТВ.
    func search(_ query: String) async throws -> [VodItem] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else { return [] }
        async let movies = tmdb.decode(TMDbPage.self, "search/movie", ["query": text], ttl: DiskCache.day)
        async let series = tmdb.decode(TMDbPage.self, "search/tv", ["query": text], ttl: DiskCache.day)
        let names = await genres.names()
        var scored: [(VodItem, Int, Double)] = []
        for (page, kind) in [(try? await movies, VodKind.movie), (try? await series, VodKind.series)] {
            for row in page?.results ?? [] {
                guard let item = row.item(kind: kind, genres: names) else { continue }
                let weight = (row.popularity ?? 0) * log(2 + Double(row.voteCount ?? 0))
                scored.append((item, SearchText.relevance(text, title: item.title, original: item.originalTitle), weight))
            }
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 > $1.2 }.map { $0.0 }
    }

    // MARK: Актёр

    func person(_ person: VodPerson) async throws -> VodPersonInfo {
        let body = try await tmdb.decode(TMDbPerson.self, "person/\(person.id)", ttl: 7 * DiskCache.day)
        var biography = body.biography ?? ""
        if biography.isEmpty {
            // Русской биографии у TMDb часто нет — тогда английская.
            biography = (try? await tmdb.decode(TMDbPerson.self, "person/\(person.id)", ["language": "en-US"], ttl: 7 * DiskCache.day))?.biography ?? ""
        }
        // Биография не по-русски — переводит ИИ, как на ТВ (`ReviewTranslator`); перевод кэшируется на месяц.
        if AI.enabled, !AppLanguage.english, !biography.isEmpty, !Self.cyrillic.matches(String(biography.prefix(300))),
           let russian = try? await AI.translate(biography, what: "biography of a film actor or director"), !russian.isEmpty {
            biography = russian
        }
        let credits = try await tmdb.decode(TMDbCredits.self, "person/\(person.id)/combined_credits", ttl: 7 * DiskCache.day)
        let directing = person.role == L("Режиссёр") || body.knownForDepartment == "Directing"
        let rows = directing ? (credits.crew ?? []).filter { $0.job == "Director" } : (credits.cast ?? [])
        let works = try await items(rows, kind: nil).sorted { $0.releaseDate > $1.releaseDate }
        return VodPersonInfo(id: person.id, name: body.name ?? person.name, photo: body.profilePath ?? person.photo,
                             department: body.knownForDepartment ?? "", birthday: body.birthday ?? "",
                             place: body.placeOfBirth ?? "", biography: biography.trimmingCharacters(in: .whitespacesAndNewlines),
                             works: works)
    }

    private static let cyrillic = Rx("[А-Яа-яЁё]")

    // MARK: Разбор

    /// Логотипы: только русский PNG, широкие раньше, затем по оценке и ширине (как `selectLogos` ТВ).
    static func logo(_ logos: [TMDbDetails.Image]) -> String {
        logos.filter { ($0.filePath ?? "").hasSuffix(".png") && $0.iso6391 == "ru" }
            .sorted { a, b in
                let wideA = Double(a.width ?? 0) > Double(a.height ?? 0) * 1.5
                let wideB = Double(b.width ?? 0) > Double(b.height ?? 0) * 1.5
                if wideA != wideB { return wideA }
                if (a.voteAverage ?? 0) != (b.voteAverage ?? 0) { return (a.voteAverage ?? 0) > (b.voteAverage ?? 0) }
                return (a.width ?? 0) > (b.width ?? 0)
            }
            .first?.filePath ?? ""
    }

    /// Трейлер YouTube: сперва русский, «Trailer» раньше «Teaser», официальный раньше прочих.
    static func trailer(_ videos: [TMDbDetails.Video]) -> String {
        videos.filter { $0.site == "YouTube" && ["Trailer", "Teaser"].contains($0.type ?? "") && !($0.key ?? "").isEmpty }
            .sorted { a, b in
                if (a.iso6391 == "ru") != (b.iso6391 == "ru") { return a.iso6391 == "ru" }
                if (a.type == "Trailer") != (b.type == "Trailer") { return a.type == "Trailer" }
                return (a.official ?? false) && !(b.official ?? false)
            }
            .first?.key ?? ""
    }

    /// Возрастной рейтинг: сначала Россия, затем США.
    static func certification(_ body: TMDbDetails, kind: VodKind) -> String {
        var byCountry: [String: String] = [:]
        if kind == .movie {
            for country in body.releaseDates?.results ?? [] {
                let value = (country.releaseDates ?? []).compactMap { $0.certification?.trimmingCharacters(in: .whitespaces) }
                    .first { !$0.isEmpty }
                if let code = country.iso31661, let value { byCountry[code] = value }
            }
        } else {
            for rating in body.contentRatings?.results ?? [] {
                if let code = rating.iso31661, let value = rating.rating?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
                    byCountry[code] = value
                }
            }
        }
        guard let value = byCountry["RU"] ?? byCountry["US"] else { return "" }
        return value.allSatisfy(\.isNumber) ? "\(value)+" : value
    }

    static func countries(_ body: TMDbDetails) -> [String] {
        var codes = (body.productionCountries ?? []).compactMap(\.iso31661)
        if codes.isEmpty { codes = body.originCountry ?? [] }
        let russian = Locale(identifier: "ru_RU")
        var seen = Set<String>()
        return codes.filter { $0.count == 2 && seen.insert($0).inserted }.prefix(3).map {
            russian.localizedString(forRegionCode: $0) ?? $0
        }
    }

    static func facts(_ body: TMDbDetails, kind: VodKind, countries: [String]) -> [VodFact] {
        var facts: [VodFact] = []
        func add(_ label: String, _ value: String?) {
            if let value, !value.isEmpty { facts.append(VodFact(label: label, value: value)) }
        }
        add(L("Оригинальное название"), kind == .movie ? body.originalTitle : body.originalName)
        add(L("Премьера"), (kind == .movie ? body.releaseDate : body.firstAirDate).map(Format.date))
        add(L("Страны"), countries.joined(separator: ", "))
        add(L("Студии"), (body.productionCompanies ?? []).compactMap(\.name).prefix(4).joined(separator: ", "))
        let money = NumberFormatter()
        money.numberStyle = .decimal
        money.groupingSeparator = " "
        if let budget = body.budget, budget > 0 { add(L("Бюджет"), "$" + (money.string(from: NSNumber(value: budget)) ?? "\(budget)")) }
        if let revenue = body.revenue, revenue > 0 { add(L("Сборы"), "$" + (money.string(from: NSNumber(value: revenue)) ?? "\(revenue)")) }
        if kind == .series {
            if let seasons = body.numberOfSeasons, seasons > 0 { add(L("Сезонов"), String(seasons)) }
            if let episodes = body.numberOfEpisodes, episodes > 0 { add(L("Серий"), String(episodes)) }
        }
        return facts
    }
}

/// Названия жанров TMDb (id → имя): справочник грузится один раз; сбой одного из двух не стирает известные имена.
actor GenreStore {
    private var cache: [Int: String] = [:]
    private var loading: Task<[Int: String], Never>?

    func names() async -> [Int: String] {
        if !cache.isEmpty { return cache }
        if let loading { return await loading.value }
        let task = Task<[Int: String], Never> {
            var all: [Int: String] = [:]
            for type in ["movie", "tv"] {
                if let list = try? await TMDb.shared.decode(TMDbGenres.self, "genre/\(type)/list", ttl: 7 * DiskCache.day) {
                    for genre in list.genres { if let id = genre.id, let name = genre.name { all[id] = name } }
                }
            }
            return all
        }
        loading = task
        let result = await task.value
        loading = nil
        cache.merge(result) { $1 }
        return cache
    }
}
