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

    /// When the latest sample arrived, so a graph can glide between samples.
    private(set) var lastSampleDate: Date?

    /// Which cores are performance and which efficiency; nil where the Mac doesn't say.
    let coreLayout: CoreLayout?

    private let sampler: any SystemVitalsSampling
    private let interval: Duration
    private let now: @Sendable () -> Date

    init(sampler: any SystemVitalsSampling = SystemVitalsSampler(),
         interval: Duration = .seconds(1),
         coreLayoutProvider: any CoreLayoutProviding = DeviceTreeCoreLayout(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.sampler = sampler
        coreLayout = coreLayoutProvider.read()
        self.interval = interval
        self.now = now
    }

    /// One sample → publish it and extend the history.
    func refreshOnce() async {
        let sample = await sampler.sample()
        vitals = sample
        history.append(sample)
        lastSampleDate = now()
    }

    /// Owned by the view via `.task`, which cancels it on disappear.
    func run() async {
        while !Task.isCancelled {
            await refreshOnce()
            try? await Task.sleep(for: interval)
        }
    }
}
