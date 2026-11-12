import Foundation
import IOKit

/// One core's clock over the last sampling interval.
struct CoreFrequency: Equatable, Sendable {
    /// Share of the interval the core wasn't idle, 0–1.
    let activeFraction: Double
    /// Average frequency while active, weighted by time at each step; nil if never active.
    let averageMHz: Double?

    /// "3.4 GHz", "820 MHz", or "idle" for a core that never left idle.
    var text: String {
        guard let mhz = averageMHz else { return "idle" }
        return Self.text(mhz: mhz)
    }

    static func text(mhz: Double) -> String {
        mhz >= 1000 ? String(format: "%.1f GHz", mhz / 1000) : "\(Int(mhz.rounded())) MHz"
    }
}

/// The pure arithmetic, kept apart from the private API so it is testable.
enum CPUFrequencyMath {
    /// One core from its state residencies: index 0 is IDLE, then one entry per step of
    /// `table` (MHz), in order. Nil when the counts don't line up: a mismatch would make
    /// every figure silently wrong, so it shows nothing instead.
    static func core(residencies: [Int64], table: [Double]) -> CoreFrequency? {
        guard residencies.count == table.count + 1, residencies.allSatisfy({ $0 >= 0 }) else { return nil }
        let total = residencies.reduce(0, +)
        guard total > 0 else { return nil }
        let active = Array(residencies.dropFirst())
        let activeTotal = active.reduce(0, +)
        let weighted = zip(active, table).reduce(0.0) { $0 + Double($1.0) * $1.1 }
        return CoreFrequency(activeFraction: Double(activeTotal) / Double(total),
                             averageMHz: activeTotal > 0 ? weighted / Double(activeTotal) : nil)
    }

    /// The average clock of a group of cores, weighted by how active each was, so an idle
    /// core's last step doesn't count as much as a busy core's. Nil when none were active.
    static func groupAverageMHz(_ cores: [CoreFrequency]) -> Double? {
        let active = cores.compactMap { core in core.averageMHz.map { (mhz: $0, weight: core.activeFraction) } }
        let weight = active.reduce(0) { $0 + $1.weight }
        guard weight > 0 else { return nil }
        return active.reduce(0) { $0 + $1.mhz * $1.weight } / weight
    }

    /// A device-tree `voltage-states…-sram` table: 8-byte entries whose first little-endian
    /// UInt32 is the frequency in Hz.
    static func megahertz(fromVoltageStates data: Data) -> [Double] {
        stride(from: 0, to: data.count - 7, by: 8).map { offset in
            let hz = data[data.startIndex + offset ..< data.startIndex + offset + 4]
                .enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
            return Double(hz) / 1_000_000
        }
    }

    /// "ECPU0" → "E1", "PCPU5" → "P6": the same labels the core grid uses.
    static func label(forChannel name: String) -> String? {
        guard name.count > 4, let kind = name.first, kind == "E" || kind == "P",
              name.dropFirst().hasPrefix("CPU"), let index = Int(name.dropFirst(4)) else { return nil }
        return "\(kind)\(index + 1)"
    }
}

/// Per-core frequencies keyed by core label ("E1", "P3"); behind a protocol so the sampler
/// can be tested with a fake.
protocol CPUFrequencyProviding: Sendable {
    /// Nil on the first call (no baseline yet) and whenever IOReport or the tables are missing.
    func read() -> [String: CoreFrequency]?
}

/// Reads per-core performance-state residency from IOReport (private; loaded by name at
/// runtime, so a missing function means "no reading") and converts it with the device tree's
/// frequency tables. No root needed. Only called from `SystemVitalsSampler`'s actor, which
/// serialises access to the subscription and previous sample; hence `@unchecked Sendable`.
final class IOReportCPUFrequencies: CPUFrequencyProviding, @unchecked Sendable {
    private typealias CopyChannelsFn = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias SubscribeFn = @convention(c) (UnsafeRawPointer?, CFMutableDictionary,
                                                    UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> Unmanaged<AnyObject>?
    private typealias SamplesFn = @convention(c) (AnyObject, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias DeltaFn = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias NameFn = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias CountFn = @convention(c) (CFDictionary) -> Int32
    private typealias ResidencyFn = @convention(c) (CFDictionary, Int32) -> Int64

    private struct Functions {
        let samples: SamplesFn, delta: DeltaFn, name: NameFn, count: CountFn, residency: ResidencyFn
    }
    private struct Subscription {
        let functions: Functions
        let subscription: AnyObject
        let channels: CFMutableDictionary
        let tables: (efficiency: [Double], performance: [Double])
    }

    private lazy var setup: Subscription? = Self.subscribe()
    private var previous: CFDictionary?

    func read() -> [String: CoreFrequency]? {
        guard let setup,
              let current = setup.functions.samples(setup.subscription, setup.channels, nil)?.takeRetainedValue()
        else { return nil }
        defer { previous = current }
        guard let previous,
              let delta = setup.functions.delta(previous, current, nil)?.takeRetainedValue() as NSDictionary?,
              let channels = delta["IOReportChannels"] as? [NSDictionary]
        else { return nil }

        var result: [String: CoreFrequency] = [:]
        for channel in channels {
            let item = channel as CFDictionary
            guard let name = setup.functions.name(item)?.takeUnretainedValue() as String?,
                  let label = CPUFrequencyMath.label(forChannel: name) else { continue }
            let table = label.hasPrefix("E") ? setup.tables.efficiency : setup.tables.performance
            let residencies = (0..<setup.functions.count(item)).map { setup.functions.residency(item, $0) }
            if let core = CPUFrequencyMath.core(residencies: residencies, table: table) { result[label] = core }
        }
        return result.isEmpty ? nil : result
    }

    private static func subscribe() -> Subscription? {
        guard let tables = frequencyTables(),
              let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func symbol<T>(_ name: String, as: T.Type) -> T? { dlsym(handle, name).map { unsafeBitCast($0, to: T.self) } }
        guard let copyChannels = symbol("IOReportCopyChannelsInGroup", as: CopyChannelsFn.self),
              let subscribe = symbol("IOReportCreateSubscription", as: SubscribeFn.self),
              let samples = symbol("IOReportCreateSamples", as: SamplesFn.self),
              let delta = symbol("IOReportCreateSamplesDelta", as: DeltaFn.self),
              let name = symbol("IOReportChannelGetChannelName", as: NameFn.self),
              let count = symbol("IOReportStateGetCount", as: CountFn.self),
              let residency = symbol("IOReportStateGetResidency", as: ResidencyFn.self),
              let wanted = copyChannels("CPU Stats" as CFString, "CPU Core Performance States" as CFString, 0, 0, 0)?
                .takeRetainedValue()
        else { return nil }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = subscribe(nil, wanted, &subscribed, 0, nil)?.takeRetainedValue(),
              let channels = subscribed?.takeRetainedValue()
        else { return nil }
        return Subscription(functions: Functions(samples: samples, delta: delta, name: name, count: count, residency: residency),
                            subscription: subscription, channels: channels, tables: tables)
    }

    /// E-cluster and P-cluster tables from the power manager's device-tree node.
    private static func frequencyTables() -> (efficiency: [Double], performance: [Double])? {
        let pmgr = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/arm-io/pmgr")
        guard pmgr != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(pmgr) }
        func table(_ key: String) -> [Double]? {
            let data = IORegistryEntryCreateCFProperty(pmgr, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Data
            return data.map(CPUFrequencyMath.megahertz(fromVoltageStates:)).flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let efficiency = table("voltage-states1-sram"),
              let performance = table("voltage-states5-sram") else { return nil }
        return (efficiency, performance)
    }
}
