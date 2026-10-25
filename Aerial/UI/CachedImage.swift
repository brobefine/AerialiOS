import ImageIO
import SwiftUI
import UIKit

/// Загрузка картинок: память (NSCache) → диск (URLCache 512 МБ) → сеть; официальный CDN, затем Worker.
/// Картинка уменьшается до нужной ширины при декодировании (ImageIO) — постер w500 в ряду не держит лишнюю память.
final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()

    private let memory = NSCache<NSString, UIImage>()
    private let session: URLSession

    private init() {
        memory.totalCostLimit = 160 << 20
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 512 << 20,
                                   directory: URL.cachesDirectory.appending(path: "images"))
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 12
        session = URLSession(configuration: config)
    }

    func cached(_ urls: [URL], pixelWidth: Int) -> UIImage? {
        guard let first = urls.first else { return nil }
        return memory.object(forKey: key(first, pixelWidth))
    }

    func image(_ urls: [URL], pixelWidth: Int) async -> UIImage? {
        guard let first = urls.first else { return nil }
        let key = key(first, pixelWidth)
        if let image = memory.object(forKey: key) { return image }
        for url in urls {
            guard let loaded = try? await session.data(from: url),
                  (loaded.1 as? HTTPURLResponse)?.statusCode == 200,
                  let image = Self.decode(loaded.0, pixelWidth: pixelWidth) else { continue }
            memory.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
            return image
        }
        return nil
    }

    /// Свернули — картинки в памяти отпускаем (диск остаётся): меньше памяти у спящего процесса, ниже риск выгрузки.
    func trimMemory() { memory.removeAllObjects() }

    func clear() {
        memory.removeAllObjects()
        session.configuration.urlCache?.removeAllCachedResponses()
    }

    private func key(_ url: URL, _ width: Int) -> NSString { "\(width)|\(url.absoluteString)" as NSString }

    private static func decode(_ data: Data, pixelWidth: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, pixelWidth),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// Картинка TMDb по пути и размеру; до загрузки — подложка цвета карточки.
struct CachedImage: View {
    let urls: [URL]
    var pixelWidth: Int = 600
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?

    init(path: String, size: String, pixelWidth: Int = 600, contentMode: ContentMode = .fill) {
        urls = TMDbImage.urls(path, size)
        self.pixelWidth = pixelWidth
        self.contentMode = contentMode
        _image = State(initialValue: ImageLoader.shared.cached(urls, pixelWidth: pixelWidth))
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: urls.first) {
            if let hit = ImageLoader.shared.cached(urls, pixelWidth: pixelWidth) {
                image = hit
                return
            }
            if let loaded = await ImageLoader.shared.image(urls, pixelWidth: pixelWidth) {
                withAnimation(.easeOut(duration: 0.2)) { image = loaded }
            }
        }
    }
}
