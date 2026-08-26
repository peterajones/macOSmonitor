import Foundation

/// A fixed-capacity sliding window of samples, oldest first. Appending past
/// capacity evicts the oldest value.
struct MetricHistory: Equatable, Sendable {
    let capacity: Int
    private var storage: [Double] = []

    init(capacity: Int = 60) {
        self.capacity = max(1, capacity)
    }

    mutating func append(_ value: Double) {
        storage.append(value)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
    }

    /// Samples oldest → newest.
    var values: [Double] { storage }
    var isEmpty: Bool { storage.isEmpty }
    var latest: Double? { storage.last }
    /// Largest value currently in the window (0 when empty).
    var peak: Double { storage.max() ?? 0 }
}
