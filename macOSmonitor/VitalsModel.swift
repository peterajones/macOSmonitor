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
    /// The latest CPU temperature on every vitals tick (60 s), so it can share the CPU graph's
    /// time axis; the sensors are read every 2 s, so each reading repeats until the next.
    private(set) var cpuTemperatureHistory = MetricHistory(capacity: 60)
    /// When the latest temperature joined the history, so the thermal graph glides on its
    /// own 2 s tick.
    private(set) var lastThermalSampleDate: Date?

    static let thermalInterval: Duration = .seconds(2)
    static let thermalHistoryCapacity = 150
    private let thermalSampler: any ThermalSampling

    /// Latest power draw; nil until read, or when this Mac reports none.
    private(set) var power: PowerReading?
    /// Whole-system watts, one sample per vitals tick (60 s).
    private(set) var powerHistory = MetricHistory(capacity: 60)
    private let powerSampler: any PowerSampling

    private let sampler: any SystemVitalsSampling
    private let interval: Duration
    private let now: @Sendable () -> Date

    init(sampler: any SystemVitalsSampling = SystemVitalsSampler(),
         interval: Duration = .seconds(1),
         coreLayoutProvider: any CoreLayoutProviding = DeviceTreeCoreLayout(),
         thermalSampler: any ThermalSampling = ThermalSampler(),
         powerSampler: any PowerSampling = PowerSampler(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.sampler = sampler
        self.thermalSampler = thermalSampler
        self.powerSampler = powerSampler
        coreLayout = coreLayoutProvider.read()
        self.interval = interval
        self.now = now
    }

    /// How fast the graphs glide: slower on battery or in Low Power Mode.
    var graphFrameRate: Double { GraphFrameRate.rate(for: vitals) }

    /// One sample → publish it and extend the history.
    func refreshOnce() async {
        let sample = await sampler.sample()
        vitals = sample
        history.append(sample)
        if let celsius = thermal?.headline { cpuTemperatureHistory.append(celsius) }
        lastSampleDate = now()
    }

    /// One temperature read → publish it and extend the history. A tick without a reading
    /// appends nothing, so the graph never shows a fake drop to 0 °C.
    func refreshThermalOnce() async {
        thermal = await thermalSampler.sample()
        if let headline = thermal?.headline {
            thermalHistory.append(headline)
            lastThermalSampleDate = now()
        }
    }

    /// One power read. Like temperatures, a tick without a reading appends nothing.
    func refreshPowerOnce() async {
        power = await powerSampler.sample()
        if let watts = power?.systemWatts { powerHistory.append(watts) }
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
            await refreshPowerOnce()
            try? await Task.sleep(for: interval)
        }
    }
}
