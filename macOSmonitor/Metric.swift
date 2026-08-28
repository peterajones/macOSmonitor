import Foundation

/// A measurable quantity the UI can colour-code.
///
/// Deliberately separate from `Surface`, which also carries non-metric cases
/// (`.processes`, `.summary`) that would need meaningless colour entries.
enum Metric: String, CaseIterable, Hashable, Sendable {
    case cpu, memory, network, disk, battery, thermal
}
