import ActivityKit
import Foundation

/// Live Activity загрузки: общее для приложения и виджета (Dynamic Island и экран блокировки).
struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var fraction: Double
        /// Байт в секунду.
        var rate: Int64
        /// Сколько раздач в очереди, включая текущую.
        var left: Int
    }

    var poster: String
}
