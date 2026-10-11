import Foundation

/// Power of the Apple Silicon chip's parts (CPU, GPU, memory, …), from the IOReport
/// "Energy Model" counters — the same source `powermetrics` uses, but readable
/// without root. IOReport is a private framework, loaded at runtime; if it's
/// missing or changes shape, this simply reports nothing.
final class SoCPower {
    struct Breakdown {
        var cpu = 0.0, gpu = 0.0, memory = 0.0, otherChip = 0.0   // watts
        var total: Double { cpu + gpu + memory + otherChip }
    }

    private typealias CopyChannels = @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubscription = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary,
        UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> OpaquePointer?
    private typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias SamplesDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias IntegerValue = @convention(c) (CFDictionary, Int32) -> Int64

    private var createSamples: CreateSamples?
    private var samplesDelta: SamplesDelta?
    private var channelName: ChannelString?
    private var unitLabel: ChannelString?
    private var integerValue: IntegerValue?
    private var subscription: OpaquePointer?
    private var channels: CFMutableDictionary?

    private var previous: (date: Date, sample: CFDictionary)?
    private var history: [(date: Date, seconds: Double, breakdown: Breakdown)] = []
    private let span: TimeInterval = 120

    init() {
        guard let lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return }
        func sym<T>(_ name: String, _: T.Type) -> T? { dlsym(lib, name).map { unsafeBitCast($0, to: T.self) } }
        guard let copy = sym("IOReportCopyChannelsInGroup", CopyChannels.self),
              let subscribe = sym("IOReportCreateSubscription", CreateSubscription.self),
              let all = copy("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else { return }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let sub = subscribe(nil, all, &subscribed, 0, nil), let subbed = subscribed?.takeRetainedValue() else { return }
        subscription = sub
        channels = subbed
        createSamples = sym("IOReportCreateSamples", CreateSamples.self)
        samplesDelta = sym("IOReportCreateSamplesDelta", SamplesDelta.self)
        channelName = sym("IOReportChannelGetChannelName", ChannelString.self)
        unitLabel = sym("IOReportChannelGetUnitLabel", ChannelString.self)
        integerValue = sym("IOReportSimpleGetIntegerValue", IntegerValue.self)
    }

    var isAvailable: Bool { subscription != nil }

    func sample() {
        guard let sub = subscription, let channels, let createSamples, let samplesDelta,
              let current = createSamples(sub, channels, nil)?.takeRetainedValue() else { return }
        let now = Date()
        defer { previous = (now, current) }
        guard let prev = previous, let delta = samplesDelta(prev.sample, current, nil)?.takeRetainedValue() else { return }
        let seconds = now.timeIntervalSince(prev.date)
        guard seconds > 0.5 else { return }
        history.append((now, seconds, breakdown(delta, seconds: seconds)))
        history.removeAll { now.timeIntervalSince($0.date) > span }
    }

    /// Time-weighted average over the last `seconds`.
    func average(over seconds: TimeInterval) -> Breakdown? {
        let now = Date()
        let window = history.filter { now.timeIntervalSince($0.date) <= seconds }
        let total = window.map(\.seconds).reduce(0, +)
        guard total > 0 else { return nil }
        var b = Breakdown()
        for w in window {
            let f = w.seconds / total
            b.cpu += w.breakdown.cpu * f
            b.gpu += w.breakdown.gpu * f
            b.memory += w.breakdown.memory * f
            b.otherChip += w.breakdown.otherChip * f
        }
        return b
    }

    // Top-level Energy Model channels. Per-cluster/per-core channels (EACC_CPU0, PCPUDTL…)
    // are components of "CPU Energy", so they're skipped to avoid double counting.
    private static let memoryChannels: Set<String> = ["DRAM", "AMCC", "DCS"]
    private static let otherChipChannels: Set<String> = ["ANE", "ISP", "AVE", "AFR", "MSR", "DISP", "DISPEXT"]

    private func breakdown(_ delta: CFDictionary, seconds: Double) -> Breakdown {
        var b = Breakdown()
        guard let list = (delta as NSDictionary)["IOReportChannels"] as? [CFDictionary],
              let channelName, let unitLabel, let integerValue else { return b }
        for ch in list {
            guard let name = channelName(ch)?.takeUnretainedValue() as String? else { continue }
            let unit = (unitLabel(ch)?.takeUnretainedValue() as String? ?? "").trimmingCharacters(in: .whitespaces)
            let scale: Double = switch unit {
            case "mJ": 1e-3
            case "uJ", "µJ": 1e-6
            case "nJ": 1e-9
            default: 0
            }
            let watts = Double(integerValue(ch, 0)) * scale / seconds
            if name == "CPU Energy" { b.cpu += watts }
            else if name == "GPU Energy" { b.gpu += watts }
            else if Self.memoryChannels.contains(name) { b.memory += watts }
            else if Self.otherChipChannels.contains(name) { b.otherChip += watts }
        }
        return b
    }
}
