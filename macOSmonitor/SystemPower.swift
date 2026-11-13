import Foundation
import IOKit

/// The Mac's power draw, in watts. Each part is nil when this Mac doesn't report it.
///
/// Probed 2026-11-13 on macOS 27.2 (M3 Pro): IOReport's CPU, ANE and DRAM energy counters
/// are frozen (no change over a minute of full load, root or not); only its GPU counter
/// moves. The SMC's power keys are live and need no root.
struct PowerReading: Equatable, Sendable {
    /// Everything the Mac draws (SMC `PSTR`).
    let systemWatts: Double?
    /// Coming in from the power adapter (SMC `PDTR`); 0 on battery.
    let adapterWatts: Double?
    /// Flowing in or out of the battery (SMC `PPBR`).
    let batteryWatts: Double?
    /// The GPU's own draw, from IOReport's GPU energy counter.
    let gpuWatts: Double?

    /// "15.3 W", or "—" with no reading.
    nonisolated static func text(_ watts: Double?) -> String {
        watts.map { String(format: "%.1f W", $0) } ?? "—"
    }
}

/// The SMC's power keys, in watts.
struct SMCPower: Equatable, Sendable {
    let systemWatts: Double?
    let adapterWatts: Double?
    let batteryWatts: Double?

    /// A raw SMC float as watts. The SMC answers keys it doesn't measure with NaN or junk, and
    /// some Macs report battery discharge as negative: magnitude only, and only plausible ones.
    /// (NaN and infinity fail the range check, since they compare false.)
    static func watts(_ raw: Double?) -> Double? {
        guard let raw, abs(raw) < 1_000 else { return nil }
        return abs(raw)
    }
}

protocol SMCPowerProviding: Sendable {
    /// Nil when the SMC can't be opened or publishes none of the keys.
    func read() -> SMCPower?
}

/// Cumulative GPU energy, in nanojoules; behind a protocol so watts are testable.
protocol GPUEnergyProviding: Sendable {
    func totalNanojoules() -> UInt64?
}

protocol PowerSampling: Sendable {
    func sample() async -> PowerReading?
}

/// Turns the SMC's instantaneous watts and the GPU's energy counter into one reading.
actor PowerSampler: PowerSampling {
    private let smc: any SMCPowerProviding
    private let gpu: any GPUEnergyProviding
    private let now: @Sendable () -> UInt64
    private var previousGPU: (nanojoules: UInt64, nanos: UInt64)?

    init(smc: any SMCPowerProviding = AppleSMCPower(),
         gpu: any GPUEnergyProviding = IOReportGPUEnergy(),
         now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.smc = smc
        self.gpu = gpu
        self.now = now
    }

    /// Nil when neither source reads anything (a VM, or both interfaces gone).
    func sample() -> PowerReading? {
        let smcPower = smc.read()
        let gpuTotal = gpu.totalNanojoules()
        let nanos = now()
        var gpuWatts: Double?
        if let gpuTotal, let previousGPU, nanos > previousGPU.nanos, gpuTotal >= previousGPU.nanojoules {
            gpuWatts = Double(gpuTotal - previousGPU.nanojoules) / Double(nanos - previousGPU.nanos)
        }
        previousGPU = gpuTotal.map { ($0, nanos) }
        guard smcPower != nil || gpuTotal != nil else { return nil }
        return PowerReading(systemWatts: smcPower?.systemWatts, adapterWatts: smcPower?.adapterWatts,
                            batteryWatts: smcPower?.batteryWatts, gpuWatts: gpuWatts)
    }
}

/// SMC four-character key codes.
enum SMCKey {
    static func code(_ key: String) -> UInt32 { key.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
}

/// Reads power keys straight from the AppleSMC user client (private, undocumented; no root
/// needed). The 80-byte `SMCKeyData_t` layout is the one every SMC tool uses; a call that
/// fails or a key the SMC doesn't know reads as nil.
final class AppleSMCPower: SMCPowerProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var connection: io_connect_t = 0
    private var opened = false

    deinit { if connection != 0 { IOServiceClose(connection) } }

    func read() -> SMCPower? {
        lock.lock(); defer { lock.unlock() }
        guard open() else { return nil }
        let power = SMCPower(systemWatts: SMCPower.watts(float("PSTR")),
                             adapterWatts: SMCPower.watts(float("PDTR")),
                             batteryWatts: SMCPower.watts(float("PPBR")))
        return power.systemWatts == nil && power.adapterWatts == nil && power.batteryWatts == nil ? nil : power
    }

    private func open() -> Bool {
        if opened { return connection != 0 }
        opened = true
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(service) }
        if IOServiceOpen(service, mach_task_self_, 0, &connection) != kIOReturnSuccess { connection = 0 }
        return connection != 0
    }

    // SMCKeyData_t offsets.
    private static let size = 80, keyOffset = 0, dataSizeOffset = 28, dataTypeOffset = 32
    private static let resultOffset = 40, commandOffset = 42, bytesOffset = 48
    private static let readKeyInfo: UInt8 = 9, readBytes: UInt8 = 5

    /// The key's value when it's an `flt ` (4-byte float), else nil.
    private func float(_ key: String) -> Double? {
        var input = [UInt8](repeating: 0, count: Self.size)
        put(&input, Self.keyOffset, SMCKey.code(key))
        input[Self.commandOffset] = Self.readKeyInfo
        guard let info = call(input) else { return nil }
        let dataSize = load(info, Self.dataSizeOffset)
        guard load(info, Self.dataTypeOffset) == SMCKey.code("flt "), dataSize == 4 else { return nil }
        put(&input, Self.dataSizeOffset, dataSize)
        input[Self.commandOffset] = Self.readBytes
        guard let output = call(input) else { return nil }
        let value = output[Self.bytesOffset..<Self.bytesOffset + 4].withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
        return Double(value)
    }

    private func call(_ input: [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: Self.size)
        var outputSize = Self.size
        let result = input.withUnsafeBytes { inBytes in
            output.withUnsafeMutableBytes { outBytes in
                IOConnectCallStructMethod(connection, 2, inBytes.baseAddress, Self.size, outBytes.baseAddress, &outputSize)
            }
        }
        return result == kIOReturnSuccess && output[Self.resultOffset] == 0 ? output : nil
    }

    private func put(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt32) {
        withUnsafeBytes(of: value) { for k in 0..<4 { bytes[offset + k] = $0[k] } }
    }

    private func load(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        bytes[offset..<offset + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }
}

/// The GPU's cumulative energy from IOReport's "Energy Model" group (private; loaded by name,
/// so a missing function means no reading). Only called from `PowerSampler`'s actor.
final class IOReportGPUEnergy: GPUEnergyProviding, @unchecked Sendable {
    private typealias CopyChannelsFn = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias SubscribeFn = @convention(c) (UnsafeRawPointer?, CFMutableDictionary,
                                                    UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> Unmanaged<AnyObject>?
    private typealias SamplesFn = @convention(c) (AnyObject, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias StringFn = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias ValueFn = @convention(c) (CFDictionary, Int32) -> Int64

    private struct Subscription {
        let subscription: AnyObject
        let channels: CFMutableDictionary
        let samples: SamplesFn, name: StringFn, unit: StringFn, value: ValueFn
    }

    private lazy var setup: Subscription? = Self.subscribe()

    /// Nanojoules per unit, for the unit labels IOReport uses.
    static func nanojoules(perUnit unit: String) -> UInt64? {
        switch unit {
        case "nJ": 1
        case "uJ", "µJ": 1_000
        case "mJ": 1_000_000
        default: nil
        }
    }

    func totalNanojoules() -> UInt64? {
        guard let setup,
              let sample = setup.samples(setup.subscription, setup.channels, nil)?.takeRetainedValue() as NSDictionary?,
              let channels = sample["IOReportChannels"] as? [NSDictionary] else { return nil }
        for channel in channels {
            let item = channel as CFDictionary
            guard setup.name(item)?.takeUnretainedValue() as String? == "GPU Energy",
                  let unit = setup.unit(item)?.takeUnretainedValue() as String?,
                  let scale = Self.nanojoules(perUnit: unit) else { continue }
            let value = setup.value(item, 0)
            return value >= 0 ? UInt64(value) &* scale : nil
        }
        return nil
    }

    private static func subscribe() -> Subscription? {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func symbol<T>(_ name: String, as: T.Type) -> T? { dlsym(handle, name).map { unsafeBitCast($0, to: T.self) } }
        guard let copyChannels = symbol("IOReportCopyChannelsInGroup", as: CopyChannelsFn.self),
              let subscribe = symbol("IOReportCreateSubscription", as: SubscribeFn.self),
              let samples = symbol("IOReportCreateSamples", as: SamplesFn.self),
              let name = symbol("IOReportChannelGetChannelName", as: StringFn.self),
              let unit = symbol("IOReportChannelGetUnitLabel", as: StringFn.self),
              let value = symbol("IOReportSimpleGetIntegerValue", as: ValueFn.self),
              let wanted = copyChannels("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue()
        else { return nil }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = subscribe(nil, wanted, &subscribed, 0, nil)?.takeRetainedValue(),
              let channels = subscribed?.takeRetainedValue()
        else { return nil }
        return Subscription(subscription: subscription, channels: channels,
                            samples: samples, name: name, unit: unit, value: value)
    }
}
