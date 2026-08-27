import Foundation
import IOKit
import IOKit.storage

/// Cumulative disk byte counters, isolated behind a protocol so the sampler can use a fake.
protocol DiskStatsProviding: Sendable {
    func counters() -> (read: UInt64, written: UInt64)?
}

struct DiskStats: DiskStatsProviding {
    func counters() -> (read: UInt64, written: UInt64)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching(kIOBlockStorageDriverClass),
                                           &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        var read: UInt64 = 0
        var written: UInt64 = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }        // every matched service must be released
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties,
                                                    kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as? [String: Any],
                  let statistics = dictionary[kIOBlockStorageDriverStatisticsKey]
                    as? [String: Any]
            else { continue }
            // 64-bit counters: a machine with any history reads well past 4 GB.
            read += (statistics[kIOBlockStorageDriverStatisticsBytesReadKey] as? UInt64) ?? 0
            written += (statistics[kIOBlockStorageDriverStatisticsBytesWrittenKey] as? UInt64) ?? 0
        }
        return (read, written)
    }
}
