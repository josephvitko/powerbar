import Darwin
import Foundation

/// Per-app power, from the kernel's per-process energy counters (`ri_energy_nj`,
/// the same source Activity Monitor uses). Only processes owned by the current
/// user are readable without root, so system daemons like WindowServer are absent.
final class EnergyMonitor {
    private var snapshots: [(date: Date, energy: [pid_t: UInt64])] = []
    private var names: [pid_t: String] = [:]
    private let window: TimeInterval

    init(window: TimeInterval = 30) { self.window = window }

    func sample() {
        let now = Date()
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var energy: [pid_t: UInt64] = [:]
        for pid in pids.prefix(max(count, 0)) where pid > 0 {
            var info = rusage_info_v6()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) == 0
                }
            }
            guard ok else { continue }
            energy[pid] = info.ri_energy_nj
            if names[pid] == nil { names[pid] = Processes.appName(pid) }
        }
        names = names.filter { energy[$0.key] != nil }
        snapshots.append((now, energy))
        // Keep the newest snapshot that is at least `window` old as the baseline.
        while snapshots.count > 2, now.timeIntervalSince(snapshots[1].date) >= window { snapshots.removeFirst() }
    }

    /// Average watts per app over the window, highest first.
    func topApps(_ n: Int, minimumWatts: Double = 0.05) -> [(name: String, watts: Double)] {
        guard let old = snapshots.first, let new = snapshots.last, new.date > old.date else { return [] }
        let dt = new.date.timeIntervalSince(old.date)
        var byApp: [String: Double] = [:]
        for (pid, e) in new.energy {
            guard let prev = old.energy[pid], e >= prev, let name = names[pid] else { continue }
            byApp[name, default: 0] += Double(e - prev) / 1e9 / dt
        }
        return byApp.filter { $0.value >= minimumWatts }
            .sorted { $0.value > $1.value }
            .prefix(n)
            .map { ($0.key, $0.value) }
    }
}
