import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Libswresample

/// Перепаковка MKV в отрезки fMP4 для HLS — видео без перекодирования (тот же HEVC/H.264, с Dolby Vision и HDR),
/// звук AAC/AC3/E-AC3 как есть, остальной (DTS, TrueHD, FLAC, Opus…) — в AAC стерео. Субтитры-текст — в [cues].
///
/// Отрезки — по ключевым кадрам из индекса MKV (Cues), поэтому их границы и длительности известны заранее и плейлист
/// сразу полный (VOD): AVPlayer перематывает куда угодно, а мы готовим нужный отрезок по запросу. Готовим подряд
/// одним «сеансом» (демультиплексор и сборщик MP4 живут дальше): так у звука нет щелчков на стыках, а отметки
/// декодирования непрерывны. Запросили отрезок не по порядку — сеанс начинается заново с его ключевого кадра.
///
/// Время: у MKV есть только время показа (pts); время декодирования (dts) считаем сами — то же время показа,
/// отсортированное и задержанное на глубину переупорядочивания кадров `reorder`. Чтобы dts в начале файла не ушли
/// в минус, всё сдвигается на `shift` (доли секунды) — одинаково для всех отрезков. `tfdt` фрагментов — абсолютное
/// время (флаг `frag_discont` без списка правок), поэтому отрезки разных сеансов стыкуются.
/// Не потокобезопасен: все вызовы — с одной очереди ([HLSSession]).
final class Remuxer {
    enum Failure: LocalizedError {
        case open(String), unsupported(String), broken(String)

        var errorDescription: String? {
            switch self {
            case .open(let text): "открыть: \(text)"
            case .unsupported(let text): "не подходит для системного плеера: \(text)"
            case .broken(let text): "перепаковка: \(text)"
            }
        }
    }

    struct AudioTrack: Sendable {
        let stream: Int32
        let codec: String
        let title: String
        let lang: String
        let channels: Int
        /// Кладётся как есть; иначе — перекодируется в AAC.
        let copy: Bool
    }

    struct TextTrack: Sendable {
        let stream: Int32
        let codec: String
        let title: String
        let lang: String
    }

    struct Cue: Sendable {
        let start: Double
        let end: Double
        let text: String
    }

    struct Segment: Sendable {
        /// Начало — ключевой кадр, в единицах времени видеопотока.
        let start: Int64
        let end: Int64
        let duration: Double
    }

    let duration: Double
    let segments: [Segment]
    let audioTracks: [AudioTrack]
    let textTracks: [TextTrack]
    let width: Int
    let height: Int
    let videoCodec: String
    /// «PQ», «HLG» или «SDR» — для `VIDEO-RANGE` в плейлисте.
    let videoRange: String
    let frameRate: Double
    let bitRate: Int
    /// Звук, который сейчас кладётся в отрезки (номер потока MKV); nil — без звука.
    let audio: AudioTrack?
    /// Субтитры, встреченные при перепаковке: номер потока → реплики. Пополняется по мере подготовки отрезков на
    /// очереди сеанса, читается плеером с главного потока — под замком.
    private var cueStore: [Int32: [Cue]] = [:]
    private let cueLock = NSLock()

    func cues(for stream: Int32) -> [Cue] { cueLock.withLock { cueStore[stream] ?? [] } }

    /// Отрезок fMP4 без заголовка (`moof` + `mdat`) и общий заголовок (`ftyp` + `moov`) — после первого отрезка.
    private(set) var initSegment: Data?

    private var input: UnsafeMutablePointer<AVFormatContext>?
    private let abort = AbortFlag()
    private let videoIndex: Int32
    private let videoBase: AVRational
    private let frameTicks: Int64
    /// Длительность кадра точно (у MKV миллисекунды, кадр 24 к/с — 41,67): сдвиг и первые dts сеанса — без округлений.
    private let frameLength: Double
    private let reorder: Int
    private let shift: Int64
    private var dovi: Int = -1

    // Сеанс: следующий отрезок, отложенные пакеты следующего отрезка, сборщик MP4 и перекодировщик звука.
    private var next = -1
    private var held: [UnsafeMutablePointer<AVPacket>] = []
    private var output: MP4Writer?
    private var transcoder: AudioTranscoder?
    private var window: [Int64] = []
    private var lastDts = Int64.min
    private var emitted = 0

    init(url: URL, audioStream: Int32?) throws {
        var context = avformat_alloc_context()
        guard context != nil else { throw Failure.open("нет памяти") }
        context!.pointee.interrupt_callback = AVIOInterruptCB(callback: { opaque in
            guard let opaque else { return 0 }
            return Unmanaged<AbortFlag>.fromOpaque(opaque).takeUnretainedValue().value ? 1 : 0
        }, opaque: Unmanaged.passUnretained(abort).toOpaque())
        var options: OpaquePointer?
        // TorrServer отдаёт раздачу медленно и с паузами: ждём долго, обрывы — переподключение.
        av_dict_set(&options, "rw_timeout", "90000000", 0)
        av_dict_set(&options, "reconnect", "1", 0)
        av_dict_set(&options, "reconnect_on_network_error", "1", 0)
        let source = url.isFileURL ? url.path : url.absoluteString
        let opened = avformat_open_input(&context, source, nil, &options)
        av_dict_free(&options)
        guard opened >= 0, let input = context else { throw Failure.open(Self.text(opened)) }
        self.input = input
        input.pointee.probesize = 5_000_000
        input.pointee.max_analyze_duration = 3_000_000
        let info = avformat_find_stream_info(input, nil)
        guard info >= 0 else {
            Self.close(input)
            self.input = nil
            throw Failure.open(Self.text(info))
        }
        let format = String(cString: input.pointee.iformat.pointee.name)
        guard format.contains("matroska") else {
            Self.close(input)
            self.input = nil
            throw Failure.unsupported("контейнер \(format)")
        }

        let video = av_find_best_stream(input, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard video >= 0, let stream = input.pointee.streams[Int(video)], let par = stream.pointee.codecpar else {
            Self.close(input)
            self.input = nil
            throw Failure.unsupported("нет видео")
        }
        let codec = par.pointee.codec_id
        guard codec == AV_CODEC_ID_HEVC || codec == AV_CODEC_ID_H264 else {
            let name = String(cString: avcodec_get_name(codec))
            Self.close(input)
            self.input = nil
            throw Failure.unsupported("видео \(name)")
        }
        videoIndex = video
        videoBase = stream.pointee.time_base
        videoCodec = String(cString: avcodec_get_name(codec))
        width = Int(par.pointee.width)
        height = Int(par.pointee.height)
        let trc = par.pointee.color_trc
        videoRange = trc == AVCOL_TRC_SMPTE2084 ? "PQ" : trc == AVCOL_TRC_ARIB_STD_B67 ? "HLG" : "SDR"
        let rate = stream.pointee.avg_frame_rate.num > 0 ? stream.pointee.avg_frame_rate : stream.pointee.r_frame_rate
        frameRate = rate.num > 0 && rate.den > 0 ? Double(rate.num) / Double(rate.den) : 24
        // Длительность кадра в единицах видеопотока (у MKV обычно миллисекунды).
        frameLength = Double(videoBase.den) / Double(max(1, videoBase.num)) / frameRate
        frameTicks = max(1, Int64(frameLength.rounded()))
        reorder = max(Int(par.pointee.video_delay), 3) + 1
        shift = Int64((frameLength * Double(reorder)).rounded())
        if let side = av_packet_side_data_get(par.pointee.coded_side_data, par.pointee.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF) {
            dovi = Int(UnsafeRawPointer(side.pointee.data).assumingMemoryBound(to: AVDOVIDecoderConfigurationRecord.self).pointee.dv_profile)
        }
        duration = input.pointee.duration > 0 ? Double(input.pointee.duration) / 1_000_000 : 0
        bitRate = input.pointee.bit_rate > 0 ? Int(input.pointee.bit_rate) : 8_000_000

        var audios: [AudioTrack] = []
        var texts: [TextTrack] = []
        for index in 0..<Int(input.pointee.nb_streams) {
            guard let candidate = input.pointee.streams[index], let cpar = candidate.pointee.codecpar else { continue }
            let title = Self.tag(candidate, "title")
            let lang = Self.tag(candidate, "language")
            let name = String(cString: avcodec_get_name(cpar.pointee.codec_id))
            switch cpar.pointee.codec_type {
            case AVMEDIA_TYPE_AUDIO:
                let id = cpar.pointee.codec_id
                let copy = id == AV_CODEC_ID_AAC || id == AV_CODEC_ID_AC3 || id == AV_CODEC_ID_EAC3
                let decodable = copy || avcodec_find_decoder(id) != nil
                guard decodable else { continue }
                audios.append(AudioTrack(stream: Int32(index), codec: name, title: title, lang: lang,
                                         channels: Int(cpar.pointee.ch_layout.nb_channels), copy: copy))
            case AVMEDIA_TYPE_SUBTITLE:
                let id = cpar.pointee.codec_id
                guard id == AV_CODEC_ID_SUBRIP || id == AV_CODEC_ID_ASS || id == AV_CODEC_ID_SSA || id == AV_CODEC_ID_TEXT
                        || id == AV_CODEC_ID_WEBVTT || id == AV_CODEC_ID_MOV_TEXT else { continue }
                texts.append(TextTrack(stream: Int32(index), codec: name, title: title, lang: lang))
            default:
                break
            }
        }
        audioTracks = audios
        textTracks = texts
        audio = audioStream.flatMap { wanted in audios.first { $0.stream == wanted } } ?? Self.defaultAudio(audios, input)

        // Индекс ключевых кадров — из Cues в конце файла: MKV читает их при первой перемотке.
        av_seek_frame(input, video, 0, AVSEEK_FLAG_BACKWARD)
        var keys: [Int64] = []
        let count = avformat_index_get_entries_count(stream)
        for entry in 0..<count {
            guard let item = avformat_index_get_entry(stream, entry) else { continue }
            let time = item.pointee.timestamp
            if time >= 0, keys.last.map({ time > $0 }) ?? true { keys.append(time) }
        }
        let end = Int64((duration * Double(videoBase.den) / Double(max(1, videoBase.num))).rounded())
        segments = Self.plan(keys: keys, end: end, perSecond: Double(videoBase.den) / Double(max(1, videoBase.num)), bitRate: bitRate)
        guard !segments.isEmpty, duration > 0 else {
            Self.close(input)
            self.input = nil
            throw Failure.unsupported("нет индекса ключевых кадров")
        }
        if let longest = segments.map(\.duration).max(), longest > 30 {
            Self.close(input)
            self.input = nil
            throw Failure.unsupported(String(format: "ключевые кадры редко (%.0f с)", longest))
        }
    }

    deinit { close() }

    /// Прервать чтение сети (закрытие плеера) — ждущий вызов вернётся с ошибкой.
    func cancel() { abort.value = true }

    func close() {
        abort.value = true
        resetSession()
        if let input { Self.close(input) }
        input = nil
    }

    /// Номер отрезка с этим временем (с).
    func segmentIndex(at seconds: Double) -> Int {
        let ticks = Int64(seconds * Double(videoBase.den) / Double(max(1, videoBase.num)))
        return max(0, (segments.lastIndex { $0.start <= ticks } ?? 0))
    }

    /// Следующий отрезок сеанса — его [segment] сделает без перемотки.
    var upcoming: Int { next }

    /// Отрезок `index`: подряд за прошлым — продолжая сеанс, иначе — новым сеансом с его ключевого кадра.
    func segment(_ index: Int) throws -> Data {
        guard input != nil, segments.indices.contains(index) else { throw Failure.broken("нет отрезка \(index)") }
        if index != next || output == nil { try startSession(at: index) }
        return try produce()
    }

    // MARK: Сеанс

    private func startSession(at index: Int) throws {
        guard let input else { throw Failure.broken("закрыт") }
        resetSession()
        let target = segments[index].start
        let sought = av_seek_frame(input, videoIndex, target, AVSEEK_FLAG_BACKWARD)
        if sought < 0 { throw Failure.broken("перемотка: \(Self.text(sought))") }
        var streams: [MP4Writer.Stream] = []
        guard let video = input.pointee.streams[Int(videoIndex)] else { throw Failure.broken("нет видео") }
        streams.append(.copy(video.pointee.codecpar, video.pointee.time_base, tag: videoTag(video.pointee.codecpar)))
        if let audio, let stream = input.pointee.streams[Int(audio.stream)] {
            if audio.copy {
                streams.append(.copy(stream.pointee.codecpar, stream.pointee.time_base, tag: 0))
            } else {
                let transcoder = try AudioTranscoder(stream.pointee.codecpar, base: stream.pointee.time_base)
                self.transcoder = transcoder
                streams.append(.encoded(transcoder.encoder))
            }
        }
        output = try MP4Writer(streams: streams, dropDolbyVision: dovi == 7)
        next = index
    }

    private func resetSession() {
        held.forEach { var packet: UnsafeMutablePointer<AVPacket>? = $0; av_packet_free(&packet) }
        held = []
        output = nil
        transcoder = nil
        window = []
        lastDts = Int64.min
        emitted = 0
        next = -1
    }

    /// Следующий отрезок сеанса: видео — от его ключевого кадра до следующего (в порядке декодирования), звук — пока
    /// время звука не дойдёт до конца отрезка (звук в MKV лежит с небольшим опережением или отставанием от видео).
    private func produce() throws -> Data {
        guard let input, let output else { throw Failure.broken("нет сеанса") }
        let index = next
        let segment = segments[index]
        // Каждый отрезок — со своим абсолютным `tfdt`: иначе сборщик считал бы его суммой длительностей кадров,
        // а округления миллисекунд MKV за фильм набегали бы в секунды.
        output.discontinuity()
        let last = index == segments.count - 1
        let audioBase = audio.flatMap { input.pointee.streams[Int($0.stream)]?.pointee.time_base } ?? AVRational(num: 1, den: 1000)
        let audioEnd = av_rescale_q(segment.end, videoBase, audioBase)
        // Звук раньше начала отрезка — прошлому отрезку (после перемотки MKV отдаёт его с начала кластера).
        let audioStart = index == 0 ? Int64.min : av_rescale_q(segment.start, videoBase, audioBase)
        var videoDone = false
        var audioDone = audio == nil
        var sawVideo = false
        var pending = held
        held = []
        while !(videoDone && audioDone) {
            let packet: UnsafeMutablePointer<AVPacket>
            if !pending.isEmpty {
                packet = pending.removeFirst()
            } else {
                guard let fresh = av_packet_alloc() else { throw Failure.broken("нет памяти") }
                let read = av_read_frame(input, fresh)
                if read < 0 {
                    var dead: UnsafeMutablePointer<AVPacket>? = fresh
                    av_packet_free(&dead)
                    if read == Self.eof { break }
                    throw Failure.broken("чтение: \(Self.text(read))")
                }
                packet = fresh
            }
            var keep = false
            let stream = packet.pointee.stream_index
            if stream == videoIndex {
                let key = packet.pointee.flags & 1 != 0
                if videoDone {
                    held.append(packet)
                    keep = true
                } else if sawVideo, key, !last, packet.pointee.pts != Self.noTime, packet.pointee.pts >= segment.end {
                    // Ключевой кадр следующего отрезка: он и всё за ним — следующему.
                    videoDone = true
                    held.append(packet)
                    keep = true
                } else if packet.pointee.pts != Self.noTime {
                    sawVideo = true
                    try writeVideo(packet, to: output)
                }
            } else if let audio, stream == audio.stream {
                if audioDone || (!last && packet.pointee.pts != Self.noTime && packet.pointee.pts >= audioEnd) {
                    audioDone = true
                    held.append(packet)
                    keep = true
                } else if packet.pointee.pts != Self.noTime, packet.pointee.pts >= audioStart {
                    try writeAudio(packet, base: audioBase, to: output)
                }
            } else if textTracks.contains(where: { $0.stream == stream }) {
                collectCue(packet, stream: stream)
            }
            if !keep {
                var done: UnsafeMutablePointer<AVPacket>? = packet
                av_packet_free(&done)
            }
        }
        held += pending
        if last, let transcoder { try writeEncoded(transcoder.flush(), to: output) }
        let data = try output.flush()
        if initSegment == nil, let header = output.header { initSegment = header }
        next = index + 1
        emitted += 1
        return data
    }

    /// dts — время показа, отсортированное и задержанное на `reorder` кадров; первые кадры сеанса — раньше первого
    /// на целые кадры. Плюс общий сдвиг `shift`.
    private func writeVideo(_ packet: UnsafeMutablePointer<AVPacket>, to output: MP4Writer) throws {
        let pts = packet.pointee.pts
        window.append(pts)
        window.sort()
        var dts: Int64
        if window.count > reorder {
            dts = window.removeFirst()
        } else {
            dts = (window.first ?? pts) - Int64((frameLength * Double(reorder - window.count + 1)).rounded())
        }
        if lastDts != Int64.min, dts <= lastDts { dts = lastDts + 1 }
        if dts > pts { dts = pts }
        guard lastDts == Int64.min || dts > lastDts else { return }
        lastDts = dts
        packet.pointee.pts = pts + shift
        packet.pointee.dts = dts + shift
        if packet.pointee.duration <= 0 { packet.pointee.duration = frameTicks }
        try output.write(packet, stream: 0)
    }

    private func writeAudio(_ packet: UnsafeMutablePointer<AVPacket>, base: AVRational, to output: MP4Writer) throws {
        let offset = av_rescale_q(shift, videoBase, base)
        if let transcoder {
            try writeEncoded(transcoder.feed(packet), to: output)
        } else {
            packet.pointee.pts += offset
            packet.pointee.dts = packet.pointee.pts
            try output.write(packet, stream: 1)
        }
    }

    /// Пакеты AAC перекодировщика — со сдвигом `shift`; освобождаются здесь.
    private func writeEncoded(_ packets: [UnsafeMutablePointer<AVPacket>], to output: MP4Writer) throws {
        guard let transcoder else { return }
        let encodedShift = av_rescale_q(shift, videoBase, transcoder.encoder.pointee.time_base)
        defer { packets.forEach { var done: UnsafeMutablePointer<AVPacket>? = $0; av_packet_free(&done) } }
        for packet in packets {
            packet.pointee.pts += encodedShift
            packet.pointee.dts += encodedShift
            try output.write(packet, stream: 1)
        }
    }

    private func collectCue(_ packet: UnsafeMutablePointer<AVPacket>, stream: Int32) {
        guard let input, let source = input.pointee.streams[Int(stream)], packet.pointee.pts != Self.noTime,
              let bytes = packet.pointee.data, packet.pointee.size > 0 else { return }
        let base = source.pointee.time_base
        let seconds = { (value: Int64) in Double(value) * Double(base.num) / Double(base.den) }
        let start = seconds(packet.pointee.pts)
        let end = start + max(0.5, seconds(packet.pointee.duration))
        let raw = String(decoding: UnsafeBufferPointer(start: bytes, count: Int(packet.pointee.size)), as: UTF8.self)
        let codec = source.pointee.codecpar.pointee.codec_id
        let text = SubtitleText.clean(raw, ass: codec == AV_CODEC_ID_ASS || codec == AV_CODEC_ID_SSA)
        guard !text.isEmpty else { return }
        cueLock.withLock {
            var list = cueStore[stream] ?? []
            guard !list.contains(where: { abs($0.start - start) < 0.01 && $0.text == text }) else { return }
            let place = list.firstIndex { $0.start > start } ?? list.count
            list.insert(Cue(start: start, end: end, text: text), at: place)
            cueStore[stream] = list
        }
    }

    /// HEVC — `hvc1` (AVPlayer не берёт `hev1`), Dolby Vision profile 5 — `dvh1`; profile 7 (два слоя) VideoToolbox
    /// не умеет — играем базовый слой HDR10 без описания Dolby Vision ([MP4Writer] его убирает).
    private func videoTag(_ par: UnsafeMutablePointer<AVCodecParameters>?) -> UInt32 {
        guard par?.pointee.codec_id == AV_CODEC_ID_HEVC else { return 0 }
        return dovi == 5 ? Self.fourcc("dvh1") : Self.fourcc("hvc1")
    }

    // MARK: План отрезков

    /// Отрезки по 4 с (у тяжёлых раздач — по 2 с: меньше памяти на отрезок) из ключевых кадров; у последнего конец — файла.
    static func plan(keys: [Int64], end: Int64, perSecond: Double, bitRate: Int) -> [Segment] {
        guard let first = keys.first, end > first else { return [] }
        let target = Int64((bitRate > 30_000_000 ? 2.0 : 4.0) * perSecond)
        var segments: [Segment] = []
        var start = first
        for key in keys.dropFirst() where key - start >= target && key < end {
            segments.append(Segment(start: start, end: key, duration: Double(key - start) / perSecond))
            start = key
        }
        segments.append(Segment(start: start, end: end, duration: Double(end - start) / perSecond))
        return segments
    }

    private static func defaultAudio(_ audios: [AudioTrack], _ input: UnsafeMutablePointer<AVFormatContext>) -> AudioTrack? {
        let best = av_find_best_stream(input, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        let russian = audios.first { ["ru", "rus"].contains($0.lang.lowercased()) }
        return russian ?? audios.first { $0.stream == best } ?? audios.first
    }

    // MARK: Мелочи FFmpeg

    static let noTime = Int64.min
    /// `AVERROR_EOF` — макрос FFmpeg, в Swift недоступен: −'EOF '.
    static let eof: Int32 = -0x2046_4F45

    static func fourcc(_ code: String) -> UInt32 {
        code.utf8.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }

    static func text(_ code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        av_strerror(code, &buffer, buffer.count)
        return String(cString: buffer)
    }

    private static func tag(_ stream: UnsafeMutablePointer<AVStream>, _ key: String) -> String {
        guard let entry = av_dict_get(stream.pointee.metadata, key, nil, 0), let value = entry.pointee.value else { return "" }
        return String(cString: value)
    }

    private static func close(_ input: UnsafeMutablePointer<AVFormatContext>) {
        var context: UnsafeMutablePointer<AVFormatContext>? = input
        avformat_close_input(&context)
    }
}

/// Флаг прерывания чтения сети для `interrupt_callback` FFmpeg (зовётся из потока чтения).
final class AbortFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}

/// Текст реплики: SubRip — без тегов `<i>` и подобных; ASS — поле текста после восьми запятых, без `{\…}`.
enum SubtitleText {
    static func clean(_ raw: String, ass: Bool) -> String {
        var text = raw
        if ass {
            // Строка блока MKV: ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text.
            let parts = text.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
            if parts.count == 9 { text = String(parts[8]) }
            text = text.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\h", with: " ")
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
