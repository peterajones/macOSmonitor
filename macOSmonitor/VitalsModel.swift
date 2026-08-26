import Foundation
import Observation

/// Owns system-wide vitals: the sampler, the latest snapshot, and 60 seconds of history.
/// Runs its own ~1 Hz loop, independent of the process list.
@MainActor
@Observable
final class VitalsModel {
    /// Latest system-wide vitals; nil until the first sample.
    private(set) var vitals: SystemVitals?
    /// Sliding 60-second window per metric, fed one snapshot per tick.
    private(set) var history = VitalsHistory()

    private let sampler: any SystemVitalsSampling
    private let interval: Duration

    init(sampler: any SystemVitalsSampling = SystemVitalsSampler(),
         interval: Duration = .seconds(1)) {
        self.sampler = sampler
        self.interval = interval
    }

    /// One sample → publish it and extend the history.
    func refreshOnce() async {
        let sample = await sampler.sample()
        vitals = sample
        history.append(sample)
    }

    /// Owned by the view via `.task`, which cancels it on disappear.
    func run() async {
        while !Task.isCancelled {
            await refreshOnce()
            try? await Task.sleep(for: interval)
        }
    }
}
