import Foundation
import IOKit

/// Cumulative GPU time per process, in nanoseconds. Read from the GPU driver's user-client
/// registry entries: each app that uses the GPU has one or more, naming its PID
/// ("IOUserClientCreator" = "pid 625, WindowServer") with an "AppUsage" list whose
/// "accumulatedGPUTime" counters grow as it runs GPU work. Public IOKit reads, but the
/// property names are undocumented, so a missing or changed shape means "no reading".
/// Readable for every process, root's included, without root; ~1 ms for ~75 processes.
protocol ProcessGPUUsageProviding: Sendable {
    /// Nil when no GPU publishes usage. A process absent from the map has used no GPU time.
    func gpuTimes() -> [pid_t: UInt64]?
}

enum GPUClientParsing {
    /// "pid 625, WindowServer" → 625.
    static func pid(fromCreator creator: String) -> pid_t? {
        guard creator.hasPrefix("pid "),
              let number = creator.dropFirst(4).split(separator: ",").first else { return nil }
        return pid_t(number.trimmingCharacters(in: .whitespaces))
    }

    /// Sum of every "accumulatedGPUTime" in an "AppUsage" list (one entry per API, e.g. Metal).
    static func gpuTime(fromAppUsage usage: [[String: Any]]) -> UInt64 {
        usage.compactMap { ($0["accumulatedGPUTime"] as? NSNumber)?.uint64Value }
            .reduce(0, { $0 &+ $1 })
    }
}

struct ProcessGPUUsage: ProcessGPUUsageProviding {
    func gpuTimes() -> [pid_t: UInt64]? {
        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"),
                                           &accelerators) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(accelerators) }

        var times: [pid_t: UInt64] = [:]
        var sawUsage = false
        while case let accelerator = IOIteratorNext(accelerators), accelerator != IO_OBJECT_NULL {
            defer { IOObjectRelease(accelerator) }
            var clients: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &clients) == KERN_SUCCESS
            else { continue }
            defer { IOObjectRelease(clients) }
            while case let client = IOIteratorNext(clients), client != IO_OBJECT_NULL {
                defer { IOObjectRelease(client) }   // first, so it also runs on `continue`
                guard let creator = property(client, "IOUserClientCreator") as? String,
                      let pid = GPUClientParsing.pid(fromCreator: creator),
                      let usage = property(client, "AppUsage") as? [[String: Any]]
                else { continue }
                sawUsage = true
                times[pid, default: 0] &+= GPUClientParsing.gpuTime(fromAppUsage: usage)
            }
        }
        return sawUsage ? times : nil
    }

    private func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
