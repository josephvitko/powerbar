import Foundation

/// Per-app energy over time: every sample for the last 10 minutes in memory, and hourly
/// totals persisted as CSV (`hour,app,cpuJ,gpuJ`) for 30 days. Energy is additive, so
/// rows for the same hour (e.g. written before and after a restart) are simply summed.
final class AppHistory {
    private(set) var recent: [(date: Date, seconds: Double, apps: [String: AppEnergy])] = []
    private var hours: [Date: [String: AppEnergy]] = [:]
    private var pending: [String: AppEnergy] = [:]   // current hour, not yet written
    private var pendingHour: Date?
    private var lastWrite = Date()
    private let url: URL
    private let retention: TimeInterval = 30 * 86400
    private let recentSpan: TimeInterval = 600

    init() {
        url = Storage.directory.appendingPathComponent("apps.csv")
        load()
    }

    func add(seconds: Double, apps: [String: AppEnergy], at date: Date = Date()) {
        recent.append((date, seconds, apps))
        recent.removeAll { date.timeIntervalSince($0.date) > recentSpan }

        let hour = Self.hour(of: date)
        if pendingHour != hour { flush(); pendingHour = hour }
        for (name, e) in apps {
            pending[name, default: AppEnergy()] += e
            hours[hour, default: [:]][name, default: AppEnergy()] += e
        }
        // Write at least every 10 minutes so a crash loses little.
        if date.timeIntervalSince(lastWrite) > 600 { flush() }
    }

    /// Average watts per app over the in-memory window (since launch, up to 10 minutes).
    func recentWatts() -> (apps: [String: AppEnergy], seconds: Double) {
        var total: [String: AppEnergy] = [:]
        for r in recent { for (name, e) in r.apps { total[name, default: AppEnergy()] += e } }
        let seconds = recent.map(\.seconds).reduce(0, +)
        guard seconds > 0 else { return ([:], 0) }
        return (total.mapValues { AppEnergy(cpu: $0.cpu / seconds, gpu: $0.gpu / seconds) }, seconds)
    }

    /// Joules per app from the hour containing `date` onward.
    func energy(since date: Date) -> [String: AppEnergy] {
        let from = Self.hour(of: date)
        var total: [String: AppEnergy] = [:]
        for (hour, apps) in hours where hour >= from {
            for (name, e) in apps { total[name, default: AppEnergy()] += e }
        }
        return total
    }

    /// Writes the unsaved part of the current hour.
    func flush() {
        lastWrite = Date()
        guard let hour = pendingHour, !pending.isEmpty else { return }
        let text = pending.map { Self.line(hour, $0.key, $0.value) }.joined()
        pending = [:]
        let data = Data(text.utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private static func hour(of date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
    }

    private static func line(_ hour: Date, _ name: String, _ e: AppEnergy) -> String {
        let safe = name.replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: "\n", with: " ")
        return String(format: "%.0f,%@,%.1f,%.1f\n", hour.timeIntervalSince1970, safe, e.cpu, e.gpu)
    }

    private func load() {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let cutoff = Date().addingTimeInterval(-retention)
        var rows = 0
        for line in text.split(separator: "\n") {
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count == 4, let t = Double(f[0]), let cpu = Double(f[2]), let gpu = Double(f[3]) else { continue }
            let hour = Date(timeIntervalSince1970: t)
            guard hour >= cutoff else { continue }
            hours[hour, default: [:]][String(f[1]), default: AppEnergy()] += AppEnergy(cpu: cpu, gpu: gpu)
            rows += 1
        }
        // Compact: one row per (hour, app), expired hours dropped.
        let compacted = hours.keys.sorted().flatMap { h in hours[h]!.map { Self.line(h, $0.key, $0.value) } }
        if compacted.count != rows || text.split(separator: "\n").count != rows {
            try? compacted.joined().write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
