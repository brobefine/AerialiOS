import ActivityKit
import Foundation

/// Загрузка в Dynamic Island и на экране блокировки (Live Activity, виджет `AerialWidgets`): название, доля, скорость.
/// Обновляется не чаще раза в 2 с — чаще iOS всё равно не покажет, а каждое обновление стоит батареи.
@MainActor
final class DownloadLive {
    static let shared = DownloadLive()

    private var activity: Activity<DownloadActivityAttributes>?
    private var updated = Date.distantPast

    func show(_ job: DownloadJob, done: Int64, rate: Int64, left: Int) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = DownloadActivityAttributes.ContentState(
            title: job.item.title, fraction: job.totalBytes > 0 ? min(1, Double(done) / Double(job.totalBytes)) : 0,
            rate: rate, left: max(1, left))
        if let activity {
            guard Date().timeIntervalSince(updated) >= 2 else { return }
            updated = Date()
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
        } else {
            updated = Date()
            do {
                activity = try Activity.request(attributes: DownloadActivityAttributes(poster: job.item.poster),
                                                content: ActivityContent(state: state, staleDate: nil))
            } catch {
                Log.note("ЗАГРУЗКА", "Live Activity: \(error.localizedDescription)")
            }
        }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
