import Foundation
import IOKit

/// GPU load and memory, read from the GPU driver's IOKit registry entry (`IOAccelerator`)
/// without root. The driver publishes a `PerformanceStatistics` dictionary that Activity
/// Monitor's GPU History reads too.
struct GPUInfo: Equatable, Sendable {
    /// "Device Utilization %": how much of the time the GPU was busy, 0–100.
    let utilizationPercent: Double
    /// "In use system memory": unified memory the GPU is using now; nil when not published.
    let memoryInUseBytes: UInt64?
    /// e.g. "Apple M3 Pro".
    let name: String?
    let coreCount: Int?

    /// Parses an accelerator's registry properties. Nil without a utilisation figure, which
    /// is what a virtual or software-only accelerator looks like.
    init?(properties: [String: Any]) {
        let statistics = properties["PerformanceStatistics"] as? [String: Any] ?? [:]
        guard let utilization = (statistics["Device Utilization %"] as? NSNumber)?.doubleValue else {
            return nil
        }
        utilizationPercent = min(max(utilization, 0), 100)
        memoryInUseBytes = (statistics["In use system memory"] as? NSNumber)?.uint64Value
        name = properties["model"] as? String
        coreCount = (properties["gpu-core-count"] as? NSNumber)?.intValue
    }

    init(utilizationPercent: Double, memoryInUseBytes: UInt64?, name: String? = nil, coreCount: Int? = nil) {
        self.utilizationPercent = utilizationPercent
        self.memoryInUseBytes = memoryInUseBytes
        self.name = name
        self.coreCount = coreCount
    }

    var utilizationText: String { "\(Int(utilizationPercent.rounded()))%" }

    var memoryText: String { memoryInUseBytes.map(SystemVitals.gigabytes) ?? "—" }

    /// "Apple M3 Pro, 18 cores", or whichever part is known.
    var descriptionText: String {
        switch (name, coreCount) {
        case let (name?, cores?): "\(name), \(cores) cores"
        case let (name?, nil):    name
        case let (nil, cores?):   "\(cores) GPU cores"
        default:                  "GPU"
        }
    }
}

/// Reads `GPUInfo`; behind a protocol so the sampler can be tested with a fake.
protocol GPUStatsProviding: Sendable {
    func read() -> GPUInfo?   // nil when no GPU publishes statistics
}

struct GPUStats: GPUStatsProviding {
    /// The first accelerator that publishes statistics. Apple Silicon Macs have one GPU.
    func read() -> GPUInfo? {
        var iterator: io_iterator_t = 0
        // IOServiceMatching's dictionary is consumed by IOServiceGetMatchingServices.
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }   // first, so it also runs on `continue`
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as? [String: Any]
            else { continue }
            if let info = GPUInfo(properties: dictionary) { return info }
        }
        return nil
    }
}
