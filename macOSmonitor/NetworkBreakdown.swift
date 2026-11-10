import Foundation

/// One row of the Network panel's per-interface breakdown.
struct InterfaceRate: Equatable, Sendable {
    let name: String
    let kind: InterfaceKind
    let inBytesPerSec: Double
    let outBytesPerSec: Double

    var inText: String { SystemVitals.rate(inBytesPerSec) }
    var outText: String { SystemVitals.rate(outBytesPerSec) }
}

/// Builds the breakdown rows. Pure, so ordering and folding are testable without a sampler.
enum NetworkBreakdown {
    static let otherName = "Other"

    /// - Parameters:
    ///   - counters: this tick's cumulative counters, used to hide ports that never carried traffic.
    ///   - rates: per-interface rates, keyed by BSD name.
    ///   - ports: hardware ports, keyed by BSD name; everything else folds into one "Other" row.
    static func rows(counters: [InterfaceCounters],
                     rates: [String: (in: Double, out: Double)],
                     ports: [String: HardwarePort]) -> [InterfaceRate] {
        var hardware: [InterfaceRate] = []
        var otherIn = 0.0
        var otherOut = 0.0
        var otherEverUsed = false

        for counter in counters {
            let rate = rates[counter.name] ?? (in: 0, out: 0)
            let everUsed = counter.received > 0 || counter.sent > 0
            if let port = ports[counter.name] {
                guard everUsed else { continue }
                hardware.append(InterfaceRate(name: port.displayName, kind: port.kind,
                                              inBytesPerSec: rate.in, outBytesPerSec: rate.out))
            } else {
                otherEverUsed = otherEverUsed || everUsed
                otherIn += rate.in
                otherOut += rate.out
            }
        }

        // A fixed order, so rows don't jump about as rates change.
        hardware.sort {
            $0.kind != $1.kind ? $0.kind < $1.kind
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        if otherEverUsed {
            hardware.append(InterfaceRate(name: otherName, kind: .virtual,
                                          inBytesPerSec: otherIn, outBytesPerSec: otherOut))
        }
        return hardware
    }
}
