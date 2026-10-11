import Foundation
import IOKit.pwr_mgt

/// An app currently holding a power assertion that stops the Mac or display from sleeping.
struct SleepBlocker: Identifiable {
    let app: String
    let reason: String
    let blocksDisplay: Bool
    var id: String { "\(app)|\(reason)|\(blocksDisplay)" }

    private static let displayTypes: Set<String> = ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]
    private static let systemTypes: Set<String> = [
        "PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion",
    ]
    // System processes whose assertions are routine (display-on, Handoff, input activity).
    // corespeechd is "Hey Siri" listening via the mic.
    private static let ignoredProcesses: Set<String> = [
        "powerd", "WindowServer", "sharingd", "useractivityd", "corespeechd",
    ]

    static func current() -> [SleepBlocker] {
        var cf: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&cf) == kIOReturnSuccess,
              let byPid = cf?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }

        var result: [SleepBlocker] = []
        for (pidNum, assertions) in byPid {
            for a in assertions {
                let type = (a["AssertionTrueType"] as? String) ?? (a["AssertType"] as? String) ?? ""
                let display = displayTypes.contains(type)
                guard display || systemTypes.contains(type) else { continue }
                let owner = pid_t(truncating: pidNum)
                // Root-owned processes can't be named via libproc, so prefer the assertion's own record.
                let ownerName = (a["Process Name"] as? String) ?? Processes.name(owner)
                if ignoredProcesses.contains(ownerName) { continue }

                // coreaudiod holds assertions on behalf of whichever app is playing/recording.
                let onBehalf = (a["AssertionOnBehalfOfPID"] as? NSNumber).map { pid_t(truncating: $0) }
                if let pid = onBehalf, ignoredProcesses.contains(Processes.name(pid)) { continue }
                let resources = (a["ResourcesUsed"] as? [String]) ?? []
                let reason: String
                if resources.contains(where: { $0.hasPrefix("audio-in") }) {
                    reason = "using the microphone"
                } else if resources.contains(where: { $0.hasPrefix("audio-out") }) {
                    reason = "audio output open"
                } else if ownerName == "cameracaptured" {
                    reason = "camera in use"
                } else if ownerName == "caffeinate" {
                    reason = "preventing idle sleep"
                } else {
                    reason = describe(a["AssertName"] as? String) ?? type
                }
                let app = onBehalf.map { label(for: $0) } ?? label(for: owner, fallback: ownerName)
                result.append(SleepBlocker(app: app, reason: reason, blocksDisplay: display))
            }
        }
        // Collapse duplicates (e.g. several audio assertions from one app).
        var seen = Set<String>()
        return result
            .sorted { ($0.blocksDisplay ? 0 : 1, $0.app) < ($1.blocksDisplay ? 0 : 1, $1.app) }
            .filter { seen.insert($0.id).inserted }
    }

    /// Makes assertion names readable: drops UUIDs and names common system ones.
    private static func describe(_ name: String?) -> String? {
        guard let name else { return nil }
        let cleaned = name.replacingOccurrences(
            of: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
            with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if cleaned.hasPrefix("NSURLSessionTask") { return "background network transfer" }
        return cleaned.isEmpty ? nil : "“\(cleaned)”"
    }

    /// App name, attributing command-line tools like `caffeinate` to whatever launched them.
    private static func label(for pid: pid_t, fallback: String? = nil) -> String {
        var app = Processes.appName(pid)
        if let fallback, app.hasPrefix("pid ") { app = fallback }
        guard app == "caffeinate", let parent = Processes.parent(pid), parent > 1 else { return app }
        return "caffeinate (via \(Processes.appName(parent)))"
    }
}
