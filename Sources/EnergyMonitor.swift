import Darwin
import Foundation
import IOKit

/// Energy used by an app over some period, in joules.
struct AppEnergy {
    var cpu = 0.0
    var gpu = 0.0
    var total: Double { cpu + gpu }

    static func += (lhs: inout AppEnergy, rhs: AppEnergy) {
        lhs.cpu += rhs.cpu
        lhs.gpu += rhs.gpu
    }
}

/// Per-app energy between samples.
///
/// - CPU energy comes from the kernel's per-process counters (`ri_energy_nj`, the same
///   source Activity Monitor uses). Only the current user's processes are readable
///   without root, so system daemons like WindowServer have no CPU figure.
/// - GPU energy is the GPU's measured power split between apps by their share of GPU
///   busy time (`accumulatedGPUTime` per GPU client in the IORegistry, which includes
///   system processes).
///
/// Helper processes are grouped under their app (Firefox's `plugin-container` → Firefox).
final class EnergyMonitor {
    private struct Snapshot {
        let date: Date
        let energy: [pid_t: UInt64]    // nanojoules
        let gpu: [pid_t: UInt64]       // nanoseconds of GPU time
    }

    private var previous: Snapshot?
    private var names: [pid_t: String] = [:]
    private var gpuClientNames: [pid_t: String] = [:]
    private(set) var bundlePaths: [String: String] = [:]   // app name → .app path, for icons

    /// Reads all counters and returns each app's energy since the previous call
    /// (nil on the first call). `gpuWatts` is the GPU's average power over that interval.
    func sample(gpuWatts: Double?) -> (seconds: Double, apps: [String: AppEnergy])? {
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

        let current = Snapshot(date: now, energy: energy, gpu: gpu)
        defer {
            previous = current
            names = names.filter { energy[$0.key] != nil || gpu[$0.key] != nil }
        }
        guard let prev = previous else { return nil }
        let seconds = now.timeIntervalSince(prev.date)
        guard seconds > 0 else { return nil }

        // A pid missing from the previous snapshot counts from zero only if it started since then;
        // otherwise it existed but wasn't readable, and its lifetime total would be misattributed.
        func start(_ pid: pid_t, _ old: [pid_t: UInt64]) -> UInt64? {
            if let v = old[pid] { return v }
            return Processes.startTime(pid).map { $0 > prev.date ? 0 : nil } ?? nil
        }

        var apps: [String: AppEnergy] = [:]
        for (pid, e) in energy {
            guard let name = names[pid], let s = start(pid, prev.energy), e >= s else { continue }
            apps[name, default: AppEnergy()].cpu += Double(e - s) / 1e9
        }
        var busy: [String: Double] = [:]
        for (pid, t) in gpu {
            guard let name = names[pid], let s = start(pid, prev.gpu), t >= s else { continue }
            busy[name, default: 0] += Double(t - s)
        }
        let totalBusy = busy.values.reduce(0, +)
        if let gpuWatts, totalBusy > 0 {
            for (name, b) in busy { apps[name, default: AppEnergy()].gpu += gpuWatts * seconds * b / totalBusy }
        }
        return (seconds, apps.filter { $0.value.total > 0 })
    }

    // MARK: - GPU

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
