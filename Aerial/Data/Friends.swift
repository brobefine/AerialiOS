import Foundation
import Observation
import UIKit

/// Что смотрит устройство сейчас (для друзей). [room] — код комнаты, если она открыта: друг может присоединиться.
struct FriendWatching: Equatable, Sendable {
    var title: String
    var sub = ""
    var poster = ""
    var room = ""
}

/// Друг по коду: в сети ли и что смотрит.
struct Friend: Identifiable, Equatable, Sendable {
    var code: String
    var name: String
    var online: Bool
    var watching: FriendWatching?
    var id: String { code }
}

/// Друзья — перенос `Friends` ТВ: у устройства свой код, друзей добавляют по их кодам; устройства можно объединить в
/// аккаунт (общий список друзей) по PIN. Раз в 90 с–5 мин (по подсказке сервера), пока идёт фильм — раз в 10 с, и сразу
/// при смене того, что смотрим, устройство сообщает Worker'у `aerial-api` статус и получает статус друзей.
/// Свёрнутое приложение не опрашивает. Сервер хранит только имя устройства, название и код комнаты.
@MainActor @Observable
final class Friends {
    static let shared = Friends()
    private static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    private static let period: TimeInterval = 90
    private static let watchingPeriod: TimeInterval = 10

    var enabled: Bool { BuildKeys.apiEnabled }
    /// Свой код — один раз на устройство.
    let myCode: String
    private(set) var codes: [String]
    /// Аккаунт: группа устройств под одним кодом с общим списком друзей. Одиночное устройство — само себе аккаунт.
    private(set) var account: String
    var friendCode: String { account }
    /// Устройства аккаунта (имя, в сети) — пусто, пока устройство одно.
    private(set) var devices: [(name: String, online: Bool)] = []
    private(set) var friends: [Friend] = []
    /// Кто постучался — плеер показывает и сбрасывает.
    var knockFrom: String?

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var names: [String: String]
    @ObservationIgnored private var friendsDirty: Bool
    @ObservationIgnored private var knockTo: String?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var pokeTask: Task<Void, Never>?
    @ObservationIgnored private var reportedAt = Date.distantPast
    @ObservationIgnored private var next = Friends.period

    var watching: FriendWatching? {
        didSet { if oldValue != watching { poke() } }
    }

    private init() {
        if let code = defaults.string(forKey: "friends.code") {
            myCode = code
        } else {
            myCode = String((0..<6).map { _ in Self.alphabet.randomElement()! })
            defaults.set(myCode, forKey: "friends.code")
        }
        codes = (defaults.stringArray(forKey: "friends.codes") ?? []).sorted()
        account = defaults.string(forKey: "friends.account") ?? myCode
        names = defaults.dictionary(forKey: "friends.names") as? [String: String] ?? [:]
        friendsDirty = defaults.bool(forKey: "friends.dirty")
    }

    static var deviceName: String { UIDevice.current.name.isEmpty ? "iPhone" : UIDevice.current.name }

    // MARK: Жизнь

    /// Приложение на экране — опрос идёт; свёрнуто — стоит, сервер сразу узнаёт «не в сети».
    func setForeground(_ visible: Bool) {
        guard enabled else { return }
        if visible {
            start()
            return
        }
        loop?.cancel()
        loop = nil
        pokeTask?.cancel()
        if !codes.isEmpty { Task { _ = try? await post(["me": myCode, "offline": true]) } }
    }

    private func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                if let self, Date().timeIntervalSince(reportedAt) >= (watching != nil ? Self.watchingPeriod : next) { await report() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Спросить статус друзей сейчас.
    func refreshNow() {
        guard enabled else { return }
        Task { await report() }
    }

    /// Постучаться к другу: у него в плеере появится «хочет присоединиться».
    func knock(_ code: String) {
        knockTo = code
        Log.note("ДРУЗЬЯ", "стук к \(code)")
        pokeTask?.cancel()
        pokeTask = Task { await report() }
    }

    // MARK: Список

    @discardableResult
    func add(_ raw: String, name: String = "") -> Bool {
        let code = String(raw.uppercased().filter { Self.alphabet.contains($0) })
        guard code.count == 6, code != myCode, code != account else { return false }
        codes = Array(Set(codes + [code])).sorted()
        let label = name.trimmingCharacters(in: .whitespaces)
        if !label.isEmpty { names[code] = String(label.prefix(40)) }
        save()
        Log.note("ДРУЗЬЯ", "добавлен \(code)")
        poke()
        return true
    }

    func remove(_ code: String) {
        codes.removeAll { $0 == code }
        names[code] = nil
        friends.removeAll { $0.code == code }
        save()
    }

    func label(_ friend: Friend) -> String {
        if let name = names[friend.code], !name.isEmpty { return name }
        return friend.name.isEmpty ? friend.code : friend.name
    }

    /// Зрители комнаты, введшие наш код (или хозяин комнаты), — в друзья сами.
    func adoptPeers(_ peers: [(code: String, name: String)]) {
        let fresh = peers.filter { !codes.contains($0.code) && $0.code != friendCode && $0.code != myCode }
        for peer in fresh { add(peer.code, name: peer.name) }
    }

    private func save(dirty: Bool = true) {
        if dirty { friendsDirty = true }
        defaults.set(codes, forKey: "friends.codes")
        defaults.set(names, forKey: "friends.names")
        defaults.set(friendsDirty, forKey: "friends.dirty")
    }

    // MARK: Аккаунт

    /// PIN для привязки другого устройства к этому аккаунту (10 минут); nil — сервер недоступен.
    func newLinkPin() async -> String? {
        guard let reply = try? await post(["me": myCode, "op": "link-new", "friends": codes]) else { return nil }
        let pin = reply["pin"] as? String ?? ""
        return pin.isEmpty ? nil : pin
    }

    /// Войти в аккаунт другого устройства по его PIN: свои друзья вливаются в общий список.
    func joinAccount(_ pin: String) async -> Bool {
        do {
            let reply = try await post(["me": myCode, "op": "link-join", "pin": pin.filter(\.isNumber), "friends": codes])
            guard let acc = reply["account"] as? String else { return false }
            adoptAccount(acc)
            friendsDirty = false
            adoptFriends(reply["friendList"] as? [String])
            await report()
            return true
        } catch {
            Log.note("ДРУЗЬЯ", "привязка: \(error.localizedDescription)")
            return false
        }
    }

    /// Отвязать это устройство: оно снова само себе аккаунт.
    func leaveAccount() async -> Bool {
        guard (try? await post(["me": myCode, "op": "unlink"])) != nil else { return false }
        account = myCode
        devices = []
        defaults.removeObject(forKey: "friends.account")
        return true
    }

    private func adoptAccount(_ value: String) {
        guard !value.isEmpty, value != account else { return }
        account = value
        defaults.set(value, forKey: "friends.account")
        Log.note("ДРУЗЬЯ", "аккаунт \(value)")
    }

    /// Список друзей с сервера (общий у аккаунта): заменяет свой, если своих неотправленных изменений нет.
    private func adoptFriends(_ list: [String]?) {
        guard let list, !friendsDirty else { return }
        let server = list.filter { !$0.isEmpty }.sorted()
        if server != codes {
            codes = server
            save(dirty: false)
        }
    }

    // MARK: Отчёт

    /// Сообщить сразу (смена фильма, вход в комнату) — с выдержкой 1,5 с, чтобы не слать по каждому шагу.
    private func poke() {
        guard enabled else { return }
        pokeTask?.cancel()
        pokeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            await self?.report()
        }
    }

    private func report() async {
        reportedAt = .now
        // Друзей нет — наш статус никому не нужен; устройства аккаунта отчитываются всегда (через отчёт — общий список).
        if codes.isEmpty && knockTo == nil && account == myCode && devices.isEmpty { return }
        let knockCode = knockTo
        let dirty = friendsDirty
        var body: [String: Any] = ["me": myCode, "name": Self.deviceName, "friends": codes, "friendsSet": dirty,
                                   "knock": knockCode ?? NSNull()]
        if let watching {
            body["watching"] = ["title": watching.title, "sub": watching.sub, "poster": watching.poster, "room": watching.room]
        } else {
            body["watching"] = NSNull()
        }
        do {
            let reply = try await post(body)
            next = TimeInterval(min(600, max(30, (reply["next"] as? NSNumber)?.intValue ?? 90)))
            if knockCode != nil && knockTo == knockCode { knockTo = nil }
            if let acc = reply["account"] as? String { adoptAccount(acc) }
            if dirty && reply["friendList"] != nil {
                friendsDirty = false
                save(dirty: false)
            }
            adoptFriends(reply["friendList"] as? [String])
            devices = ((reply["devices"] as? [[String: Any]]) ?? []).filter { $0["code"] as? String != myCode }.map { row in
                let name = row["name"] as? String ?? ""
                return (name.isEmpty ? row["code"] as? String ?? "" : name, row["online"] as? Bool ?? false)
            }
            if let knock = reply["knock"] as? [String: Any] {
                let from = knock["from"] as? String ?? ""
                knockFrom = from.isEmpty ? knock["code"] as? String : from
            }
            friends = ((reply["friends"] as? [[String: Any]]) ?? []).map { row in
                let w = row["watching"] as? [String: Any]
                let watching = w.map { FriendWatching(title: $0["title"] as? String ?? "", sub: $0["sub"] as? String ?? "",
                                                      poster: $0["poster"] as? String ?? "", room: $0["room"] as? String ?? "") }
                return Friend(code: row["code"] as? String ?? "", name: row["name"] as? String ?? "", online: row["online"] as? Bool ?? false,
                              watching: watching?.title.isEmpty == false ? watching : nil)
            }
        } catch {
            if !HTTP.isCancellation(error) { Log.note("ДРУЗЬЯ", "сбой: \(error.localizedDescription)") }
        }
    }

    private func post(_ body: [String: Any]) async throws -> [String: Any] {
        guard let base = BuildKeys.apiBase else { throw HTTPError.invalidResponse }
        let data = try await HTTP.postJSON(base.appending(path: "presence"), body: body, timeout: 10,
                                           headers: ["X-Aerial-Token": BuildKeys.apiToken])
        return (try? HTTP.json(data)) ?? [:]
    }
}
