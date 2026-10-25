import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Libswresample

/// Сборщик фрагментов MP4 (FFmpeg `mov`) в память: после [write] пакетов отрезка [flush] отдаёт `moof` + `mdat`;
/// заголовок (`ftyp` + `moov`) пишется при первом сбросе и лежит в [header].
/// `frag_discont` без списка правок — `tfdt` равен абсолютному времени декодирования (см. [Remuxer]).
final class MP4Writer {
    enum Stream {
        /// Поток как есть: параметры из MKV, единицы времени источника, метка образца (`hvc1`/`dvh1`, 0 — сам).
        case copy(UnsafeMutablePointer<AVCodecParameters>?, AVRational, tag: UInt32)
        /// Поток кодировщика (AAC из [AudioTranscoder]).
        case encoded(UnsafeMutablePointer<AVCodecContext>)
    }

    private(set) var header: Data?
    private var context: UnsafeMutablePointer<AVFormatContext>?
    private let sink = DataSink()
    private var sources: [AVRational] = []

    init(streams: [Stream], dropDolbyVision: Bool) throws {
        var created: UnsafeMutablePointer<AVFormatContext>?
        let allocated = avformat_alloc_output_context2(&created, nil, "mp4", nil)
        guard allocated >= 0, let context = created else { throw Remuxer.Failure.broken("mp4: \(Remuxer.text(allocated))") }
        self.context = context
        for stream in streams {
            guard let out = avformat_new_stream(context, nil), let par = out.pointee.codecpar else {
                throw Remuxer.Failure.broken("mp4: поток")
            }
            switch stream {
            case .copy(let source, let base, let tag):
                let copied = avcodec_parameters_copy(par, source)
                guard copied >= 0 else { throw Remuxer.Failure.broken("mp4: параметры \(Remuxer.text(copied))") }
                par.pointee.codec_tag = tag
                if dropDolbyVision, par.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
                    av_packet_side_data_remove(par.pointee.coded_side_data, &par.pointee.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF)
                }
                out.pointee.time_base = base
                sources.append(base)
            case .encoded(let encoder):
                let copied = avcodec_parameters_from_context(par, encoder)
                guard copied >= 0 else { throw Remuxer.Failure.broken("mp4: параметры AAC \(Remuxer.text(copied))") }
                out.pointee.time_base = encoder.pointee.time_base
                sources.append(encoder.pointee.time_base)
            }
        }
        let size = 256 * 1024
        guard let buffer = av_malloc(size) else { throw Remuxer.Failure.broken("mp4: нет памяти") }
        let io = avio_alloc_context(buffer.assumingMemoryBound(to: UInt8.self), Int32(size), 1,
                                    Unmanaged.passUnretained(sink).toOpaque(), nil, { opaque, data, length in
            guard let opaque, let data, length > 0 else { return length }
            Unmanaged<DataSink>.fromOpaque(opaque).takeUnretainedValue().data.append(data, count: Int(length))
            return length
        }, nil)
        guard let io else {
            av_free(buffer)
            throw Remuxer.Failure.broken("mp4: avio")
        }
        context.pointee.pb = io
        // `dvcC`/`dvvC` (Dolby Vision) пишется только с «неофициальной» строгостью; сдвиг отметок к нулю — выключен.
        context.pointee.strict_std_compliance = -1
        context.pointee.avoid_negative_ts = 0
        var options: OpaquePointer?
        av_dict_set(&options, "movflags", "frag_custom+empty_moov+delay_moov+default_base_moof+frag_discont+skip_sidx+skip_trailer", 0)
        av_dict_set(&options, "use_editlist", "0", 0)
        let written = avformat_write_header(context, &options)
        av_dict_free(&options)
        guard written >= 0 else { throw Remuxer.Failure.broken("mp4: заголовок \(Remuxer.text(written))") }
    }

    deinit {
        guard let context else { return }
        if let io = context.pointee.pb {
            av_free(io.pointee.buffer)
            var pointer: UnsafeMutablePointer<AVIOContext>? = io
            avio_context_free(&pointer)
            context.pointee.pb = nil
        }
        avformat_free_context(context)
    }

    /// Следующий фрагмент — с абсолютным временем первого кадра в `tfdt` (флаг `frag_discont` сбрасывается сам).
    func discontinuity() {
        guard let context else { return }
        av_opt_set(context.pointee.priv_data, "movflags", "+frag_discont", 0)
    }

    /// Пакет потока `stream` во фрагмент: отметки — из единиц источника в единицы дорожки MP4.
    func write(_ packet: UnsafeMutablePointer<AVPacket>, stream: Int) throws {
        guard let context, let out = context.pointee.streams[stream] else { throw Remuxer.Failure.broken("mp4: закрыт") }
        av_packet_rescale_ts(packet, sources[stream], out.pointee.time_base)
        packet.pointee.stream_index = Int32(stream)
        packet.pointee.pos = -1
        let written = av_write_frame(context, packet)
        if written < 0 { throw Remuxer.Failure.broken("mp4: пакет \(Remuxer.text(written))") }
    }

    /// Закрыть фрагмент: всё, что записано с прошлого сброса. Первый сброс пишет только `moov` (`delay_moov`) —
    /// поэтому сбрасываем дважды и отрезаем заголовок.
    func flush() throws -> Data {
        guard let context else { throw Remuxer.Failure.broken("mp4: закрыт") }
        av_write_frame(context, nil)
        if header == nil { av_write_frame(context, nil) }
        avio_flush(context.pointee.pb)
        var data = sink.data
        sink.data = Data()
        if header == nil, let split = Self.offset(of: "moof", in: data) {
            header = data.prefix(split)
            data = data.suffix(from: split)
        }
        return Data(data)
    }

    /// Начало первого бокса `type` верхнего уровня.
    static func offset(of type: String, in data: Data) -> Int? {
        let bytes = [UInt8](data)
        let code = Array(type.utf8)
        var position = 0
        while position + 8 <= bytes.count {
            var size = Int(bytes[position]) << 24 | Int(bytes[position + 1]) << 16 | Int(bytes[position + 2]) << 8 | Int(bytes[position + 3])
            if Array(bytes[position + 4..<position + 8]) == code { return position }
            if size == 1, position + 16 <= bytes.count {
                size = bytes[position + 8..<position + 16].reduce(0) { $0 << 8 | Int($1) }
            }
            guard size >= 8 else { return nil }
            position += size
        }
        return nil
    }
}

/// Куда `avio` складывает байты MP4.
final class DataSink {
    var data = Data()
}

/// Звук, которого нет в HLS у Apple (DTS, TrueHD, FLAC, Opus, MP3…), — в AAC стерео 192 кбит/с: декодер FFmpeg →
/// пересэмплирование в float planar → очередь по 1024 отсчёта → кодировщик AAC. Отметки — по счёту отсчётов от
/// первого кадра сеанса; новый сеанс (перемотка) — новый перекодировщик.
final class AudioTranscoder {
    let encoder: UnsafeMutablePointer<AVCodecContext>
    private var decoder: UnsafeMutablePointer<AVCodecContext>?
    private var resampler: OpaquePointer?
    private var fifo: OpaquePointer?
    private let rate: Int32
    private var nextPts = Int64.min
    private let base: AVRational

    init(_ source: UnsafeMutablePointer<AVCodecParameters>?, base: AVRational) throws {
        self.base = base
        guard let source, let codec = avcodec_find_decoder(source.pointee.codec_id),
              let decoder = avcodec_alloc_context3(codec) else { throw Remuxer.Failure.unsupported("нет декодера звука") }
        self.decoder = decoder
        avcodec_parameters_to_context(decoder, source)
        decoder.pointee.pkt_timebase = base
        let opened = avcodec_open2(decoder, codec, nil)
        guard opened >= 0 else { throw Remuxer.Failure.broken("декодер звука: \(Remuxer.text(opened))") }

        guard let aac = avcodec_find_encoder(AV_CODEC_ID_AAC), let encoder = avcodec_alloc_context3(aac) else {
            throw Remuxer.Failure.unsupported("нет кодировщика AAC")
        }
        self.encoder = encoder
        let input = decoder.pointee.sample_rate
        rate = input == 44100 || input == 48000 ? input : 48000
        encoder.pointee.sample_fmt = AV_SAMPLE_FMT_FLTP
        encoder.pointee.sample_rate = rate
        av_channel_layout_default(&encoder.pointee.ch_layout, 2)
        encoder.pointee.bit_rate = 192_000
        encoder.pointee.time_base = AVRational(num: 1, den: rate)
        encoder.pointee.flags |= 1 << 22 // AV_CODEC_FLAG_GLOBAL_HEADER: AudioSpecificConfig — в `esds`
        let ready = avcodec_open2(encoder, aac, nil)
        guard ready >= 0 else { throw Remuxer.Failure.broken("AAC: \(Remuxer.text(ready))") }

        var swr: OpaquePointer?
        let configured = swr_alloc_set_opts2(&swr, &encoder.pointee.ch_layout, AV_SAMPLE_FMT_FLTP, rate,
                                             &decoder.pointee.ch_layout, decoder.pointee.sample_fmt, input, 0, nil)
        guard configured >= 0, let swr, swr_init(swr) >= 0 else { throw Remuxer.Failure.broken("пересэмплирование") }
        resampler = swr
        fifo = av_audio_fifo_alloc(AV_SAMPLE_FMT_FLTP, 2, 4096)
    }

    deinit {
        if let fifo { av_audio_fifo_free(fifo) }
        var swr = resampler
        swr_free(&swr)
        var decoder = self.decoder
        avcodec_free_context(&decoder)
        var encoder: UnsafeMutablePointer<AVCodecContext>? = self.encoder
        avcodec_free_context(&encoder)
    }

    /// Пакет источника → готовые пакеты AAC (в единицах `1/rate`). Пакеты освобождает вызывающий.
    func feed(_ packet: UnsafeMutablePointer<AVPacket>) throws -> [UnsafeMutablePointer<AVPacket>] {
        guard let decoder else { return [] }
        if avcodec_send_packet(decoder, packet) < 0 { return [] }
        try drainDecoder()
        return try encodeQueued(final: false)
    }

    /// Конец файла: остаток очереди и хвост кодировщика.
    func flush() throws -> [UnsafeMutablePointer<AVPacket>] {
        guard let decoder else { return [] }
        avcodec_send_packet(decoder, nil)
        try drainDecoder()
        var packets = try encodeQueued(final: true)
        avcodec_send_frame(encoder, nil)
        packets += receivePackets()
        return packets
    }

    private func drainDecoder() throws {
        guard let decoder, let resampler, let fifo, let frame = av_frame_alloc() else { return }
        var decoded: UnsafeMutablePointer<AVFrame>? = frame
        defer { av_frame_free(&decoded) }
        while avcodec_receive_frame(decoder, frame) >= 0 {
            if nextPts == Int64.min {
                let start = frame.pointee.best_effort_timestamp != Int64.min ? frame.pointee.best_effort_timestamp : frame.pointee.pts
                nextPts = start == Int64.min ? 0 : av_rescale_q(start, base, AVRational(num: 1, den: rate))
            }
            guard let converted = av_frame_alloc() else { return }
            var out: UnsafeMutablePointer<AVFrame>? = converted
            converted.pointee.sample_rate = rate
            converted.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
            av_channel_layout_copy(&converted.pointee.ch_layout, &encoder.pointee.ch_layout)
            if swr_convert_frame(resampler, converted, frame) >= 0, converted.pointee.nb_samples > 0 {
                let planes = UnsafeRawPointer(converted.pointee.extended_data).assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
                av_audio_fifo_write(fifo, planes, converted.pointee.nb_samples)
            }
            av_frame_free(&out)
            av_frame_unref(frame)
        }
    }

    private func encodeQueued(final: Bool) throws -> [UnsafeMutablePointer<AVPacket>] {
        guard let fifo else { return [] }
        let size = encoder.pointee.frame_size > 0 ? encoder.pointee.frame_size : 1024
        var packets: [UnsafeMutablePointer<AVPacket>] = []
        while av_audio_fifo_size(fifo) >= size || (final && av_audio_fifo_size(fifo) > 0) {
            let count = min(size, av_audio_fifo_size(fifo))
            guard let frame = av_frame_alloc() else { break }
            var owned: UnsafeMutablePointer<AVFrame>? = frame
            frame.pointee.nb_samples = count
            frame.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
            frame.pointee.sample_rate = rate
            av_channel_layout_copy(&frame.pointee.ch_layout, &encoder.pointee.ch_layout)
            guard av_frame_get_buffer(frame, 0) >= 0 else {
                av_frame_free(&owned)
                break
            }
            let planes = UnsafeRawPointer(frame.pointee.extended_data).assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
            av_audio_fifo_read(fifo, planes, count)
            frame.pointee.pts = nextPts
            nextPts += Int64(count)
            avcodec_send_frame(encoder, frame)
            av_frame_free(&owned)
            packets += receivePackets()
        }
        return packets
    }

    private func receivePackets() -> [UnsafeMutablePointer<AVPacket>] {
        var packets: [UnsafeMutablePointer<AVPacket>] = []
        while let packet = av_packet_alloc() {
            if avcodec_receive_packet(encoder, packet) < 0 {
                var unused: UnsafeMutablePointer<AVPacket>? = packet
                av_packet_free(&unused)
                break
            }
            packets.append(packet)
        }
        return packets
    }
}
