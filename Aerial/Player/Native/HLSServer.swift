import Foundation
import Network

/// Раздача MKV плееру AVPlayer как HLS: `http://127.0.0.1:<порт>/<сеанс>/master.m3u8`, `media.m3u8`,
/// `init.mp4` и отрезки `s<n>.m4s` ([Remuxer]). Плейлист полный (VOD) — отрезки готовятся по запросу.
/// Сеанс закрывают явно ([HLSSession.release]); отпущенный живёт, пока его читают (окно PiP), и закрывается
/// через 3 мин тишины или при новом сеансе.
final class HLSServer: @unchecked Sendable {
    static let shared = HLSServer()

    private let queue = DispatchQueue(label: "aerial.hls.server")
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var sessions: [String: HLSSession] = [:]
    private let lock = NSLock()

    /// Запустить (один раз) и вернуть порт.
    func start() async throws -> UInt16 {
        if let port = lock.withLock({ listener != nil && self.port > 0 ? self.port : nil }) { return port }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = AbortFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard !resumed.value else { return }
                    resumed.value = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    guard !resumed.value else { return }
                    resumed.value = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        lock.withLock {
            self.listener = listener
            self.port = port
        }
        Log.player("HLS: сервер на 127.0.0.1:\(port)")
        return port
    }

    func register(_ session: HLSSession) {
        lock.withLock {
            // Новый просмотр — прежние отпущенные сеансы больше не нужны (окно PiP закрывается при новом плеере).
            for (id, old) in sessions where old.released {
                old.close()
                sessions[id] = nil
            }
            sessions[session.id] = session
        }
        sweepLater()
    }

    private func sweepLater() {
        queue.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self else { return }
            let stale = lock.withLock { () -> [HLSSession] in
                let stale = sessions.values.filter { $0.released && Date().timeIntervalSince($0.lastAccess) > 180 }
                stale.forEach { sessions[$0.id] = nil }
                return stale
            }
            stale.forEach { $0.close() }
            if lock.withLock({ !sessions.isEmpty }) { sweepLater() }
        }
    }

    // MARK: HTTP

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                handle(head, on: connection)
                return
            }
            if complete || error != nil || buffer.count > 64 * 1024 {
                connection.cancel()
                return
            }
            receive(connection, buffer: buffer)
        }
    }

    private func handle(_ head: String, on connection: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else {
            reply(connection, status: 405, type: "text/plain", body: Data(), range: nil, head: false)
            return
        }
        let range = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }
            .flatMap { HTTPRange(header: String($0.dropFirst("range:".count))) }
        let path = String(parts[1]).split(separator: "?").first.map(String.init) ?? ""
        let pieces = path.split(separator: "/").map(String.init)
        guard pieces.count == 2, let session = lock.withLock({ sessions[pieces[0]] }) else {
            reply(connection, status: 404, type: "text/plain", body: Data(), range: nil, head: parts[0] == "HEAD")
            return
        }
        let onlyHead = parts[0] == "HEAD"
        session.respond(to: pieces[1]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let (type, body)):
                reply(connection, status: 200, type: type, body: body, range: range, head: onlyHead)
            case .failure(let error):
                Log.player("HLS: \(pieces[1]) — \(error.localizedDescription)")
                reply(connection, status: 500, type: "text/plain", body: Data(error.localizedDescription.utf8), range: nil, head: onlyHead)
            }
        }
    }

    private func reply(_ connection: NWConnection, status: Int, type: String, body: Data, range: HTTPRange?, head: Bool) {
        var code = status
        var payload = body
        var extra = ""
        if status == 200, let range, let slice = range.slice(of: body.count) {
            code = 206
            payload = body.subdata(in: slice)
            extra = "Content-Range: bytes \(slice.lowerBound)-\(slice.upperBound - 1)/\(body.count)\r\n"
        }
        let reason = [200: "OK", 206: "Partial Content", 404: "Not Found", 405: "Method Not Allowed"][code] ?? "Error"
        let header = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(payload.count)\r\n"
            + "Accept-Ranges: bytes\r\n\(extra)Cache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
        var message = Data(header.utf8)
        if !head { message.append(payload) }
        connection.send(content: message, completion: .contentProcessed { [weak self] error in
            if error != nil {
                connection.cancel()
            } else {
                self?.receive(connection, buffer: Data())
            }
        })
    }
}

/// `Range: bytes=a-b` (одна часть).
struct HTTPRange {
    let start: Int?
    let end: Int?

    init?(header: String) {
        let value = header.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("bytes=") else { return nil }
        let bounds = value.dropFirst(6).split(separator: ",").first?.split(separator: "-", omittingEmptySubsequences: false) ?? []
        guard bounds.count == 2 else { return nil }
        start = Int(bounds[0])
        end = Int(bounds[1])
        if start == nil && end == nil { return nil }
    }

    func slice(of count: Int) -> Range<Int>? {
        guard count > 0 else { return nil }
        if let start {
            let last = min(end ?? count - 1, count - 1)
            return start <= last ? start..<(last + 1) : nil
        }
        guard let end, end > 0 else { return nil }
        return max(0, count - end)..<count
    }
}

/// Один фильм для AVPlayer: перепаковщик со своим звуком, плейлисты и последние отрезки.
/// Отрезки готовятся на своей очереди по одному; следующий за отданным готовится заранее.
final class HLSSession: @unchecked Sendable {
    let id = UUID().uuidString.lowercased()
    let remuxer: Remuxer
    private(set) var lastAccess = Date()
    private(set) var released = false
    private let queue = DispatchQueue(label: "aerial.hls.session", qos: .userInitiated)
    private var cache: [Int: Data] = [:]
    private var order: [Int] = []
    private var start: Double
    private var closed = false
    private var port: UInt16 = 0

    init(remuxer: Remuxer, start: Double) {
        self.remuxer = remuxer
        self.start = start
    }

    /// Открыть MKV (сеть — долго; вызывать не с главного потока) и зарегистрировать на сервере.
    static func open(url: URL, audioStream: Int32?, start: Double) async throws -> HLSSession {
        let port = try await HLSServer.shared.start()
        let remuxer = try await Task.detached(priority: .userInitiated) {
            try Remuxer(url: url, audioStream: audioStream)
        }.value
        let session = HLSSession(remuxer: remuxer, start: start)
        session.port = port
        HLSServer.shared.register(session)
        return session
    }

    var masterURL: URL { URL(string: "http://127.0.0.1:\(port)/\(id)/master.m3u8")! }

    /// Плеер закрыт: сеанс ещё нужен окну PiP, пока его читают.
    func release() { released = true }

    func close() {
        queue.async { [self] in
            closed = true
            cache = [:]
            remuxer.close()
        }
        remuxer.cancel()
    }

    func respond(to name: String, completion: @escaping (Result<(String, Data), Error>) -> Void) {
        lastAccess = Date()
        switch name {
        case "master.m3u8":
            completion(.success(("application/vnd.apple.mpegurl", Data(master().utf8))))
        case "media.m3u8":
            completion(.success(("application/vnd.apple.mpegurl", Data(media().utf8))))
        case "init.mp4":
            queue.async { [self] in
                completion(Result {
                    if let header = remuxer.initSegment { return ("video/mp4", header) }
                    // Заголовок появляется с первым отрезком — с того места, откуда начнётся просмотр.
                    let first = remuxer.segmentIndex(at: start)
                    _ = try segment(first)
                    guard let header = remuxer.initSegment else { throw Remuxer.Failure.broken("нет заголовка") }
                    return ("video/mp4", header)
                })
            }
        default:
            guard name.hasPrefix("s"), name.hasSuffix(".m4s"), let index = Int(name.dropFirst().dropLast(4)) else {
                completion(.failure(Remuxer.Failure.broken("нет файла \(name)")))
                return
            }
            queue.async { [self] in
                completion(Result { ("video/iso.segment", try segment(index)) })
                // Следующий — заранее, пока плеер играет этот.
                queue.async { [self] in
                    guard !closed, index + 1 < remuxer.segments.count, cache[index + 1] == nil else { return }
                    _ = try? segment(index + 1)
                }
            }
        }
    }

    /// На очереди сеанса.
    private func segment(_ index: Int) throws -> Data {
        if let data = cache[index] { return data }
        guard !closed else { throw Remuxer.Failure.broken("сеанс закрыт") }
        let data = try remuxer.segment(index)
        cache[index] = data
        order.append(index)
        // Держим два последних: отрезок 4К — десятки мегабайт.
        while order.count > 2 { cache[order.removeFirst()] = nil }
        return data
    }

    private func master() -> String {
        let fps = String(format: "%.3f", remuxer.frameRate)
        return """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-STREAM-INF:BANDWIDTH=\(max(remuxer.bitRate, 500_000)),RESOLUTION=\(remuxer.width)x\(remuxer.height),FRAME-RATE=\(fps),VIDEO-RANGE=\(remuxer.videoRange)
        media.m3u8

        """
    }

    private func media() -> String {
        let target = Int((remuxer.segments.map(\.duration).max() ?? 4).rounded(.up))
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(target)", "#EXT-X-MEDIA-SEQUENCE:0",
                     "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-INDEPENDENT-SEGMENTS"]
        if start > 1 { lines.append(String(format: "#EXT-X-START:TIME-OFFSET=%.3f,PRECISE=YES", start)) }
        lines.append("#EXT-X-MAP:URI=\"init.mp4\"")
        for (index, segment) in remuxer.segments.enumerated() {
            lines.append(String(format: "#EXTINF:%.6f,", segment.duration))
            lines.append("s\(index).m4s")
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }
}
