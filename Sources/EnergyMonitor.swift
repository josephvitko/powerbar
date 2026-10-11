import Darwin
import Foundation
import IOKit

/// Per-app CPU power and GPU usage.
///
/// - CPU watts come from the kernel's per-process energy counters (`ri_energy_nj`,
///   the same source Activity Monitor uses). Only the current user's processes are
///   readable without root, so system daemons like WindowServer have no CPU figure.
/// - GPU % comes from each GPU client's `accumulatedGPUTime` in the IORegistry, which
///   includes system processes. macOS doesn't expose per-app GPU *power*.
///
/// Neither covers the display backlight, which is often the largest single draw.
final class EnergyMonitor {
    struct AppUsage: Identifiable {
        let name: String
        let bundlePath: String?  // for the app icon
        let cpuWatts: Double?   // nil if unreadable (other users' processes)
        let gpuPercent: Double
        let gpuWatts: Double?   // the app's share of measured GPU power, when available
        var id: String { name }
    }

    private struct Snapshot {
        let date: Date
        let energy: [pid_t: UInt64]    // nanojoules
        let gpu: [pid_t: UInt64]       // nanoseconds of GPU time
    }

    /// Latest counters per pid, kept after a process exits so its energy still counts
    /// toward the window it ran in (short-lived builds and scripts would otherwise vanish).
    private struct LastSeen {
        var date: Date
        var energy: UInt64?
        var gpu: UInt64?
    }

    private var snapshots: [Snapshot] = []
    private var lastSeen: [pid_t: LastSeen] = [:]
    private var names: [pid_t: String] = [:]
    private var bundlePaths: [String: String] = [:]   // app name → .app path
    private let window: TimeInterval

    // Fallback ranking weight when GPU power isn't measured: treat 10% GPU busy as ~1 W.
    private let gpuWattsPerPercent = 0.1

    init(window: TimeInterval = 60) { self.window = window }

    /// True once there are two snapshots to diff.
    var hasData: Bool { snapshots.count >= 2 }

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
            if names[pid] == nil {
                let name = Processes.appName(pid)
                names[pid] = name
                if bundlePaths[name] == nil, let path = Processes.appBundlePath(pid) { bundlePaths[name] = path }
            }
        }

        let gpu = gpuTimes()
        for pid in gpu.keys where names[pid] == nil || names[pid]!.hasPrefix("pid ") {
            names[pid] = gpuClientNames[pid] ?? Processes.appName(pid)
        }

        for (pid, e) in energy { lastSeen[pid, default: LastSeen(date: now)].energy = e; lastSeen[pid]!.date = now }
        for (pid, t) in gpu { lastSeen[pid, default: LastSeen(date: now)].gpu = t; lastSeen[pid]!.date = now }

        snapshots.append(Snapshot(date: now, energy: energy, gpu: gpu))
        // Keep the newest snapshot that is at least `window` old as the baseline.
        while snapshots.count > 2, now.timeIntervalSince(snapshots[1].date) >= window { snapshots.removeFirst() }
        // Forget processes that exited before the window began.
        if let baseline = snapshots.first?.date {
            lastSeen = lastSeen.filter { $0.value.date > baseline }
            names = names.filter { lastSeen[$0.key] != nil }
        }
    }

    /// Apps with notable CPU power or GPU use over the window, heaviest first. Given the GPU's
    /// measured power, each app is assigned a share of it in proportion to its GPU busy time.
    func topApps(_ n: Int, gpuPower: Double? = nil, minimumWatts: Double = 0.05, minimumGPU: Double = 1) -> [AppUsage] {
        guard let old = snapshots.first, let new = snapshots.last, new.date > old.date else { return [] }
        let dt = new.date.timeIntervalSince(old.date)
        var cpu: [String: Double] = [:], gpu: [String: Double] = [:]
        for (pid, seen) in lastSeen {
            guard let name = names[pid] else { continue }
            // Counters start at zero, so a process born mid-window counts from 0.
            if let e = seen.energy {
                let start = old.energy[pid] ?? 0
                if e >= start { cpu[name, default: 0] += Double(e - start) / 1e9 / dt }
            }
            if let t = seen.gpu {
                let start = old.gpu[pid] ?? 0
                if t >= start { gpu[name, default: 0] += Double(t - start) / 1e9 / dt * 100 }
            }
        }
        let gpuBusy = gpu.values.reduce(0, +)
        return Set(cpu.keys).union(gpu.keys)
            .map { name -> AppUsage in
                let pct = gpu[name] ?? 0
                let watts = gpuPower.flatMap { gpuBusy > 0 ? $0 * pct / gpuBusy : nil }
                return AppUsage(name: name, bundlePath: bundlePaths[name], cpuWatts: cpu[name], gpuPercent: pct, gpuWatts: watts)
            }
            .filter { ($0.cpuWatts ?? 0) >= minimumWatts || ($0.gpuWatts.map { $0 >= minimumWatts } ?? ($0.gpuPercent >= minimumGPU)) }
            .sorted { score($0) > score($1) }
            .prefix(n)
            .map { $0 }
    }

    private func score(_ u: AppUsage) -> Double { (u.cpuWatts ?? 0) + (u.gpuWatts ?? u.gpuPercent * gpuWattsPerPercent) }

    // MARK: - GPU

    private var gpuClientNames: [pid_t: String] = [:]

    /// Sums `accumulatedGPUTime` across every GPU user client, keyed by owning pid.
    private func gpuTimes() -> [pid_t: UInt64] {
        var out: [pid_t: UInt64] = [:]
        var accels: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &accels) == KERN_SUCCESS
        else { return out }
        defer { IOObjectRelease(accels) }

        while case let accel = IOIteratorNext(accels), accel != 0 {
            defer { IOObjectRelease(accel) }
            var clients: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accel, kIOServicePlane, &clients) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(clients) }
            while case let client = IOIteratorNext(clients), client != 0 {
                defer { IOObjectRelease(client) }
                func prop(_ key: String) -> Any? {
                    IORegistryEntryCreateCFProperty(client, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                }
                // e.g. "pid 395, WindowServer"
                guard let creator = prop("IOUserClientCreator") as? String,
                      let usage = prop("AppUsage") as? [[String: Any]] else { continue }
                let parts = creator.dropFirst(4).split(separator: ",", maxSplits: 1)
                guard creator.hasPrefix("pid "), let pid = pid_t(parts.first ?? "") else { continue }
                if parts.count == 2 { gpuClientNames[pid] = parts[1].trimmingCharacters(in: .whitespaces) }
                out[pid, default: 0] += usage.compactMap { ($0["accumulatedGPUTime"] as? NSNumber)?.uint64Value }.reduce(0, +)
            }
        }
        gpuClientNames = gpuClientNames.filter { out[$0.key] != nil }
        return out
    }
}
