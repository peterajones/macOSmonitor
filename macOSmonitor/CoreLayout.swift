import Foundation
import IOKit

/// Apple Silicon's two kinds of CPU core.
enum CoreKind: String, Equatable, Sendable {
    case performance = "P"
    case efficiency = "E"
}

/// Which logical CPUs are performance and which are efficiency cores, indexed by logical CPU
/// id (the order `host_processor_info` reports per-core load in). Read once: hardware
/// doesn't change while the app runs.
struct CoreLayout: Equatable, Sendable {
    let kinds: [CoreKind]

    /// "P1"…"P6", "E1"…"E6": numbered within each kind, in logical-CPU order. Falls back to
    /// "0", "1", … when the layout doesn't match the number of cores being shown, so a
    /// mismatch can never put a P label on an E core.
    static func labels(for layout: CoreLayout?, coreCount: Int) -> [String] {
        guard let kinds = layout?.kinds, kinds.count == coreCount else {
            return (0..<coreCount).map(String.init)
        }
        var counts: [CoreKind: Int] = [:]
        return kinds.map { kind in
            counts[kind, default: 0] += 1
            return "\(kind.rawValue)\(counts[kind]!)"
        }
    }

    func count(_ kind: CoreKind) -> Int { kinds.filter { $0 == kind }.count }

    /// "12 (6P + 6E)"
    var coreCountText: String {
        "\(kinds.count) (\(count(.performance))P + \(count(.efficiency))E)"
    }

    /// Mean load of one kind's cores; nil when there are none or the counts don't line up.
    func averageLoad(of kind: CoreKind, perCore: [Double]) -> Double? {
        guard perCore.count == kinds.count else { return nil }
        let loads = zip(kinds, perCore).filter { $0.0 == kind }.map(\.1)
        return loads.isEmpty ? nil : loads.reduce(0, +) / Double(loads.count)
    }

    /// Builds the layout from (logical CPU id, cluster type) pairs as the device tree lists
    /// them. Nil unless the ids are exactly 0..<n and every type is E or P.
    init?(cores: [(logicalID: Int, clusterType: String)]) {
        let sorted = cores.sorted { $0.logicalID < $1.logicalID }
        guard !sorted.isEmpty, sorted.map(\.logicalID) == Array(0..<sorted.count) else { return nil }
        var kinds: [CoreKind] = []
        for core in sorted {
            guard let kind = CoreKind(rawValue: core.clusterType) else { return nil }
            kinds.append(kind)
        }
        self.kinds = kinds
    }

    init(kinds: [CoreKind]) { self.kinds = kinds }
}

/// Reads the core layout; behind a protocol so the model can be tested with a fake.
protocol CoreLayoutProviding: Sendable {
    func read() -> CoreLayout?   // nil on Intel or when the device tree doesn't say
}

/// Reads `cluster-type` ("E"/"P") and `logical-cpu-id` from each `IODeviceTree:/cpus` child.
struct DeviceTreeCoreLayout: CoreLayoutProviding {
    func read() -> CoreLayout? {
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(cpus) }

        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var cores: [(logicalID: Int, clusterType: String)] = []
        while case let cpu = IOIteratorNext(iterator), cpu != IO_OBJECT_NULL {
            defer { IOObjectRelease(cpu) }   // first, so it also runs on `continue`
            guard let id = property(cpu, "logical-cpu-id") as? NSNumber,
                  let type = property(cpu, "cluster-type") as? Data
            else { continue }
            // A C string in a Data blob: "E\0" or "P\0".
            let text = String(decoding: type.prefix { $0 != 0 }, as: UTF8.self)
            cores.append((id.intValue, text))
        }
        return CoreLayout(cores: cores)
    }

    private func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
