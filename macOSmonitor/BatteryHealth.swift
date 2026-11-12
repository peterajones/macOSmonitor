import Foundation
import IOKit

/// Long-term battery condition and live electrical readings, from the `AppleSmartBattery`
/// IOKit service. No root needed. Every field but the cycle count is optional: keys move
/// between macOS releases (several now sit inside a nested `BatteryData` dictionary).
struct BatteryHealth: Equatable, Sendable {
    let cycleCount: Int
    /// Cycles the battery is rated for (1000 on current Macs).
    let designCycleCount: Int?
    /// What a full charge holds today, in mAh. Apple's "Maximum Capacity" is this ÷ design.
    let fullChargeCapacity: Int?
    let designCapacity: Int?
    let temperatureCelsius: Double?
    let voltage: Double?
    /// Positive while charging, negative while discharging.
    let amperageMilliamps: Int?

    /// Parses registry properties. Nil without a cycle count: no smart battery.
    ///
    /// `sources` are searched in order, each at its top level and then in its nested
    /// `BatteryData`. On macOS 27 the temperature is only on the `AppleSmartBatteryPack`
    /// child node, not on `AppleSmartBattery` itself, so the reader passes both.
    init?(sources: [[String: Any]]) {
        let dictionaries = sources.flatMap { [$0, $0["BatteryData"] as? [String: Any] ?? [:]] }
        func int(_ key: String) -> Int? {
            // IOKit hands signed values (amperage) back as unsigned 64-bit numbers; the bit
            // pattern recovers the sign: 18446744073709550000-ish means a small negative.
            guard let number = dictionaries.lazy.compactMap({ $0[key] as? NSNumber }).first
            else { return nil }
            return Int(Int64(bitPattern: number.uint64Value))
        }
        guard let cycles = int("CycleCount") else { return nil }
        cycleCount = cycles
        designCycleCount = int("DesignCycleCount9C")
        fullChargeCapacity = int("NominalChargeCapacity")
        designCapacity = int("DesignCapacity")
        temperatureCelsius = int("Temperature").map { Double($0) / 100 }   // centi-degrees
        voltage = int("Voltage").map { Double($0) / 1000 }                  // millivolts
        amperageMilliamps = int("Amperage")
    }

    init?(properties: [String: Any]) { self.init(sources: [properties]) }

    init(cycleCount: Int, designCycleCount: Int?, fullChargeCapacity: Int?, designCapacity: Int?,
         temperatureCelsius: Double?, voltage: Double?, amperageMilliamps: Int?) {
        self.cycleCount = cycleCount
        self.designCycleCount = designCycleCount
        self.fullChargeCapacity = fullChargeCapacity
        self.designCapacity = designCapacity
        self.temperatureCelsius = temperatureCelsius
        self.voltage = voltage
        self.amperageMilliamps = amperageMilliamps
    }

    /// Matches System Information's "Maximum Capacity": full-charge ÷ design capacity.
    var maximumCapacityPercent: Int? {
        guard let full = fullChargeCapacity, let design = designCapacity, design > 0 else { return nil }
        return Int((Double(full) / Double(design) * 100).rounded())
    }

    /// Watts flowing into (+) or out of (−) the battery.
    var powerWatts: Double? {
        guard let voltage, let amperageMilliamps else { return nil }
        return voltage * Double(amperageMilliamps) / 1000
    }

    // MARK: Display text

    var maximumCapacityText: String { maximumCapacityPercent.map { "\($0)%" } ?? "—" }

    var cycleCountText: String {
        designCycleCount.map { "\(cycleCount) of \($0)" } ?? String(cycleCount)
    }

    var capacityText: String {
        switch (fullChargeCapacity, designCapacity) {
        case let (full?, design?): "\(full) of \(design) mAh"
        case let (full?, nil):     "\(full) mAh"
        default:                   "—"
        }
    }

    var temperatureText: String {
        temperatureCelsius.map { String(format: "%.1f °C", $0) } ?? "—"
    }

    var powerText: String {
        guard let watts = powerWatts else { return "—" }
        let magnitude = String(format: "%.1f W", abs(watts))
        if magnitude == "0.0 W" { return "0.0 W (idle)" }
        return watts > 0 ? "\(magnitude) into battery" : "\(magnitude) from battery"
    }
}

/// Reads `BatteryHealth`; behind a protocol so the model can be tested with a fake.
protocol BatteryHealthProviding: Sendable {
    func read() -> BatteryHealth?   // nil when there is no battery
}

struct SmartBattery: BatteryHealthProviding {
    func read() -> BatteryHealth? {
        guard let battery = Self.properties(ofFirst: "AppleSmartBattery") else { return nil }
        let pack = Self.properties(ofFirst: "AppleSmartBatteryPack")
        return BatteryHealth(sources: [battery] + (pack.map { [$0] } ?? []))
    }

    /// The registry properties of the first service of `className`, or nil if there is none.
    private static func properties(ofFirst className: String) -> [String: Any]? {
        // IOServiceMatching's dictionary is consumed by IOServiceGetMatchingService.
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(className))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS
        else { return nil }
        return properties?.takeRetainedValue() as? [String: Any]
    }
}
