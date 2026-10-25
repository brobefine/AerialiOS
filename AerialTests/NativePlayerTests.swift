import AVFoundation
import Foundation
import Testing
@testable import Aerial

/// Системный плеер: перепаковка MKV в отрезки fMP4 ([Remuxer]), HLS для AVPlayer ([HLSSession]), субтитры.
/// Файлы — в `AerialTests/Media`: H.264 + AC3 (рус.) + DTS + SRT и HEVC 10 бит (открытый GOP) + E-AC3 + TrueHD + ASS.
@Suite(.serialized)
struct NativePlayerTests {
    private final class Token {}

    private func media(_ name: String) throws -> URL {
        try #require(Bundle(for: Token.self).url(forResource: name, withExtension: "mkv"))
    }

    /// Все отрезки подряд: заголовок `ftyp`+`moov`, отрезки `moof`+`mdat`, время декодирования растёт.
    private func remuxAll(_ name: String, audio: Int32?) throws -> (Remuxer, [Data]) {
        let remuxer = try Remuxer(url: try media(name), audioStream: audio)
        var segments: [Data] = []
        for index in remuxer.segments.indices {
            segments.append(try remuxer.segment(index))
        }
        return (remuxer, segments)
    }

    @Test(arguments: [("h264-ac3-dts", Int32?.none), ("h264-ac3-dts", 2), ("hevc10-eac3-truehd", nil), ("hevc10-eac3-truehd", 2)])
    func remuxesEverySegment(name: String, audio: Int32?) throws {
        let (remuxer, segments) = try remuxAll(name, audio: audio)
        #expect(remuxer.segments.count >= 2)
        #expect(abs(remuxer.segments.map(\.duration).reduce(0, +) - remuxer.duration) < 0.5)
        let header = try #require(remuxer.initSegment)
        #expect(MP4Writer.offset(of: "ftyp", in: header) == 0)
        #expect(MP4Writer.offset(of: "moov", in: header) != nil)
        var previous: UInt64?
        for (index, segment) in segments.enumerated() {
            #expect(MP4Writer.offset(of: "moof", in: segment) == 0, "отрезок \(index) не с moof")
            #expect(MP4Writer.offset(of: "mdat", in: segment) != nil, "отрезок \(index) без mdat")
            let times = Self.decodeTimes(segment)
            #expect(times.count == (remuxer.audio == nil ? 1 : 2), "отрезок \(index): дорожек \(times.count)")
            if let video = times.first {
                if let previous { #expect(video > previous, "отрезок \(index): tfdt \(video) ≤ \(previous)") }
                previous = video
            }
        }
        if let audio { #expect(remuxer.audio?.stream == audio) }
        // Русская дорожка — по умолчанию.
        if audio == nil { #expect(remuxer.audio?.lang == "rus") }
        // DTS и TrueHD — в AAC.
        if audio == 2 { #expect(remuxer.audio?.copy == false) }
    }

    /// Отрезок нового сеанса (перемотка) совпадает по времени с тем же отрезком, сделанным подряд.
    @Test(arguments: ["h264-ac3-dts", "hevc10-eac3-truehd"])
    func sessionsAgreeOnTime(name: String) throws {
        let (_, continuous) = try remuxAll(name, audio: nil)
        let jumper = try Remuxer(url: try media(name), audioStream: nil)
        let index = jumper.segments.count - 1
        let alone = try jumper.segment(index)
        let jumped = Self.decodeTimes(alone), steady = Self.decodeTimes(continuous[index])
        #expect(jumped.count == steady.count)
        // Звук — точно; видео — в пределах кадра (dts первых кадров сеанса восстановлены по частоте кадров).
        if jumped.count == 2, steady.count == 2 { #expect(jumped[1] == steady[1]) }
        if let a = jumped.first, let b = steady.first { #expect(Double(max(a, b) - min(a, b)) <= Double(b) * 0.012, "\(a) против \(b)") }
        // Заголовок от любого сеанса — один и тот же.
        let fresh = try Remuxer(url: try media(name), audioStream: nil)
        _ = try fresh.segment(0)
        #expect(fresh.initSegment == jumper.initSegment)
    }

    @Test func collectsTextSubtitles() throws {
        let (remuxer, _) = try remuxAll("h264-ac3-dts", audio: nil)
        let track = try #require(remuxer.textTracks.first)
        let cues = remuxer.cues(for: track.stream)
        #expect(cues.count == 2)
        #expect(cues.first?.text == "Первая строка")
        #expect(abs((cues.first?.start ?? 0) - 1) < 0.01)
        #expect(cues.last?.text == "Вторая\nстрока")

        let (styled, _) = try remuxAll("hevc10-eac3-truehd", audio: nil)
        let ass = try #require(styled.textTracks.first)
        #expect(styled.cues(for: ass.stream).first?.text == "Первая строка")
    }

    @Test func parsesSubtitleText() {
        #expect(SubtitleText.clean("12,0,Default,,0,0,0,,{\\i1}Привет{\\i0}\\Nмир", ass: true) == "Привет\nмир")
        #expect(SubtitleText.clean("<i>Курсив</i> <font color=\"red\">цвет</font>", ass: false) == "Курсив цвет")
        let cues = SRT.parse("1\r\n00:00:01,500 --> 00:00:03,000\r\nОдин\r\n\r\n2\r\n00:01:02,000 --> 00:01:04,250\r\n<b>Два</b>\r\n")
        #expect(cues.count == 2)
        #expect(cues.first?.start == 1.5)
        #expect(cues.last?.end == 64.25)
        #expect(cues.last?.text == "Два")
    }

    @Test func plansSegmentsByKeyframes() {
        let keys: [Int64] = [0, 2000, 4000, 6000, 8000, 10000, 12000]
        let segments = Remuxer.plan(keys: keys, end: 13000, perSecond: 1000, bitRate: 5_000_000)
        #expect(segments.map(\.start) == [0, 4000, 8000, 12000])
        #expect(segments.last?.end == 13000)
        #expect(segments.map(\.duration) == [4, 4, 4, 1])
        // Тяжёлая раздача — по 2 с.
        #expect(Remuxer.plan(keys: keys, end: 13000, perSecond: 1000, bitRate: 60_000_000).count == 7)
    }

    /// AVPlayer в симуляторе играет HLS из перепакованного MKV: готов, время идёт. H.264 + DTS → AAC — строго;
    /// HEVC 10 бит + E-AC3 — смотрим, что скажет симулятор (кодеков Dolby в нём может не быть).
    @Test(arguments: [("h264-ac3-dts", Int32(2), true), ("h264-ac3-dts", Int32(1), false), ("hevc10-eac3-truehd", Int32(2), false)])
    @MainActor
    func avPlayerPlaysRemux(name: String, audio: Int32, strict: Bool) async throws {
        let session = try await HLSSession.open(url: try media(name), audioStream: audio, start: 0)
        defer { session.close() }
        let item = AVPlayerItem(url: session.masterURL)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.play()
        var waited = 0.0
        while item.status == .unknown || player.currentTime().seconds < 2, item.status != .failed, waited < 30 {
            try await Task.sleep(for: .milliseconds(250))
            waited += 0.25
        }
        let report = "\(name) звук \(audio): статус \(item.status.rawValue), время \(player.currentTime().seconds), "
            + "ошибка \(item.error?.localizedDescription ?? "нет") \(item.errorLog()?.events.last?.errorComment ?? "")"
        print("AVPLAYER: \(report)")
        if strict {
            #expect(item.status == .readyToPlay, "\(report)")
            #expect(player.currentTime().seconds >= 2, "\(report)")
        }
        player.pause()
    }

    // MARK: Разбор fMP4

    /// `baseMediaDecodeTime` каждого `traf` во фрагменте — по порядку дорожек.
    static func decodeTimes(_ data: Data) -> [UInt64] {
        // Только первый `moof`: дальше — данные `mdat`.
        let bytes = [UInt8](data.prefix(MP4Writer.offset(of: "mdat", in: data) ?? data.count))
        var times: [UInt64] = []
        var index = 0
        let tag: [UInt8] = Array("tfdt".utf8)
        while index + 16 <= bytes.count {
            if Array(bytes[index..<index + 4]) == tag {
                let version = bytes[index + 4]
                let start = index + 8
                if version == 1, start + 8 <= bytes.count {
                    times.append(bytes[start..<start + 8].reduce(0) { $0 << 8 | UInt64($1) })
                } else if start + 4 <= bytes.count {
                    times.append(bytes[start..<start + 4].reduce(0) { $0 << 8 | UInt64($1) })
                }
                index += 4
            } else {
                index += 1
            }
        }
        return times
    }
}
