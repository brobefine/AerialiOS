import ActivityKit
import SwiftUI
import WidgetKit

/// Виджет Aerial: только Live Activity загрузки — Dynamic Island и экран блокировки.
@main
struct AerialWidgets: WidgetBundle {
    var body: some Widget {
        DownloadActivityWidget()
    }
}

private let accent = Color(red: 0x7F / 255, green: 0xDC / 255, blue: 0xFF / 255)

struct DownloadActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            // Экран блокировки и баннер.
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(accent)
                    Text(context.state.title).font(.headline).lineLimit(1)
                    Spacer()
                    Text(percent(context.state.fraction)).font(.headline.monospacedDigit())
                }
                ProgressView(value: context.state.fraction).tint(accent)
                Text(detail(context.state)).font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            .activityBackgroundTint(Color.black.opacity(0.6))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(percent(context.state.fraction)).font(.title3.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        ProgressView(value: context.state.fraction).tint(accent)
                        Text(detail(context.state)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(accent)
            } compactTrailing: {
                Text(percent(context.state.fraction)).font(.caption.monospacedDigit()).foregroundStyle(accent)
            } minimal: {
                ProgressView(value: context.state.fraction).progressViewStyle(.circular).tint(accent)
            }
        }
    }

    private func percent(_ fraction: Double) -> String { "\(Int(fraction * 100)) %" }

    private func detail(_ state: DownloadActivityAttributes.ContentState) -> String {
        let speed = ByteCountFormatter.string(fromByteCount: state.rate, countStyle: .file) + "/с"
        return state.left > 1 ? "\(speed) · в очереди ещё \(state.left - 1)" : speed
    }
}
