import Foundation
import IOKit

/// A single reading from the AppleSmartBattery IOKit service.
struct BatteryReading {
    let watts: Double          // >0 discharging, <0 charging
    let accessoryWatts: Double // power the Mac is supplying to USB-C devices (e.g. charging a phone)
    let percent: Int
    let minutesLeft: Int?      // nil while calculating / on AC
    let externalConnected: Bool
    let isCharging: Bool
    let adapterWatts: Int?
    let healthPercent: Int
    let cycles: Int
    let tempC: Double

    static func read() -> BatteryReading? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let p = unmanaged?.takeRetainedValue() as? [String: Any] else { return nil }

        func int(_ k: String) -> Int { (p[k] as? NSNumber)?.intValue ?? 0 }
        let amps = Double((p["InstantAmperage"] as? NSNumber)?.int64Value ?? 0) / 1000
        let volts = Double(int("Voltage")) / 1000
        let external = (p["ExternalConnected"] as? Bool) ?? false
        let avgTTE = int("AvgTimeToEmpty")
        let adapter = (p["AdapterDetails"] as? [String: Any])?["Watts"] as? NSNumber
        let design = max(int("DesignCapacity"), 1)
        // One entry per USB-C port; "Watts" is in milliwatts.
        let portsOut = (p["PowerOutDetails"] as? [[String: Any]]) ?? []
        let accessoryMilliwatts = portsOut.compactMap { ($0["Watts"] as? NSNumber)?.doubleValue }.reduce(0, +)

        return BatteryReading(
            watts: -amps * volts,
            accessoryWatts: accessoryMilliwatts / 1000,
            percent: int("CurrentCapacity"),
            minutesLeft: (!external && avgTTE > 0 && avgTTE < 65535) ? avgTTE : nil,
            externalConnected: external,
            isCharging: (p["IsCharging"] as? Bool) ?? false,
            adapterWatts: adapter?.intValue,
            // NominalChargeCapacity is what System Settings' "Maximum Capacity" is based on.
            healthPercent: Int((Double(int("NominalChargeCapacity")) / Double(design) * 100).rounded()),
            cycles: int("CycleCount"),
            tempC: Double(int("Temperature")) / 100
        )
    }
}

/// Rolling history of battery discharge watts. `nil` entries mark time spent on AC.
struct PowerHistory {
    private(set) var samples: [(date: Date, watts: Double?)] = []
    let span: TimeInterval

    init(span: TimeInterval) { self.span = span }

    mutating func append(_ watts: Double?, at date: Date = Date()) {
        samples.append((date, watts))
        samples.removeAll { date.timeIntervalSince($0.date) > span }
    }

    /// Average over the window, or nil if any of it was on AC or history doesn't cover it yet.
    func average(over seconds: TimeInterval, requireFullWindow: Bool = false) -> Double? {
        guard let last = samples.last?.date else { return nil }
        let window = samples.filter { last.timeIntervalSince($0.date) <= seconds }
        if requireFullWindow, let first = window.first, last.timeIntervalSince(first.date) < seconds * 0.9 { return nil }
        let vals = window.compactMap(\.watts)
        guard !vals.isEmpty, vals.count == window.count else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }
}
