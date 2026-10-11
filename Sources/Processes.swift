import Darwin
import Foundation

/// Helpers for naming processes, grouping helper processes under their parent app.
enum Processes {
    static func path(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    static func name(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buf, UInt32(buf.count))
        let n = String(cString: buf)
        return n.isEmpty ? "pid \(pid)" : n
    }

    static func parent(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    /// Path of the outermost `.app` bundle containing the executable, if any.
    static func appBundlePath(_ pid: pid_t) -> String? {
        guard let p = path(pid), let r = p.range(of: ".app/") else { return nil }
        return String(p[..<r.lowerBound]) + ".app"
    }

    /// The outermost `.app` bundle name in the executable path (so Firefox's
    /// `plugin-container` and Chromium's helpers count as the app itself),
    /// falling back to the process name.
    static func appName(_ pid: pid_t) -> String {
        if let p = path(pid), let r = p.range(of: ".app/") {
            return (String(p[..<r.lowerBound]) as NSString).lastPathComponent
        }
        return name(pid)
    }
}
