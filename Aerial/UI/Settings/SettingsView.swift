import SwiftUI

/// Вкладка «Настройки»: поиск раздач, TorrServer (встроенный или внешний), плеер, подбор, TMDb, кэш, журналы.
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Library.self) private var library

    @State private var probes: [String: Bool] = [:]
    @State private var externalCheck: String?
    @State private var cacheBytes = 0

    private var server: EmbeddedTorrServer { .shared }

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
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

                Section {
                    Toggle("Следующая серия автоматически", isOn: $settings.autoplayNext)
                } header: {
                    Text("Плеер")
                } footer: {
                    Text("Серия кончилась — через 10 с начнётся следующая из той же раздачи. Заставку можно пропустить кнопкой, если её отметили зрители IntroDB или AniSkip.")
                }

                Section {
                    Toggle("Учитывать историю просмотра", isOn: $settings.tasteHistory)
                    LabeledContent("Оценок", value: String(library.marks.count))
                    Button("Сбросить оценки", role: .destructive) { library.clearMarks() }
                        .disabled(library.marks.isEmpty)
                } header: {
                    Text("Рекомендации")
                } footer: {
                    Text("«Вам понравится?» подбирается по оценкам «Нравится», «Обожаю» и «Не моё», «Моему списку» и просмотренному — вместе с похожими по TMDb.")
                }

                Section {
                    TextField("Прокси TMDb", text: $settings.tmdbProxy)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    LabeledContent("Кэш ответов", value: Format.bytes(Int64(cacheBytes)))
                    Button("Очистить кэш", role: .destructive) {
                        DiskCache.api.clear()
                        ImageLoader.shared.clear()
                        cacheBytes = DiskCache.api.bytes
                    }
                } header: {
                    Text("Каталог")
                } footer: {
                    Text("Если TMDb недоступен напрямую, запросы идут через этот Worker.")
                }

                Section {
                    LabeledContent("Версия", value: version)
                    LabeledContent("Журналы", value: "Файлы › На iPhone › Aerial › logs")
                } header: {
                    Text("О приложении")
                }
            }
            .navigationTitle("Настройки")
            .task { await probe() }
            .task { cacheBytes = DiskCache.api.bytes }
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
