import Foundation
import IOKit

/// One temperature sensor's reading, as the HID event system names it (e.g. "PMU tdie3").
struct SensorReading: Equatable, Sendable {
    let name: String
    let celsius: Double
}

/// Temperatures grouped the way the Thermal panel shows them. Apple doesn't document which
/// die sensor sits over which core, so CPU readings are summarised (hottest, average) rather
/// than labelled per core.
struct ThermalReading: Equatable, Sendable {
    let cpuDieMax: Double?
    let cpuDieAverage: Double?
    let boardMax: Double?
    let ssd: Double?
    let battery: Double?

    /// Readings outside this range are a sensor reporting "no value" (0, −127, 255…), not heat.
    static let plausible: ClosedRange<Double> = 1...150

    /// Groups raw sensor readings. Nil when no sensor gives a plausible value: the panel then
    /// hides rather than showing a row of dashes.
    ///
    /// - "PMU tdie…": CPU die. "PMU tdev…": other board sensors. "PMU tcal" is a constant
    ///   calibration value, not a temperature, and is skipped.
    /// - "NAND…": SSD. "gas gauge battery": the battery's cells.
    init?(readings: [SensorReading]) {
        let valid = readings.filter { Self.plausible.contains($0.celsius) }
        func values(_ matches: (String) -> Bool) -> [Double] {
            valid.filter { matches($0.name) }.map(\.celsius)
        }
        let die = values { $0.hasPrefix("PMU tdie") }
        let board = values { $0.hasPrefix("PMU tdev") }
        let ssd = values { $0.hasPrefix("NAND") }
        let battery = values { $0.hasPrefix("gas gauge battery") }

        guard !(die.isEmpty && board.isEmpty && ssd.isEmpty && battery.isEmpty) else { return nil }
        cpuDieMax = die.max()
        cpuDieAverage = die.isEmpty ? nil : die.reduce(0, +) / Double(die.count)
        boardMax = board.max()
        self.ssd = ssd.max()
        self.battery = battery.isEmpty ? nil : battery.reduce(0, +) / Double(battery.count)
    }

    init(cpuDieMax: Double?, cpuDieAverage: Double?, boardMax: Double?, ssd: Double?, battery: Double?) {
        self.cpuDieMax = cpuDieMax
        self.cpuDieAverage = cpuDieAverage
        self.boardMax = boardMax
        self.ssd = ssd
        self.battery = battery
    }

    /// "44 °C", or "—" when the sensor group is missing.
    static func text(_ celsius: Double?) -> String {
        celsius.map { "\(Int($0.rounded())) °C" } ?? "—"
    }

    /// The headline figure: the hottest CPU die sensor, else the hottest of anything else.
    var headline: Double? { cpuDieMax ?? [boardMax, ssd, battery].compactMap { $0 }.max() }
}

/// Reads every temperature sensor; behind a protocol so the sampler can be tested with a fake.
protocol ThermalSensorProviding: Sendable {
    /// Nil when the private interface is unavailable (a macOS update removed or changed it).
    func read() -> [SensorReading]?
}

/// Reads the SMC's temperature sensors through the HID event system: private IOKit
/// functions, looked up by name at runtime so a missing one means "no reading", never a
/// failed launch. Only ever called from `ThermalSampler`'s actor, which serialises access to
/// the cached client and services; hence `@unchecked Sendable`.
final class HIDThermalSensors: ThermalSensorProviding, @unchecked Sendable {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatchingFn = @convention(c) (AnyObject, CFDictionary) -> Void
    private typealias CopyServicesFn = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEventFn = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloatFn = @convention(c) (AnyObject, Int32) -> Double

    private struct Functions {
        let create: CreateFn
        let setMatching: SetMatchingFn
        let copyServices: CopyServicesFn
        let copyProperty: CopyPropertyFn
        let copyEvent: CopyEventFn
        let getFloat: GetFloatFn
    }

    private static let temperatureEventType: Int64 = 15            // kIOHIDEventTypeTemperature
    private static let temperatureField = Int32(15 << 16)           // its level field

    private lazy var functions: Functions? = Self.loadFunctions()
    /// Connecting and listing sensors costs ~5–9 ms, so it's done once and reused.
    private var sensors: [(service: AnyObject, name: String)]?
    private var client: AnyObject?

    func read() -> [SensorReading]? {
        guard let functions else { return nil }
        if sensors == nil { connect(functions) }
        guard let sensors, !sensors.isEmpty else { return nil }
        return sensors.compactMap { sensor in
            guard let event = functions.copyEvent(sensor.service, Self.temperatureEventType, 0, 0)?
                    .takeRetainedValue() else { return nil }
            return SensorReading(name: sensor.name, celsius: functions.getFloat(event, Self.temperatureField))
        }
    }

    private func connect(_ functions: Functions) {
        guard let client = functions.create(kCFAllocatorDefault)?.takeRetainedValue() else {
            sensors = []
            return
        }
        // Apple vendor usage page 0xff00, usage 5: temperature sensors.
        functions.setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        let services = (functions.copyServices(client)?.takeRetainedValue() as? [AnyObject]) ?? []
        self.client = client
        sensors = services.map { service in
            (service, functions.copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String ?? "")
        }
    }

    private static func loadFunctions() -> Functions? {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return nil }
        func symbol<T>(_ name: String, as: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let create = symbol("IOHIDEventSystemClientCreate", as: CreateFn.self),
              let setMatching = symbol("IOHIDEventSystemClientSetMatching", as: SetMatchingFn.self),
              let copyServices = symbol("IOHIDEventSystemClientCopyServices", as: CopyServicesFn.self),
              let copyProperty = symbol("IOHIDServiceClientCopyProperty", as: CopyPropertyFn.self),
              let copyEvent = symbol("IOHIDServiceClientCopyEvent", as: CopyEventFn.self),
              let getFloat = symbol("IOHIDEventGetFloatValue", as: GetFloatFn.self)
        else { return nil }
        return Functions(create: create, setMatching: setMatching, copyServices: copyServices,
                         copyProperty: copyProperty, copyEvent: copyEvent, getFloat: getFloat)
    }
}

protocol ThermalSampling: Sendable {
    func sample() async -> ThermalReading?
}

/// Its own actor, apart from `SystemVitalsSampler`: one pass waits ~45 ms on the SMC (only
/// ~2 ms of it CPU), which must not hold up the 1 Hz vitals tick.
actor ThermalSampler: ThermalSampling {
    private let sensors: any ThermalSensorProviding

    init(sensors: any ThermalSensorProviding = HIDThermalSensors()) {
        self.sensors = sensors
    }

    func sample() -> ThermalReading? {
        sensors.read().flatMap(ThermalReading.init(readings:))
    }
}
