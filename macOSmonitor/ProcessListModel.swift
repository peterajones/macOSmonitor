import Foundation
import Observation

@MainActor
@Observable
final class ProcessListModel {
    private(set) var rows: [ProcessInfoRow] = []

    private let sampler: any ProcessSampling
    private let interval: Duration

    init(sampler: any ProcessSampling = ProcessSampler(), interval: Duration = .seconds(1)) {
        self.sampler = sampler
        self.interval = interval
    }

    /// One sample → publish. Used by both `run()` and unit tests.
    func refreshOnce() async {
        rows = await sampler.sample()
    }

    /// Drives the dashboard. Owned by the view via `.task`, which cancels it on disappear.
    func run() async {
        while !Task.isCancelled {
            await refreshOnce()
            try? await Task.sleep(for: interval)
        }
    }
}
