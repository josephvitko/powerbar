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
        var macWatts: Double? = nil            // the Mac's own power (SMC system − USB-C), battery or AC
        var chip: SoCPower.Breakdown? = nil    // CPU / GPU / memory / other chip

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
    private struct Bucket {
        let start: Date
        var battery = 0.0, accessory = 0.0, wh = 0.0
        var acCount = 0, count = 0
        var mac = 0.0, macCount = 0
        var chip = SoCPower.Breakdown(), chipCount = 0
    }
    private var bucket: Bucket?

    init() {
        url = Storage.directory.appendingPathComponent("history.csv")
        load()
    }

    /// Adds a reading to the current minute, writing the previous minute out once it's complete.
    func record(_ r: BatteryReading, chip: SoCPower.Breakdown?, at date: Date = Date()) {
        let start = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
        if let b = bucket, b.start != start { flush() }
        var b = bucket ?? Bucket(start: start)
        b.battery += r.watts
        b.accessory += r.accessoryWatts
        b.acCount += r.externalConnected ? 1 : 0
        b.count += 1
        b.wh = r.remainingWh
        if let mac = r.macWatts { b.mac += mac; b.macCount += 1 }
        if let c = chip { b.chip = b.chip + c; b.chipCount += 1 }
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

    /// Writes out the partial current minute (on quit), so it isn't lost.
    func flush() {
        guard let b = bucket, b.count > 0 else { return }
        bucket = nil
        let n = Double(b.count)
        let m = Minute(date: b.start, batteryWatts: b.battery / n, accessoryWatts: b.accessory / n,
                       onAC: b.acCount * 2 >= b.count, remainingWh: b.wh,
                       macWatts: b.macCount > 0 ? b.mac / Double(b.macCount) : nil,
                       chip: b.chipCount > 0 ? b.chip * (1 / Double(b.chipCount)) : nil)
        insert(m)
        append(Self.line(m))
    }

    /// Appends a minute, merging it with the previous one if it's the same minute
    /// (the app was restarted partway through it and both halves were saved).
    private func insert(_ m: Minute) {
        guard let last = minutes.last, last.date == m.date else { minutes.append(m); return }
        func avg(_ a: Double?, _ b: Double?) -> Double? { a.flatMap { x in b.map { (x + $0) / 2 } } ?? a ?? b }
        let chip: SoCPower.Breakdown? = switch (last.chip, m.chip) {
        case let (a?, b?): (a + b) * 0.5
        case let (a, b): a ?? b
        }
        minutes[minutes.count - 1] = Minute(date: m.date, batteryWatts: (last.batteryWatts + m.batteryWatts) / 2,
                                            accessoryWatts: (last.accessoryWatts + m.accessoryWatts) / 2,
                                            onAC: last.onAC && m.onAC, remainingWh: m.remainingWh,
                                            macWatts: avg(last.macWatts, m.macWatts), chip: chip)
    }

    // time,battery,accessory,onAC,remainingWh,mac,cpu,gpu,memory,otherChip (last five may be empty)
    private static func line(_ m: Minute) -> String {
        func f(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "" }
        return String(format: "%.0f,%.2f,%.2f,%d,%.2f", m.date.timeIntervalSince1970, m.batteryWatts, m.accessoryWatts,
                      m.onAC ? 1 : 0, m.remainingWh)
            + "," + [f(m.macWatts), f(m.chip?.cpu), f(m.chip?.gpu), f(m.chip?.memory), f(m.chip?.otherChip)].joined(separator: ",")
            + "\n"
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
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count == 5 || f.count == 10, let t = Double(f[0]), let b = Double(f[1]), let a = Double(f[2]),
                  let wh = Double(f[4]) else { dropped = true; continue }
            let date = Date(timeIntervalSince1970: t)
            guard date >= cutoff else { dropped = true; continue }
            var m = Minute(date: date, batteryWatts: b, accessoryWatts: a, onAC: f[3] == "1", remainingWh: wh)
            if f.count == 10 {
                m.macWatts = Double(f[5])
                if let cpu = Double(f[6]), let gpu = Double(f[7]), let mem = Double(f[8]), let other = Double(f[9]) {
                    m.chip = SoCPower.Breakdown(cpu: cpu, gpu: gpu, memory: mem, otherChip: other)
                }
            }
            let before = minutes.count
            insert(m)
            if minutes.count == before { dropped = true }   // merged a duplicate; rewrite the file
        }
        if dropped { try? minutes.map(Self.line).joined().write(to: url, atomically: true, encoding: .utf8) }
    }
}
