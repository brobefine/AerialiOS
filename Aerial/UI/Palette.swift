import SwiftUI
import UIKit

/// Цвет постера — перенос `VodPalette` ТВ: самый частый насыщенный оттенок маленькой копии постера, доведённый до
/// яркости 160 из 255. Им окрашены кнопки страницы фильма и плеер.
enum PosterPalette {
    private static let memory = NSCache<NSString, UIColor>()

    static func cached(_ path: String) -> Color? { memory.object(forKey: path as NSString).map(Color.init) }

    static func accent(_ path: String) async -> Color? {
        guard !path.isEmpty else { return nil }
        if let cached = cached(path) { return cached }
        guard let image = await ImageLoader.shared.image(TMDbImage.urls(path, "w92"), pixelWidth: 64) else { return nil }
        let color = await Task.detached(priority: .utility) { compute(image) }.value
        guard let color else { return nil }
        memory.setObject(color, forKey: path as NSString)
        return Color(color)
    }

    private static func compute(_ image: UIImage) -> UIColor? {
        guard let cg = image.cgImage else { return nil }
        let width = 32, height = 48
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var count = [Int](repeating: 0, count: 512)
        var sums = [[Int]](repeating: [0, 0, 0], count: 512)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
            let high = max(r, g, b), low = min(r, g, b)
            // Тёмное и серое не считаем — как на ТВ.
            if pixels[index + 3] < 128 || high < 35 || high - low < 18 { continue }
            let bucket = (r >> 5) << 6 | (g >> 5) << 3 | b >> 5
            count[bucket] += 1
            sums[bucket][0] += r; sums[bucket][1] += g; sums[bucket][2] += b
        }
        guard let main = count.indices.max(by: { count[$0] < count[$1] }), count[main] > 0 else { return nil }
        let rgb = sums[main].map { Double($0) / Double(count[main]) }
        let scale = 160 / max(rgb.max() ?? 1, 1)
        return UIColor(red: rgb[0] * scale / 255, green: rgb[1] * scale / 255, blue: rgb[2] * scale / 255, alpha: 1)
    }
}

/// Оценки строкой, как `RatingsRow` ТВ: знак источника и кольцо с числом; Rotten Tomatoes — оба знака рядом и два
/// кольца. Порядок: TMDb, затем IMDb, Rotten Tomatoes, Metacritic, Letterboxd.
struct RatingsRow: View {
    let tmdb: Double
    let external: String
    /// Включённые источники MDBList (`AppSettings.ratingSources`); TMDb — всегда первым.
    var sources: Set<String> = ["imdb", "tomatoes", "metacritic", "letterboxd"]

    enum Kind: Int { case tmdb, imdb, tomato, popcorn, metacritic, letterboxd }

    struct Entry: Hashable {
        let kind: Kind
        let value: Double

        var share: Double {
            switch kind {
            case .tomato, .popcorn, .metacritic: value / 100
            case .letterboxd: value / 5
            default: value / 10
            }
        }

        var text: String {
            switch kind {
            case .tomato, .popcorn, .metacritic: String(Int(value))
            default: String(format: "%.1f", value)
            }
        }
    }

    /// Разбор строки MDBList («IMDb 7.9 · 🍅 99% · 🍿 68% · Metacritic 87»).
    static func entries(tmdb: Double, external: String) -> [Entry] {
        var list: [Entry] = tmdb > 0 ? [Entry(kind: .tmdb, value: tmdb)] : []
        for part in external.components(separatedBy: " · ") {
            let p = part.trimmingCharacters(in: .whitespaces)
            func number(_ prefix: String) -> Double? {
                Double(p.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: ""))
            }
            let entry: Entry? = if p.hasPrefix("🍅") { number("🍅").map { Entry(kind: .tomato, value: $0) } }
                else if p.hasPrefix("🍿") { number("🍿").map { Entry(kind: .popcorn, value: $0) } }
                else if p.hasPrefix("Metacritic") { number("Metacritic").map { Entry(kind: .metacritic, value: $0) } }
                else if p.hasPrefix("IMDb") { number("IMDb").map { Entry(kind: .imdb, value: $0) } }
                else if p.hasPrefix("Letterboxd") { number("Letterboxd").map { Entry(kind: .letterboxd, value: $0) } }
                else { nil }
            if let entry, entry.value > 0 { list.append(entry) }
        }
        return list.sorted { $0.kind.rawValue < $1.kind.rawValue }
    }

    var body: some View {
        let entries = Self.entries(tmdb: tmdb, external: external).filter { entry in
            switch entry.kind {
            case .tmdb: true
            case .imdb: sources.contains("imdb")
            case .tomato, .popcorn: sources.contains("tomatoes")
            case .metacritic: sources.contains("metacritic")
            case .letterboxd: sources.contains("letterboxd")
            }
        }
        let tomatoes = entries.filter { $0.kind == .tomato || $0.kind == .popcorn }
        ViewThatFits(in: .horizontal) {
            row(entries, tomatoes, ringSize: 34, badge: 22, gap: 14)
            row(entries, tomatoes, ringSize: 28, badge: 18, gap: 9)
        }
    }

    private func row(_ entries: [Entry], _ tomatoes: [Entry], ringSize: CGFloat, badge: CGFloat, gap: CGFloat) -> some View {
        HStack(spacing: gap) {
            ForEach(entries, id: \.self) { entry in
                if !(tomatoes.contains(entry) && entry != tomatoes.first) {
                    let group = tomatoes.contains(entry) ? tomatoes : [entry]
                    HStack(spacing: 5) {
                        HStack(spacing: -4) { ForEach(group, id: \.self) { Self.badge($0.kind, size: badge) } }
                        ForEach(group, id: \.self) { ring(for: $0, size: ringSize) }
                    }
                }
            }
        }
        .fixedSize()
    }

    private func ring(for entry: Entry, size: CGFloat) -> some View {
        let share = min(1, max(0, entry.share))
        let line = max(2, size * 0.09)
        return ZStack {
            Circle().fill(.black.opacity(0.35))
            Circle().stroke(.white.opacity(0.16), lineWidth: line).padding(line / 2)
            Circle()
                .trim(from: 0, to: share)
                .stroke(Theme.rating(share), style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(line / 2)
            Text(entry.text)
                .font(.aerial(size: size * 0.33, .semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder static func badge(_ kind: Kind, size: CGFloat) -> some View {
        let k = size / 26
        switch kind {
        case .tomato, .popcorn:
            Text(kind == .tomato ? "🍅" : "🍿").font(.aerial(size: 18 * k)).frame(width: size, height: size)
        case .metacritic:
            Text("m").font(.aerial(size: 13 * k, .bold)).foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Color(hex: 0x1B1B1B), in: Circle())
                .overlay(Circle().stroke(Color(hex: 0xFFCC33), lineWidth: 2 * k))
        case .imdb:
            Text("IMDb").font(.aerial(size: 8 * k, .black)).foregroundStyle(.black)
                .frame(width: size, height: size)
                .background(Color(hex: 0xF5C518), in: RoundedRectangle(cornerRadius: 4 * k))
        case .tmdb:
            Text("TMDB").font(.aerial(size: 7 * k, .black)).foregroundStyle(Color(hex: 0x01D2A0))
                .frame(width: size, height: size)
                .background(Color(hex: 0x0D253F), in: RoundedRectangle(cornerRadius: 4 * k))
        case .letterboxd:
            HStack(spacing: -2 * k) {
                ForEach([0xFF8000, 0x00E054, 0x40BCF4], id: \.self) { Circle().fill(Color(hex: UInt32($0))).frame(width: 9 * k, height: 9 * k) }
            }
            .frame(width: size, height: size)
        }
    }
}
