import SwiftUI

/// Поверх видео: действия и реплики зрителей — по центру сверху, тают через 6 с; реакции летят справа.
struct PartyOverlay: View {
    let party: WatchParty

    var body: some View {
        ZStack {
            VStack(spacing: 6) {
                ForEach(party.notes) { note in
                    HStack(spacing: 6) {
                        Text(note.from).font(.caption.weight(.bold))
                        Text(note.text).font(.caption).lineLimit(2)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .glass(in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }
            .padding(.top, 64)
            HStack {
                Spacer()
                VStack(spacing: 4) {
                    Spacer()
                    ForEach(party.reactions) { reaction in
                        Text(reaction.emoji).font(.system(size: 34)).transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.trailing, 28)
                .padding(.bottom, 150)
            }
        }
        .animation(.easeOut(duration: 0.25), value: party.notes)
        .animation(.easeOut(duration: 0.25), value: party.reactions)
        .allowsHitTesting(false)
    }
}

/// «Смотреть вместе»: создать комнату и раздать код или войти по коду; в комнате — зрители, чат, реакции.
struct PartySheet: View {
    let model: PlayerModel

    @Environment(\.dismiss) private var dismiss
    @State private var joinCode = ""
    @State private var message = ""
    private var party: WatchParty { .shared }
    private static let emoji = ["😂", "😱", "😍", "👍", "🔥", "😢", "👏", "🤯"]

    var body: some View {
        NavigationStack {
            Group {
                if let code = party.code { room(code) } else { start }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Смотреть вместе")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private var start: some View {
        Form {
            Section {
                Button {
                    model.hostParty()
                } label: {
                    Label("Создать комнату с этим фильмом", systemImage: "person.2.badge.plus")
                }
            } footer: {
                Text("Видео не передаётся: у каждого раздача качается своим TorrServer, через комнату идут только пауза, перемотка, чат и реакции.")
            }
            Section("Войти по коду") {
                TextField("Код комнаты", text: $joinCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                Button("Войти") { party.join(joinCode) }.disabled(joinCode.count < 4)
                if let error = party.error { Text(error).foregroundStyle(.red) }
            }
        }
    }

    private func room(_ code: String) -> some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Комната").font(.caption).foregroundStyle(Theme.secondaryText)
                        Text(code).font(.system(.title, design: .monospaced).weight(.bold)).textSelection(.enabled)
                    }
                    Spacer()
                    ShareLink(item: "Смотрим вместе в Aerial — код комнаты \(code)") { Image(systemName: "square.and.arrow.up") }
                }
                LabeledContent("Связь", value: status)
                if let room = party.room, !room.members.isEmpty {
                    LabeledContent("Зрители", value: room.members.joined(separator: ", "))
                }
                if party.media != nil && !model.partyFile {
                    Text("Комната смотрит другой файл — плеер переключится на него.").font(.footnote).foregroundStyle(Theme.secondaryText)
                }
            }
            Section("Реакции") {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(Self.emoji, id: \.self) { emoji in
                            Button(emoji) { party.sendReaction(emoji) }.font(.system(size: 30)).buttonStyle(.plain)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            Section("Чат") {
                ForEach(party.chat.suffix(50)) { note in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.mine ? "Вы" : note.from).font(.caption.weight(.semibold))
                            .foregroundStyle(note.mine ? Theme.accent : Theme.secondaryText)
                        Text(note.text).font(.subheadline)
                    }
                }
                HStack {
                    TextField("Сообщение", text: $message).onSubmit(sendMessage)
                    Button(action: sendMessage) { Image(systemName: "paperplane.fill") }.disabled(message.isEmpty)
                }
            }
            Section {
                Button("Выйти из комнаты", role: .destructive) {
                    party.leave()
                    Friends.shared.watching = FriendWatching(title: model.request.item.title, sub: model.request.episode?.code ?? "",
                                                             poster: model.request.item.poster)
                }
            }
        }
    }

    private var status: String {
        if let error = party.error, !party.connected { return error }
        guard party.connected else { return "Подключаюсь…" }
        return party.rttMs >= 0 ? "Есть · пинг \(party.rttMs) мс" : "Есть"
    }

    private func sendMessage() {
        party.sendChat(message)
        message = ""
    }
}

/// Друзья: свой код, друзья по кодам — в сети ли и что смотрят; стук и вход в их комнату. Устройства одного человека
/// объединяются в аккаунт по PIN (общий список друзей).
struct FriendsView: View {
    @State private var newCode = ""
    @State private var newName = ""
    @State private var linkPin: String?
    @State private var joinPin = ""
    @State private var note: String?
    private var friends: Friends { .shared }

    var body: some View {
        Form {
            Section {
                LabeledContent("Ваш код") {
                    Text(friends.friendCode).font(.system(.title3, design: .monospaced).weight(.bold)).textSelection(.enabled)
                }
                ShareLink(item: "Мой код в Aerial: \(friends.friendCode)") { Label("Отправить код", systemImage: "square.and.arrow.up") }
            } footer: {
                Text("Друзья добавляются по кодам. Видно, кто в сети и что смотрит; в открытую комнату можно войти сразу.")
            }
            Section("Друзья") {
                if friends.friends.isEmpty && friends.codes.isEmpty {
                    Text("Пока никого").foregroundStyle(Theme.secondaryText)
                }
                ForEach(friends.friends) { friend in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Circle().fill(friend.online ? Color(hex: 0x3DDC84) : .gray).frame(width: 8, height: 8)
                            Text(friends.label(friend)).font(.headline)
                            Spacer()
                            if friend.online {
                                Button("Постучаться") {
                                    friends.knock(friend.code)
                                    note = "\(friends.label(friend)) увидит, что вы хотите смотреть вместе."
                                }
                                .font(.caption)
                                .buttonStyle(.bordered)
                            }
                        }
                        if let watching = friend.watching {
                            Text([watching.title, watching.sub].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(Theme.secondaryText)
                            if !watching.room.isEmpty {
                                Button("Войти в комнату \(watching.room)") { WatchParty.shared.join(watching.room) }
                                    .font(.caption.weight(.semibold))
                            }
                        }
                    }
                    .swipeActions { Button("Удалить", role: .destructive) { friends.remove(friend.code) } }
                }
                ForEach(friends.codes.filter { code in !friends.friends.contains { $0.code == code } }, id: \.self) { code in
                    Text(code).font(.system(.body, design: .monospaced)).foregroundStyle(Theme.secondaryText)
                        .swipeActions { Button("Удалить", role: .destructive) { friends.remove(code) } }
                }
            }
            Section("Добавить друга") {
                TextField("Код друга (6 символов)", text: $newCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                TextField("Имя (необязательно)", text: $newName)
                Button("Добавить") {
                    if friends.add(newCode, name: newName) {
                        newCode = ""
                        newName = ""
                    } else {
                        note = "Код не подошёл: нужно 6 символов, и не свой."
                    }
                }
                .disabled(newCode.count < 6)
            }
            Section {
                ForEach(Array(friends.devices.enumerated()), id: \.offset) { _, device in
                    LabeledContent(device.name, value: device.online ? "в сети" : "не в сети")
                }
                if let linkPin {
                    LabeledContent("PIN для другого устройства", value: linkPin)
                } else {
                    Button("Добавить своё устройство") { Task { linkPin = await friends.newLinkPin() ?? "сервер недоступен" } }
                }
                HStack {
                    TextField("PIN с другого устройства", text: $joinPin).keyboardType(.numberPad)
                    Button("Войти") {
                        Task { note = await friends.joinAccount(joinPin) ? "Устройство в аккаунте." : "PIN не подошёл." }
                    }
                    .disabled(joinPin.count < 4)
                }
                if friends.account != friends.myCode {
                    Button("Отвязать это устройство", role: .destructive) { Task { _ = await friends.leaveAccount() } }
                }
            } header: {
                Text("Мои устройства")
            } footer: {
                Text("Телефон, ТВ и компьютер можно объединить: у них будет общий код и общий список друзей.")
            }
            Section("Комната") {
                TextField("Код комнаты", text: Binding(get: { joinRoom }, set: { joinRoom = $0 }))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                Button("Войти в комнату") { WatchParty.shared.join(joinRoom) }.disabled(joinRoom.count < 4)
                if WatchParty.shared.active {
                    LabeledContent("Вы в комнате", value: WatchParty.shared.code ?? "")
                    if WatchParty.shared.media == nil { Text("Жду фильм от комнаты…").font(.footnote).foregroundStyle(Theme.secondaryText) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Друзья")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Друзья", isPresented: Binding(get: { note != nil }, set: { if !$0 { note = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(note ?? "") }
        .refreshable { friends.refreshNow() }
        .onAppear { friends.refreshNow() }
    }

    @State private var joinRoom = ""
}
