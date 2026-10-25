import SwiftUI

/// Вкладка «Настройки»: список разделов, как в «Настройках» iOS — поиск раздач, TorrServer (встроенный или внешний),
/// плеер и субтитры, подбор, каталог, ИИ, «Вместе», данные, о приложении; у каждого своя страница.
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Library.self) private var library

    @State private var probes: [String: Bool] = [:]
    @State private var externalCheck: String?
    @State private var cacheBytes = 0
    @State private var exporting = false
    @State private var importing = false
    @State private var backupFile = BackupFile(data: Data())
    @State private var backupNote: String?
    @Environment(Taste.self) private var taste

    private var server: EmbeddedTorrServer { .shared }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    category(L("Поиск раздач"), "magnifyingglass", .blue) { parserSection }
                    category("TorrServer", "server.rack", .green) { serverSection }
                    category(L("Плеер"), "play.rectangle.fill", .orange) { playerSection; subtitlesSection }
                }
                Section {
                    category(L("Вид"), "paintbrush.fill", .cyan) { appearanceSection }
                    category(L("Рекомендации"), "hand.thumbsup.fill", .pink) { tasteSection }
                    category(L("Каталог и оценки"), "film.stack", .indigo) { catalogueSection }
                    category(L("ИИ"), "sparkles", .purple) { aiSection }
                    if Friends.shared.enabled {
                        category(L("Вместе"), "person.2.fill", .teal) { friendsSection }
                    }
                }
                Section {
                    category(L("Данные"), "externaldrive.fill", .gray) { dataSection }
                    category(L("О приложении"), "info.circle.fill", .gray) { aboutSection }
                }
            }
            .navigationTitle(L("Настройки"))
            .fileExporter(isPresented: $exporting, document: backupFile, contentType: .propertyList, defaultFilename: Backup.fileName) { result in
                if case .success = result { backupNote = L("Копия сохранена.") }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.propertyList, .data]) { result in
                guard case .success(let url) = result else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    let count = try Backup.restore(Data(contentsOf: url))
                    library.reload()
                    backupNote = L("Восстановлено %@ значений. Настройки применятся полностью после перезапуска Aerial.", "\(count)")
                } catch {
                    backupNote = L("Это не копия Aerial для iPhone.")
                }
            }

            .task { await probe() }
            .task { cacheBytes = DiskCache.api.bytes }
        }
    }

    @ViewBuilder private var parserSection: some View {
        @Bindable var settings = settings
        Section {
            ForEach(AppSettings.parserCatalog) { entry in
                Button {
                    settings.parserAddress = entry.address
                    settings.parserKey = entry.key
                } label: {
                    HStack {
                        Text(entry.name).foregroundStyle(.white)
                        Spacer()
                        if let ok = probes[entry.address] {
                            Image(systemName: ok ? "circle.fill" : "xmark.circle")
                                .font(.aerial(.caption2))
                                .foregroundStyle(ok ? Color(hex: 0x3DDC84) : Color(hex: 0xFF5A4E))
                        }
                        if settings.parserAddress == entry.address {
                            Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
            TextField(L("Свой адрес (JacRed или Jackett)"), text: $settings.parserAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            SecureField(L("Ключ API (если нужен)"), text: $settings.parserKey)
            Toggle(L("Torrentio — зарубежные раздачи"), isOn: $settings.torrentio)
        } header: {
            Text(L("Поиск раздач"))
        } footer: {
            Text(L("Зелёная точка — сервер отвечает. Torrentio ищет по номеру IMDb, русских озвучек там мало."))
        }
    }

    @ViewBuilder private var serverSection: some View {
        @Bindable var settings = settings
        Section {
            Picker("TorrServer", selection: $settings.serverMode) {
                ForEach(AppSettings.ServerMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if settings.serverMode == .embedded {
                LabeledContent(L("Состояние"), value: embeddedState)
                Picker(L("Кэш в памяти"), selection: $settings.cacheMB) {
                    ForEach([128, 256, 512], id: \.self) { Text(L("%@ МБ", "\($0)")).tag($0) }
                }
                .onChange(of: settings.cacheMB) { _, value in
                    Task { await server.configure(cacheMB: value) }
                }
            } else {
                TextField(L("Адрес, например 192.168.1.10:8090"), text: $settings.externalAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button(L("Проверить")) { Task { await checkExternal() } }
                if let externalCheck { Text(externalCheck).font(.aerial(.footnote)).foregroundStyle(Theme.secondaryText) }
            }
        } header: {
            Text("TorrServer")
        } footer: {
            Text(settings.serverMode == .embedded
                 ? L("Встроенный работает, пока открыто приложение или идёт фильм. Раздача качается во время просмотра — по мобильной сети это трафик.")
                 : L("TorrServer на телевизоре или компьютере в той же сети."))
        }
    }

    @ViewBuilder private var playerSection: some View {
        @Bindable var settings = settings
        Section {
            Toggle(L("Описания серий"), isOn: $settings.episodeOverviews)
            Toggle(L("Скрывать спойлеры серий"), isOn: $settings.hideSpoilers)
        } header: {
            Text(L("Серии"))
        } footer: {
            Text(L("Спойлеры: у непросмотренных серий кадр размыт, а описание скрыто."))
        }
        Section {
            Button(L("Сбросить фильтры и сортировку раздач")) {
                UserDefaults.standard.removeObject(forKey: "releases.sort")
                UserDefaults.standard.removeObject(forKey: "releases.quality")
            }
            Button(L("Очистить историю поиска")) { UserDefaults.standard.removeObject(forKey: "search.recent") }
        }
        Section {
            Toggle(L("Следующая серия автоматически"), isOn: $settings.autoplayNext)
        } header: {
            Text(L("Плеер"))
        } footer: {
            Text(L("Серия кончилась — через 10 с начнётся следующая из той же раздачи. Заставку можно пропустить кнопкой, если её отметили зрители IntroDB или AniSkip. Скачанное (удерживайте раздачу — «Скачать») играет с телефона без сети и лежит в «Файлах» › Aerial › Downloads."))
        }
    }

    @AppStorage("ui.posterSize") private var posterSize = "large"
    @AppStorage("ui.actorPhoto") private var actorPhoto = "small"
    @AppStorage("ui.titleLogos") private var titleLogos = true

    @AppStorage(AppLanguage.key) private var language = "system"
    @State private var languageChanged = false

    @ViewBuilder private var appearanceSection: some View {
        // Язык приложения, как на ТВ; применяется при следующем запуске ([AppLanguage]).
        Section {
            Picker(L("Язык приложения"), selection: $language) {
                Text(L("Как в системе")).tag("system")
                Text("Русский").tag("ru")
                Text("English").tag("en")
            }
            .onChange(of: language) { languageChanged = true }
            .alert(L("Перезапустите Aerial"), isPresented: $languageChanged) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(L("Язык сменится после перезапуска: закройте Aerial в переключателе приложений и откройте снова."))
            }
        } footer: {
            Text(L("Каталог, даты и ответы ИИ — тоже на этом языке."))
        }
        Section {
            Picker(L("Размер постеров"), selection: $posterSize) {
                Text(L("Обычные")).tag("small")
                Text(L("Крупные")).tag("large")
            }
            Picker(L("Размер фото актёров"), selection: $actorPhoto) {
                Text(L("Обычные")).tag("small")
                Text(L("Крупные")).tag("large")
            }
            Toggle(L("Логотипы названий"), isOn: $titleLogos)
        } footer: {
            Text(L("Логотипы — название фильма надписью из TMDb вместо текста. Размеры применяются к открытым заново экранам."))
        }
    }

    @ViewBuilder private var tasteSection: some View {
        @Bindable var settings = settings
        Section {
            Toggle(L("Учитывать историю просмотра"), isOn: $settings.tasteHistory)
            LabeledContent(L("Оценок"), value: String(library.marks.count))
            Button(L("Очистить «Продолжить»"), role: .destructive) { library.clearContinue() }
                .disabled(library.continueWatching.isEmpty)
            Button(L("Очистить историю просмотра"), role: .destructive) { library.clearHistory() }
                .disabled(library.entries.isEmpty)
            Button(L("Начать рекомендации с нуля"), role: .destructive) {
                library.clearHistory()
                library.clearMarks()
                taste.clearAI()
            }
            Button(L("Сбросить оценки"), role: .destructive) {
                library.clearMarks()
                taste.clearAI()
            }
                .disabled(library.marks.isEmpty)
        } header: {
            Text(L("Рекомендации"))
        } footer: {
            Text(L("«Вам понравится?» подбирается по оценкам «Нравится», «Обожаю» и «Не моё», «Моему списку» и просмотренному — вместе с похожими по TMDb."))
        }
    }

    @ViewBuilder private var catalogueSection: some View {
        @Bindable var settings = settings
        Section {
            TextField(L("Прокси TMDb"), text: $settings.tmdbProxy)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField(L("Ключ MDBList (оценки IMDb, RT)"), text: $settings.mdblistKey)
            LabeledContent(L("Кэш ответов"), value: Format.bytes(Int64(cacheBytes)))
            Button(L("Очистить кэш"), role: .destructive) {
                DiskCache.api.clear()
                ImageLoader.shared.clear()
                cacheBytes = DiskCache.api.bytes
            }
        } header: {
            Text(L("Каталог"))
        } footer: {
            Text(L("Если TMDb недоступен напрямую, запросы идут через этот Worker. Бесплатный ключ MDBList — на mdblist.com, в разделе Preferences: с ним на странице фильма видны оценки IMDb, Rotten Tomatoes и Metacritic."))
        }
        Section {
            Toggle(L("Показывать оценки MDBList"), isOn: $settings.mdblistShown)
            if settings.mdblistShown {
                ForEach(AppSettings.ratingCatalog, id: \.key) { source in
                    Toggle(isOn: Binding(get: { settings.ratingSources.contains(source.key) }, set: { on in
                        if on { settings.ratingSources.insert(source.key) } else { settings.ratingSources.remove(source.key) }
                    })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.title)
                            Text(source.about).font(.aerial(.caption)).foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
            }
        } header: {
            Text(L("Оценки"))
        } footer: {
            Text(L("TMDb всегда первым: оценка пользователей кинобазы из 10."))
        }
    }

    @ViewBuilder private var aiSection: some View {
        @Bindable var settings = settings
        Section {
            Toggle(L("ИИ включён"), isOn: $settings.aiOn)
            SecureField(L("Ключ Gemini (aistudio.google.com)"), text: $settings.geminiKey)
            SecureField(L("Ключ Groq (console.groq.com)"), text: $settings.groqKey)
            if settings.aiEnabled {
                Toggle(L("Подборки по настроению на главной"), isOn: $settings.aiMoodShelves)
                Toggle(L("Сводка отзывов"), isOn: $settings.summarizeReviews)
                Toggle(L("Переводить отзывы сразу"), isOn: $settings.translateReviews)
            }
            if AI.regionBlocked {
                Label(L("Google и Groq не обслуживают вашу страну — ИИ работает только через VPN."), systemImage: "exclamationmark.triangle")
                    .font(.aerial(.footnote)).foregroundStyle(.yellow)
            } else if let error = taste.aiError {
                Text(error).font(.aerial(.footnote)).foregroundStyle(Theme.secondaryText)
            }
        } header: {
            Text(L("ИИ"))
        } footer: {
            Text(L("Свои бесплатные ключи. ИИ ищет фильм по описанию своими словами, подбирает «Вам понравится?» и подборки по настроению, находит «Духовных родственников», делает «Разбор» после просмотра, сводит и переводит отзывы. Есть оба ключа — основной Gemini, Groq подхватывает при лимите."))
        }
    }

    @ViewBuilder private var subtitlesSection: some View {
        @Bindable var settings = settings
        Section {
            SecureField(L("Ключ OpenSubtitles"), text: $settings.openSubsKey)
            TextField(L("Языки субтитров, например ru,en"), text: $settings.subsLanguages)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text(L("Субтитры"))
        } footer: {
            Text(L("С ключом (бесплатно: opensubtitles.com/consumers) в плеере появляется «Субтитры › Найти субтитры…». Без ключа — только субтитры из самой раздачи."))
        }
    }

    @ViewBuilder private var friendsSection: some View {
        if Friends.shared.enabled {
            Section {
                NavigationLink(L("Друзья и комнаты")) { FriendsView() }
                LabeledContent(L("Ваш код"), value: Friends.shared.friendCode)
            } header: {
                Text(L("Вместе"))
            } footer: {
                Text(L("Друзья видят, что вы смотрите, и могут войти в вашу комнату: пауза и перемотка — у всех сразу."))
            }
        }
    }

    @ViewBuilder private var dataSection: some View {
        Section {
            Button(L("Сохранить копию…")) {
                if let data = try? Backup.export() {
                    backupFile = BackupFile(data: data)
                    exporting = true
                }
            }
            Button(L("Восстановить из копии…")) { importing = true }
            if let backupNote { Text(backupNote).font(.aerial(.footnote)).foregroundStyle(Theme.secondaryText) }
        } header: {
            Text(L("Данные"))
        } footer: {
            Text(L("Настройки, ключи, «Мой список», оценки, прогресс, подписки и друзья — одним файлом. Его можно сохранить в «Файлы» или iCloud и восстановить на другом iPhone."))
        }
    }

    @ViewBuilder private var aboutSection: some View {
        Section {
            LabeledContent(L("Версия"), value: version)
            LabeledContent(L("Журналы"), value: L("Файлы › На iPhone › Aerial › logs"))
            // Где бы ни стояло приложение (и в LiveContainer, чья папка в «Файлах» может быть скрыта), журналы
            // отправляются отсюда: app, mpv, perf, отчёты MetricKit и журнал TorrServer.
            ShareLink(items: Self.logFiles()) {
                Label(L("Поделиться журналами"), systemImage: "square.and.arrow.up")
            }
        } header: {
            Text(L("О приложении"))
        }
    }

    /// Все файлы журналов: `logs/` с прошлыми запусками и `metrics/`, плюс журнал встроенного TorrServer.
    private static func logFiles() -> [URL] {
        let manager = FileManager.default
        var files: [URL] = []
        if let walker = manager.enumerator(at: Log.directory, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                files.append(url)
            }
        }
        // В LiveContainer база и журнал сервера — во временной папке процесса, в «Файлах» их не видно.
        let server = EmbeddedTorrServer.shared.dataDirectory
        for name in ["torrserver.log", "torrserver.log.1"] where manager.fileExists(atPath: server.appending(path: name).path) {
            files.append(server.appending(path: name))
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Строка раздела: значок в цветном квадрате, как в «Настройках» iOS; внутри — свои секции.
    private func category<Content: View>(_ title: String, _ symbol: String, _ color: Color,
                                         @ViewBuilder content: @escaping () -> Content) -> some View {
        NavigationLink {
            Form { content() }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 29, height: 29)
                    .background(color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
    }

    private var embeddedState: String {
        switch server.state {
        case .stopped: L("Остановлен")
        case .starting: L("Запускается…")
        case .running(let version): L("Работает · %@", version)
        case .failed(let reason): L("Ошибка: %@", reason)
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    private func probe() async {
        await withTaskGroup(of: (String, Bool).self) { group in
            for entry in AppSettings.parserCatalog {
                group.addTask { (entry.address, await ReleaseSearch.probe(entry.address)) }
            }
            for await (address, ok) in group { probes[address] = ok }
        }
    }

    private func checkExternal() async {
        externalCheck = L("Проверяю…")
        guard let client = try? TorrServerClient(address: settings.externalAddress) else {
            externalCheck = L("Некорректный адрес")
            return
        }
        if let version = await client.echo() {
            externalCheck = L("Работает · %@", version)
        } else {
            externalCheck = L("Не отвечает")
        }
    }
}
