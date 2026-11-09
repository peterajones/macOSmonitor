import Foundation

/// A fixed-capacity sliding window of samples, oldest first. Appending past
/// capacity evicts the oldest value.
struct MetricHistory: Equatable, Sendable {
    let capacity: Int
    private var storage: [Double] = []
    /// Every sample ever appended, including evicted ones: a stable clock for time marks.
    private(set) var totalAppended = 0

    init(capacity: Int = 60) {
        self.capacity = max(1, capacity)
    }

    mutating func append(_ value: Double) {
        storage.append(value)
        totalAppended += 1
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
