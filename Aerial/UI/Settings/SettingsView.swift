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
                    category("Поиск раздач", "magnifyingglass", .blue) { parserSection }
                    category("TorrServer", "server.rack", .green) { serverSection }
                    category("Плеер", "play.rectangle.fill", .orange) { playerSection; subtitlesSection }
                }
                Section {
                    category("Рекомендации", "hand.thumbsup.fill", .pink) { tasteSection }
                    category("Каталог и оценки", "film.stack", .indigo) { catalogueSection }
                    category("ИИ", "sparkles", .purple) { aiSection }
                    if Friends.shared.enabled {
                        category("Вместе", "person.2.fill", .teal) { friendsSection }
                    }
                }
                Section {
                    category("Данные", "externaldrive.fill", .gray) { dataSection }
                    category("О приложении", "info.circle.fill", .gray) { aboutSection }
                }
            }
            .navigationTitle("Настройки")
            .fileExporter(isPresented: $exporting, document: backupFile, contentType: .propertyList, defaultFilename: Backup.fileName) { result in
                if case .success = result { backupNote = "Копия сохранена." }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.propertyList, .data]) { result in
                guard case .success(let url) = result else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    let count = try Backup.restore(Data(contentsOf: url))
                    library.reload()
                    backupNote = "Восстановлено \(count) значений. Настройки применятся полностью после перезапуска Aerial."
                } catch {
                    backupNote = "Это не копия Aerial для iPhone."
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
                                .font(.caption2)
                                .foregroundStyle(ok ? Color(hex: 0x3DDC84) : Color(hex: 0xFF5A4E))
                        }
                        if settings.parserAddress == entry.address {
                            Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
            TextField("Свой адрес (JacRed или Jackett)", text: $settings.parserAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            SecureField("Ключ API (если нужен)", text: $settings.parserKey)
            Toggle("Torrentio — зарубежные раздачи", isOn: $settings.torrentio)
        } header: {
            Text("Поиск раздач")
        } footer: {
            Text("Зелёная точка — сервер отвечает. Torrentio ищет по номеру IMDb, русских озвучек там мало.")
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
                LabeledContent("Состояние", value: embeddedState)
                Picker("Кэш в памяти", selection: $settings.cacheMB) {
                    ForEach([128, 256, 512], id: \.self) { Text("\($0) МБ").tag($0) }
                }
                .onChange(of: settings.cacheMB) { _, value in
                    Task { await server.configure(cacheMB: value) }
                }
            } else {
                TextField("Адрес, например 192.168.1.10:8090", text: $settings.externalAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("Проверить") { Task { await checkExternal() } }
                if let externalCheck { Text(externalCheck).font(.footnote).foregroundStyle(Theme.secondaryText) }
            }
        } header: {
            Text("TorrServer")
        } footer: {
            Text(settings.serverMode == .embedded
                 ? "Встроенный работает, пока открыто приложение или идёт фильм. Раздача качается во время просмотра — по мобильной сети это трафик."
                 : "TorrServer на телевизоре или компьютере в той же сети.")
        }
    }

    @ViewBuilder private var playerSection: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Описания серий", isOn: $settings.episodeOverviews)
            Toggle("Скрывать спойлеры серий", isOn: $settings.hideSpoilers)
        } header: {
            Text("Серии")
        } footer: {
            Text("Спойлеры: у непросмотренных серий кадр размыт, а описание скрыто.")
        }
        Section {
            Button("Сбросить фильтры и сортировку раздач") {
                UserDefaults.standard.removeObject(forKey: "releases.sort")
                UserDefaults.standard.removeObject(forKey: "releases.quality")
            }
            Button("Очистить историю поиска") { UserDefaults.standard.removeObject(forKey: "search.recent") }
        }
        Section {
            Toggle("Следующая серия автоматически", isOn: $settings.autoplayNext)
        } header: {
            Text("Плеер")
        } footer: {
            Text("Серия кончилась — через 10 с начнётся следующая из той же раздачи. Заставку можно пропустить кнопкой, если её отметили зрители IntroDB или AniSkip. Скачанное (удерживайте раздачу — «Скачать») играет с телефона без сети и лежит в «Файлах» › Aerial › Downloads.")
        }
    }

    @ViewBuilder private var tasteSection: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Учитывать историю просмотра", isOn: $settings.tasteHistory)
            LabeledContent("Оценок", value: String(library.marks.count))
            Button("Очистить «Продолжить»", role: .destructive) { library.clearContinue() }
                .disabled(library.continueWatching.isEmpty)
            Button("Очистить историю просмотра", role: .destructive) { library.clearHistory() }
                .disabled(library.entries.isEmpty)
            Button("Начать рекомендации с нуля", role: .destructive) {
                library.clearHistory()
                library.clearMarks()
                taste.clearAI()
            }
            Button("Сбросить оценки", role: .destructive) {
                library.clearMarks()
                taste.clearAI()
            }
                .disabled(library.marks.isEmpty)
        } header: {
            Text("Рекомендации")
        } footer: {
            Text("«Вам понравится?» подбирается по оценкам «Нравится», «Обожаю» и «Не моё», «Моему списку» и просмотренному — вместе с похожими по TMDb.")
        }
    }

    @ViewBuilder private var catalogueSection: some View {
        @Bindable var settings = settings
        Section {
            TextField("Прокси TMDb", text: $settings.tmdbProxy)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Ключ MDBList (оценки IMDb, RT)", text: $settings.mdblistKey)
            LabeledContent("Кэш ответов", value: Format.bytes(Int64(cacheBytes)))
            Button("Очистить кэш", role: .destructive) {
                DiskCache.api.clear()
                ImageLoader.shared.clear()
                cacheBytes = DiskCache.api.bytes
            }
        } header: {
            Text("Каталог")
        } footer: {
            Text("Если TMDb недоступен напрямую, запросы идут через этот Worker. Бесплатный ключ MDBList — на mdblist.com, в разделе Preferences: с ним на странице фильма видны оценки IMDb, Rotten Tomatoes и Metacritic.")
        }
        Section {
            Toggle("Показывать оценки MDBList", isOn: $settings.mdblistShown)
            if settings.mdblistShown {
                ForEach(AppSettings.ratingCatalog, id: \.key) { source in
                    Toggle(isOn: Binding(get: { settings.ratingSources.contains(source.key) }, set: { on in
                        if on { settings.ratingSources.insert(source.key) } else { settings.ratingSources.remove(source.key) }
                    })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.title)
                            Text(source.about).font(.caption).foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
            }
        } header: {
            Text("Оценки")
        } footer: {
            Text("TMDb всегда первым: оценка пользователей кинобазы из 10.")
        }
    }

    @ViewBuilder private var aiSection: some View {
        @Bindable var settings = settings
        Section {
            Toggle("ИИ включён", isOn: $settings.aiOn)
            SecureField("Ключ Gemini (aistudio.google.com)", text: $settings.geminiKey)
            SecureField("Ключ Groq (console.groq.com)", text: $settings.groqKey)
            if settings.aiEnabled {
                Toggle("Подборки по настроению на главной", isOn: $settings.aiMoodShelves)
                Toggle("Сводка отзывов", isOn: $settings.summarizeReviews)
                Toggle("Переводить отзывы сразу", isOn: $settings.translateReviews)
            }
            if AI.regionBlocked {
                Label("Google и Groq не обслуживают вашу страну — ИИ работает только через VPN.", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.yellow)
            } else if let error = taste.aiError {
                Text(error).font(.footnote).foregroundStyle(Theme.secondaryText)
            }
        } header: {
            Text("ИИ")
        } footer: {
            Text("Свои бесплатные ключи. ИИ ищет фильм по описанию своими словами, подбирает «Вам понравится?» и подборки по настроению, находит «Духовных родственников», делает «Разбор» после просмотра, сводит и переводит отзывы. Есть оба ключа — основной Gemini, Groq подхватывает при лимите.")
        }
    }

    @ViewBuilder private var subtitlesSection: some View {
        @Bindable var settings = settings
        Section {
            SecureField("Ключ OpenSubtitles", text: $settings.openSubsKey)
            TextField("Языки субтитров, например ru,en", text: $settings.subsLanguages)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Субтитры")
        } footer: {
            Text("С ключом (бесплатно: opensubtitles.com/consumers) в плеере появляется «Субтитры › Найти субтитры…». Без ключа — только субтитры из самой раздачи.")
        }
    }

    @ViewBuilder private var friendsSection: some View {
        if Friends.shared.enabled {
            Section {
                NavigationLink("Друзья и комнаты") { FriendsView() }
                LabeledContent("Ваш код", value: Friends.shared.friendCode)
            } header: {
                Text("Вместе")
            } footer: {
                Text("Друзья видят, что вы смотрите, и могут войти в вашу комнату: пауза и перемотка — у всех сразу.")
            }
        }
    }

    @ViewBuilder private var dataSection: some View {
        Section {
            Button("Сохранить копию…") {
                if let data = try? Backup.export() {
                    backupFile = BackupFile(data: data)
                    exporting = true
                }
            }
            Button("Восстановить из копии…") { importing = true }
            if let backupNote { Text(backupNote).font(.footnote).foregroundStyle(Theme.secondaryText) }
        } header: {
            Text("Данные")
        } footer: {
            Text("Настройки, ключи, «Мой список», оценки, прогресс, подписки и друзья — одним файлом. Его можно сохранить в «Файлы» или iCloud и восстановить на другом iPhone.")
        }
    }

    @ViewBuilder private var aboutSection: some View {
        Section {
            LabeledContent("Версия", value: version)
            LabeledContent("Журналы", value: "Файлы › На iPhone › Aerial › logs")
        } header: {
            Text("О приложении")
        }
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
        case .stopped: "Остановлен"
        case .starting: "Запускается…"
        case .running(let version): "Работает · \(version)"
        case .failed(let reason): "Ошибка: \(reason)"
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
        externalCheck = "Проверяю…"
        guard let client = try? TorrServerClient(address: settings.externalAddress) else {
            externalCheck = "Некорректный адрес"
            return
        }
        if let version = await client.echo() {
            externalCheck = "Работает · \(version)"
        } else {
            externalCheck = "Не отвечает"
        }
    }
}
