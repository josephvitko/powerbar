import Foundation

/// Low Power Mode schedule, mirroring System Settings ▸ Battery ▸ Low Power Mode.
/// Reading is unprivileged; changing it runs `pmset` via the standard admin prompt.
enum LowPowerMode: CaseIterable {
    case never, onBattery, always

    var title: String {
        switch self {
        case .never: "Never"
        case .onBattery: "Only on Battery"
        case .always: "Always"
        }
    }

    /// Whether Low Power Mode is in effect right now.
    static var isActive: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    /// Current schedule, or nil for a combination not offered here (e.g. only on power adapter).
    static func current() -> LowPowerMode? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["-g", "custom"]
        let pipe = Pipe()
        task.standardOutput = pipe
        guard (try? task.run()) != nil else { return nil }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        task.waitUntilExit()

        // Sections look like "Battery Power:" / "AC Power:" followed by " powermode  1".
        var section = "", battery = false, ac = false
        for line in out.split(separator: "\n") {
            if line.hasSuffix(":") { section = String(line); continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2, parts[0] == "powermode" || parts[0] == "lowpowermode" else { continue }
            let low = parts[1] == "1"
            if section.hasPrefix("Battery") { battery = low } else if section.hasPrefix("AC") { ac = low }
        }
        switch (battery, ac) {
        case (false, false): return .never
        case (true, false): return .onBattery
        case (true, true): return .always
        default: return nil
        }
    }

    /// Applies the schedule. Prompts for an admin password; returns false if cancelled or failed.
    @discardableResult
    func apply() -> Bool {
        let (battery, ac) = switch self {
        case .never: (0, 0)
        case .onBattery: (1, 0)
        case .always: (1, 1)
        }
        let cmd = "/usr/bin/pmset -b lowpowermode \(battery) && /usr/bin/pmset -c lowpowermode \(ac)"
        // Run via osascript (a separate, Apple-signed process) for the standard admin prompt;
        // this works the same under the hardened runtime as in a dev build.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "do shell script \"\(cmd)\" with administrator privileges "
                          + "with prompt \"PowerBar wants to change Low Power Mode.\""]
        guard (try? task.run()) != nil else { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }
}
