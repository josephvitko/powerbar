import Foundation

/// One-minute averages of battery power, persisted as CSV so charts and daily
/// totals survive restarts. Kept for 30 days (~2 MB).
final class HistoryStore {
    struct Minute {
        let date: Date
        let batteryWatts: Double     // >0 discharging, <0 charging
        let accessoryWatts: Double   // supplied to USB-C devices
        let onAC: Bool
        let remainingWh: Double

        /// Battery draw while unplugged; nil on AC.
        var drawWatts: Double? { onAC ? nil : max(batteryWatts, 0) }
    }

    struct Day: Identifiable {
        let date: Date
        let macWh: Double            // used from battery by the Mac itself
        let accessoryWh: Double      // used from battery to charge USB-C devices
        let batteryHours: Double     // time spent unplugged and awake
        var id: Date { date }
        var totalWh: Double { macWh + accessoryWh }
    }

    private(set) var minutes: [Minute] = []
    private let url: URL
    private let retention: TimeInterval = 30 * 86400
    private var bucket: (start: Date, battery: Double, accessory: Double, acCount: Int, count: Int, wh: Double)?

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PowerBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("history.csv")
        load()
    }

    /// Adds a reading to the current minute, writing the previous minute out once it's complete.
    func record(_ r: BatteryReading, at date: Date = Date()) {
        let start = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
        if let b = bucket, b.start != start { flush() }
        var b = bucket ?? (start, 0, 0, 0, 0, 0)
        b.battery += r.watts
        b.accessory += r.accessoryWatts
        b.acCount += r.externalConnected ? 1 : 0
        b.count += 1
        b.wh = r.remainingWh
        bucket = b
    }

    func minutes(since date: Date) -> [Minute] {
        // Minutes are chronological, so scan back from the end.
        guard let i = minutes.lastIndex(where: { $0.date < date }) else { return minutes }
        return Array(minutes[(i + 1)...])
    }

    /// Battery usage per calendar day, oldest first, ending today.
    func days(_ count: Int) -> [Day] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let first = cal.date(byAdding: .day, value: -(count - 1), to: today)!
        var byDay: [Date: (total: Double, accessory: Double, minutes: Int)] = [:]
        for m in minutes(since: first) where !m.onAC {
            let day = cal.startOfDay(for: m.date)
            var d = byDay[day] ?? (0, 0, 0)
            d.total += max(m.batteryWatts, 0) / 60
            d.accessory += m.accessoryWatts / 60
            d.minutes += 1
            byDay[day] = d
        }
        return (0..<count).map { offset in
            let day = cal.date(byAdding: .day, value: offset, to: first)!
            let d = byDay[day] ?? (0, 0, 0)
            let accessory = min(d.accessory, d.total)
            return Day(date: day, macWh: d.total - accessory, accessoryWh: accessory, batteryHours: Double(d.minutes) / 60)
        }
    }

    // MARK: - Persistence

    private func flush() {
        guard let b = bucket, b.count > 0 else { return }
        bucket = nil
        let n = Double(b.count)
        let m = Minute(date: b.start, batteryWatts: b.battery / n, accessoryWatts: b.accessory / n,
                       onAC: b.acCount * 2 >= b.count, remainingWh: b.wh)
        minutes.append(m)
        append(Self.line(m))
    }

    private static func line(_ m: Minute) -> String {
        String(format: "%.0f,%.2f,%.2f,%d,%.2f\n", m.date.timeIntervalSince1970, m.batteryWatts, m.accessoryWatts,
               m.onAC ? 1 : 0, m.remainingWh)
    }

    private func append(_ text: String) {
        let data = Data(text.utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private func load() {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let cutoff = Date().addingTimeInterval(-retention)
        var dropped = false
        for line in text.split(separator: "\n") {
            let f = line.split(separator: ",")
            guard f.count == 5, let t = Double(f[0]), let b = Double(f[1]), let a = Double(f[2]),
                  let wh = Double(f[4]) else { dropped = true; continue }
            let date = Date(timeIntervalSince1970: t)
            guard date >= cutoff else { dropped = true; continue }
            minutes.append(Minute(date: date, batteryWatts: b, accessoryWatts: a, onAC: f[3] == "1", remainingWh: wh))
        }
        if dropped { try? minutes.map(Self.line).joined().write(to: url, atomically: true, encoding: .utf8) }
    }
}
