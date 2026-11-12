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

    /// Latest grouped temperatures; nil until read, or when the sensors are unavailable.
    private(set) var thermal: ThermalReading?
    /// Hottest CPU die temperature, one sample per thermal tick: 150 × 2 s = 5 minutes.
    private(set) var thermalHistory = MetricHistory(capacity: VitalsModel.thermalHistoryCapacity)

    static let thermalInterval: Duration = .seconds(2)
    static let thermalHistoryCapacity = 150
    private let thermalSampler: any ThermalSampling

    private let sampler: any SystemVitalsSampling
    private let interval: Duration
    private let now: @Sendable () -> Date

    init(sampler: any SystemVitalsSampling = SystemVitalsSampler(),
         interval: Duration = .seconds(1),
         coreLayoutProvider: any CoreLayoutProviding = DeviceTreeCoreLayout(),
         thermalSampler: any ThermalSampling = ThermalSampler(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.sampler = sampler
        self.thermalSampler = thermalSampler
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

    /// One temperature read → publish it and extend the history. A tick without a reading
    /// appends nothing, so the graph never shows a fake drop to 0 °C.
    func refreshThermalOnce() async {
        thermal = await thermalSampler.sample()
        if let headline = thermal?.headline { thermalHistory.append(headline) }
    }

    /// The slower temperature loop, separate from `run()` so the SMC wait never delays the
    /// 1 Hz vitals. Started once by the app alongside `run()`.
    func runThermal() async {
        while !Task.isCancelled {
            await refreshThermalOnce()
            try? await Task.sleep(for: Self.thermalInterval)
        }
    }

    /// Owned by the view via `.task`, which cancels it on disappear.
    func run() async {
        while !Task.isCancelled {
            await refreshOnce()
            try? await Task.sleep(for: interval)
        }
    }
}
