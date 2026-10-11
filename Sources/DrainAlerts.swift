import Foundation
import UserNotifications

/// Notifies when battery draw stays above a threshold. Fires once per episode:
/// it re-arms only after draw falls back below 80% of the threshold, and never
/// more often than `cooldown`.
final class DrainAlerts: NSObject, UNUserNotificationCenterDelegate {
    static let thresholdOptions: [Double] = [10, 15, 20, 25, 30]
    static let durationOptions: [Int] = [2, 5, 10]

    private let defaults = UserDefaults.standard
    private let cooldown: TimeInterval = 30 * 60
    private var armed = true
    private var lastFired: Date?

    /// Watts; 0 means alerts are off.
    var threshold: Double {
        get { defaults.object(forKey: "alertThreshold") as? Double ?? 15 }
        set { defaults.set(newValue, forKey: "alertThreshold"); if newValue > 0 { requestPermission() } }
    }

    var minutes: Int {
        get { defaults.object(forKey: "alertMinutes") as? Int ?? 5 }
        set { defaults.set(newValue, forKey: "alertMinutes") }
    }

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        if threshold > 0 { requestPermission() }
    }

    func evaluate(history: PowerHistory, culprit: EnergyMonitor.AppUsage?) {
        guard threshold > 0 else { return }
        let window = TimeInterval(minutes * 60)
        guard let avg = history.average(over: window, requireFullWindow: true) else {
            armed = true   // on AC or not enough data: reset the episode
            return
        }
        if avg < threshold * 0.8 { armed = true; return }
        guard armed, avg >= threshold else { return }
        if let last = lastFired, Date().timeIntervalSince(last) < cooldown { return }

        armed = false
        lastFired = Date()
        let content = UNMutableNotificationContent()
        content.title = String(format: "High battery drain: %.1f W", avg)
        var body = "Averaging \(String(format: "%.1f", avg)) W for the last \(minutes) min"
        if let c = culprit {
            var stats: [String] = []
            if let w = c.cpuWatts, w >= 0.05 { stats.append(String(format: "%.1f W CPU", w)) }
            if c.gpuPercent >= 1 { stats.append(String(format: "%.0f%% GPU", c.gpuPercent)) }
            body += " — \(c.name) is the heaviest app (\(stats.joined(separator: ", ")))."
        } else {
            body += "."
        }
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "drain", content: content, trigger: nil))
    }

    private func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // Show banners even though PowerBar counts as the active app while its menu is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
