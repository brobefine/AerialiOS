import Foundation
import Observation

/// Что смотрит комната: раздача, файл и оформление. [series]/[season]/[episode] — сериал TMDb и серия файла у создателя:
/// по ним гость находит заставку и титры.
struct PartyMedia: Equatable, Sendable {
    var hash: String
    var file: Int
    var title: String
    var poster = ""
    var backdrop = ""
    var year = ""
    var series = ""
    var season = 0
    var episode = 0

    var json: [String: Any] {
        ["hash": hash, "file": file, "title": title, "poster": poster, "backdrop": backdrop, "year": year,
         "series": series, "season": season, "episode": episode]
    }

    static func from(_ object: [String: Any]?) -> PartyMedia? {
        guard let object, let hash = (object["hash"] as? String)?.lowercased(), Rx("^[0-9a-f]{40}$").matches(hash) else { return nil }
        func int(_ key: String) -> Int { (object[key] as? NSNumber)?.intValue ?? Int(object[key] as? String ?? "") ?? 0 }
        return PartyMedia(hash: hash, file: int("file"), title: object["title"] as? String ?? "", poster: object["poster"] as? String ?? "",
                          backdrop: object["backdrop"] as? String ?? "", year: object["year"] as? String ?? "",
                          series: object["series"] as? String ?? "", season: int("season"), episode: int("episode"))
    }
}

/// Общий ход комнаты и момент, когда он пришёл (по часам устройства).
struct PartyState: Equatable, Sendable {
    var playing: Bool
    var position: Double
    var buffering: Int
    var members: [String]
    var receivedAt: TimeInterval

    /// Где должен быть фильм сейчас. Пока кто-то буферизуется, ход стоит.
    func target(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double {
        playing && buffering == 0 ? position + (now - receivedAt) : position
    }
    var effectivePlaying: Bool { playing && buffering == 0 }
}

/// Уведомление о действии другого зрителя или реплика чата.
struct PartyNote: Identifiable, Equatable, Sendable {
    var id: Int
    var from: String
    var text: String
    var chat: Bool
    var mine: Bool
}

struct PartyReaction: Identifiable, Equatable, Sendable {
    var id: Int
    var emoji: String
    var from: String
}

/// Совместный просмотр — перенос `WatchParty` ТВ через Worker `aerial-api` (Durable Object PartyRoom). Видео между
/// устройствами не ходит: каждый TorrServer качает раздачу сам, через комнату идут пауза, ход, перемотка, чат и реакции.
/// Связь — WebSocket; действия ещё и дублируются коротким POST и повторяются до подтверждения комнатой; сторож связи
/// переподключается, если комната молчит дольше 7,5 с.
@MainActor @Observable
final class WatchParty {
    static let shared = WatchParty()
    private static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    static let noteSeconds: Double = 6
    static let reactionSeconds: Double = 3

    private(set) var code: String?
    private(set) var connected = false
    private(set) var room: PartyState?
    private(set) var media: PartyMedia?
    private(set) var error: String?
    private(set) var rttMs = -1
    private(set) var notes: [PartyNote] = []
    private(set) var chat: [PartyNote] = []
    private(set) var reactions: [PartyReaction] = []
    var active: Bool { code != nil }
    var enabled: Bool { BuildKeys.apiEnabled }

    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var hello: [String: Any]?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var hosting = false
    @ObservationIgnored private var pending: [String: Any]?
    @ObservationIgnored private var pendingAt: TimeInterval = 0
    @ObservationIgnored private var stateSeq = Int(Date().timeIntervalSince1970 * 1000)
    @ObservationIgnored private var lastPongAt: TimeInterval = 0
    @ObservationIgnored private var connectAt: TimeInterval = 0
    @ObservationIgnored private var lastBuffering: Bool?
    @ObservationIgnored private var lastLog = 0
    @ObservationIgnored private var seenLog: [Int] = []
    @ObservationIgnored private var pendingEcho: [String] = []
    @ObservationIgnored private var noteSeq = 0
    /// Один на запуск: по нему комната узнаёт переподключившееся устройство и убирает прежнее соединение.
    @ObservationIgnored private let clientId = UUID().uuidString
    @ObservationIgnored private let session = URLSession(configuration: .default)

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Комната

    /// Создать комнату со своим фильмом. Возвращает код для гостей.
    @discardableResult
    func host(_ value: PartyMedia, playing: Bool, position: Double) -> String {
        let newCode = String((0..<5).map { _ in Self.alphabet.randomElement()! })
        hosting = true
        start(newCode, hello: ["t": "hello", "name": Friends.deviceName, "cid": clientId, "fc": Friends.shared.friendCode,
                               "media": value.json, "playing": playing, "pos": Int(position * 1000)])
        media = value
        Log.note("PARTY", "создана \(newCode): \(value.title)")
        return newCode
    }

    /// Войти в комнату по коду; фильм придёт в [media].
    func join(_ raw: String) {
        let clean = String(raw.uppercased().filter { Self.alphabet.contains($0) })
        guard (4...8).contains(clean.count) else {
            error = "Неверный код"
            return
        }
        hosting = false
        start(clean, hello: ["t": "hello", "name": Friends.deviceName, "cid": clientId, "fc": Friends.shared.friendCode])
        Log.note("PARTY", "вход в \(clean)")
    }

    func leave() {
        generation += 1
        loop?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        code = nil
        connected = false
        room = nil
        media = nil
        error = nil
        hello = nil
        rttMs = -1
        notes = []
        chat = []
        reactions = []
        pending = nil
        pendingEcho = []
        lastLog = 0
        seenLog = []
    }

    // MARK: Действия

    /// Своё действие: пауза, ход, перемотка. Сразу и у себя, затем — надёжной доставкой до подтверждения комнатой.
    func sendState(playing: Bool, position: Double) {
        let ms = Int(max(0, position) * 1000)
        if var current = room {
            current.playing = playing
            current.position = max(0, position)
            current.receivedAt = now
            room = current
        }
        stateSeq += 1
        let message: [String: Any] = ["t": "state", "playing": playing, "pos": ms, "seq": stateSeq]
        pending = message
        pendingAt = now
        deliver(message)
    }

    func sendBuffering(_ on: Bool) {
        guard lastBuffering != on else { return }
        lastBuffering = on
        send(["t": "buffering", "on": on])
    }

    /// Смена серии: та же раздача, другой файл — у всех открывается он же.
    func switchMedia(_ value: PartyMedia) {
        guard active, media != value else { return }
        media = value
        if var current = room {
            current.playing = true
            current.position = 0
            current.receivedAt = now
            room = current
        }
        send(["t": "media", "media": value.json, "pos": 0])
    }

    func sendChat(_ text: String) {
        let clean = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        guard !clean.isEmpty else { return }
        deliver(["t": "chat", "text": clean, "mid": UUID().uuidString])
        // Своё сообщение — в ленту сразу; эхо комнаты опознаётся по тексту и второй раз не добавляется.
        pendingEcho.append(clean)
        noteSeq += 1
        chat = Array((chat + [PartyNote(id: noteSeq, from: Friends.deviceName, text: clean, chat: true, mine: true)]).suffix(200))
    }

    /// Догрузил место после перемотки — комната ждёт всех, потом общий ход идёт дальше.
    func sendReady() { deliver(["t": "ready", "mid": UUID().uuidString]) }

    func sendReaction(_ emoji: String) {
        deliver(["t": "react", "emoji": emoji, "mid": UUID().uuidString], post: false)
    }

    // MARK: Связь

    private func start(_ newCode: String, hello message: [String: Any]) {
        leave()
        code = newCode
        hello = message
        lastBuffering = nil
        let gen = generation
        connect(gen)
        // Пинг раз в 3 с, сводка не нужна; неподтверждённое действие — повтор раз в секунду, не дольше 15 с.
        loop = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self, gen == generation else { return }
                let time = now
                if connected && time - lastPongAt > 7.5 || !connected && time - connectAt > 5 {
                    Log.note("PARTY", connected ? "нет ответа комнаты, переподключаемся" : "соединение не открылось, ещё раз")
                    connected = false
                    connect(gen)
                } else if connected && time - connectAt > 60 {
                    connect(gen)
                }
                if connected && tick % 2 == 0 { send(["t": "ping", "at": Int(time * 1000)]) }
                if let message = pending {
                    if time - pendingAt > 15 {
                        pending = nil
                    } else if time - pendingAt >= 1 {
                        pendingAt = time
                        deliver(message)
                    }
                }
                tick += 1
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }
    }

    private func connect(_ gen: Int) {
        guard let code, let base = BuildKeys.apiBase,
              var components = URLComponents(url: base.appending(path: "party/\(code)"), resolvingAgainstBaseURL: false) else { return }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        guard let url = components.url else { return }
        connectAt = now
        var request = URLRequest(url: url)
        request.setValue(BuildKeys.apiToken, forHTTPHeaderField: "X-Aerial-Token")
        let old = socket
        let task = session.webSocketTask(with: request)
        socket = task
        task.resume()
        // Прежнее соединение закрывается чуть позже: новое уже открыто, пауз в связи нет.
        if let old { Task { try? await Task.sleep(for: .seconds(3)); old.cancel(with: .normalClosure, reason: nil) } }
        opened(task, gen)
        receive(task, gen)
    }

    /// Открытие: hello, неподтверждённое действие и догон журнала.
    private func opened(_ task: URLSessionWebSocketTask, _ gen: Int) {
        var first: [[String: Any]] = []
        if let hello { first.append(hello) }
        if let pending { first.append(pending) }
        first.append(["t": "history", "since": lastLog])
        Task { [weak self] in
            for message in first {
                guard let data = try? JSONSerialization.data(withJSONObject: message), let text = String(data: data, encoding: .utf8) else { continue }
                do {
                    try await task.send(.string(text))
                } catch {
                    self?.failed(task, gen, error)
                    return
                }
            }
            guard let self, gen == generation, task === socket else { return }
            connected = true
            error = nil
            lastPongAt = now
        }
    }

    private func receive(_ task: URLSessionWebSocketTask, _ gen: Int) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                switch result {
                case .success(let message):
                    if task === self.socket { self.lastPongAt = self.now }
                    if case .string(let text) = message, let data = text.data(using: .utf8),
                       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.handle(object, from: task)
                    }
                    self.receive(task, gen)
                case .failure(let error):
                    self.failed(task, gen, error)
                }
            }
        }
    }

    private func failed(_ task: URLSessionWebSocketTask, _ gen: Int, _ failure: Error) {
        guard gen == generation, task === socket else { return }
        connected = false
        let code = ((task.response as? HTTPURLResponse)?.statusCode) ?? 0
        if code == 403 {
            error = "Комнаты недоступны (ключ)"
            return
        }
        if code == 429 {
            error = "Комната заполнена"
            return
        }
        error = "Нет связи с комнатой, переподключаемся…"
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, gen == generation, task === socket else { return }
            connect(gen)
        }
    }

    @discardableResult
    private func send(_ message: [String: Any]) -> Bool {
        var message = message
        // Имя и устройство — в каждом действии: при смене соединения действие могло дойти раньше hello.
        if !["ping", "who", "stat", "hello"].contains(message["t"] as? String ?? "") {
            message["name"] = Friends.deviceName
            message["cid"] = clientId
        }
        guard let socket, connected, let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return false }
        socket.send(.string(text)) { _ in }
        return true
    }

    /// По WebSocket и (для надёжности) коротким POST — комната применяет повтор один раз.
    private func deliver(_ message: [String: Any], post: Bool = true) {
        let sent = send(message)
        if !post && sent { return }
        guard let code, let base = BuildKeys.apiBase else { return }
        var message = message
        message["name"] = Friends.deviceName
        message["cid"] = clientId
        let body: [String: Any] = ["cid": clientId, "m": message]
        Task {
            _ = try? await HTTP.postJSON(base.appending(path: "party/\(code)"), body: body, timeout: 5,
                                         headers: ["X-Aerial-Token": BuildKeys.apiToken])
        }
    }

    // MARK: Входящее

    private func handle(_ object: [String: Any], from task: URLSessionWebSocketTask) {
        switch object["t"] as? String ?? "" {
        case "ack":
            let seq = (object["seq"] as? NSNumber)?.intValue ?? 0
            if let pendingSeq = pending?["seq"] as? Int, pendingSeq <= seq { pending = nil }
        case "pong":
            let sent = (object["at"] as? NSNumber)?.doubleValue ?? 0
            if sent > 0 { rttMs = Int(now * 1000 - sent) }
            // Версия журнала комнаты новее нашей — рассылка ушла в замёрзшее соединение; догоняем.
            let n = (object["n"] as? NSNumber)?.intValue ?? -1
            if n > lastLog { send(["t": "history", "since": lastLog]) }
        case "event", "chat", "react":
            log(object, replay: false)
        case "history":
            for row in object["items"] as? [[String: Any]] ?? [] { log(row, replay: true) }
        case "room":
            for row in object["tail"] as? [[String: Any]] ?? [] { log(row, replay: false) }
            let state = PartyState(playing: object["playing"] as? Bool ?? false,
                                   position: ((object["pos"] as? NSNumber)?.doubleValue ?? 0) / 1000,
                                   buffering: (object["buffering"] as? NSNumber)?.intValue ?? 0,
                                   members: object["members"] as? [String] ?? [],
                                   // Сообщение шло к нам половину пинга: общий ход уже ушёл вперёд на столько же.
                                   receivedAt: now - Double(min(2000, max(0, rttMs))) / 2000)
            // Своё неподтверждённое действие главнее: снимок комнаты мог уйти до него.
            if let pending, let playing = pending["playing"] as? Bool {
                var mine = state
                mine.playing = playing
                mine.position = room?.target() ?? state.position
                room = mine
            } else {
                room = state
            }
            if let roomMedia = PartyMedia.from(object["media"] as? [String: Any]), roomMedia != media { media = roomMedia }
            // Гость дружит только с хозяином, хозяин — со всеми, кто ввёл его код.
            let peers = (object["peers"] as? [[String: Any]] ?? []).filter { hosting || $0["host"] as? Bool == true }
                .map { (code: $0["fc"] as? String ?? "", name: $0["name"] as? String ?? "") }
                .filter { !$0.code.isEmpty && $0.code != Friends.shared.friendCode }
            if !peers.isEmpty { Friends.shared.adoptPeers(peers) }
        default:
            break
        }
    }

    private func log(_ object: [String: Any], replay: Bool) {
        let n = (object["n"] as? NSNumber)?.intValue ?? 0
        if n > 0 {
            if seenLog.contains(n) { return }
            seenLog.append(n)
            if seenLog.count > 500 { seenLog.removeFirst() }
            lastLog = max(lastLog, n)
        }
        let mine = object["fromId"] as? String == clientId
        let from = object["from"] as? String ?? ""
        switch object["t"] as? String ?? "" {
        case "chat":
            let text = object["text"] as? String ?? ""
            if mine, let index = pendingEcho.firstIndex(of: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                pendingEcho.remove(at: index)
                return
            }
            noteSeq += 1
            let note = PartyNote(id: noteSeq, from: from, text: text, chat: true, mine: mine)
            chat = Array((chat + [note]).suffix(200))
            if !mine && !replay { addNote(note) }
        case "react":
            guard !replay else { return }
            noteSeq += 1
            let reaction = PartyReaction(id: noteSeq, emoji: object["emoji"] as? String ?? "", from: from)
            reactions = Array((reactions + [reaction]).suffix(24))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.reactionSeconds))
                self?.reactions.removeAll { $0.id == reaction.id }
            }
        default:
            guard !mine, !replay, let text = Self.eventText(object) else { return }
            noteSeq += 1
            addNote(PartyNote(id: noteSeq, from: from, text: text, chat: false, mine: false))
        }
    }

    private func addNote(_ incoming: PartyNote) {
        // То же от того же зрителя подряд (перемотка, пауза-продолжение) — та же плашка с новым текстом.
        var note = incoming
        if let last = notes.last, !incoming.chat, !last.chat, last.from == incoming.from {
            note.id = last.id
            notes[notes.count - 1] = note
        } else {
            notes = Array((notes + [note]).suffix(3))
        }
        let shown = note
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.noteSeconds))
            self?.notes.removeAll { $0 == shown }
        }
    }

    /// Подпись действия зрителя — в настоящем времени: род по имени не угадать.
    private static func eventText(_ object: [String: Any]) -> String? {
        switch object["kind"] as? String ?? "" {
        case "join": "входит в комнату"
        case "leave": "выходит из комнаты"
        case "pause": "ставит на паузу"
        case "play": "продолжает просмотр"
        case "seek": "перематывает"
        case "media": "включает " + String((object["title"] as? String ?? "").prefix(60))
        default: nil
        }
    }
}
