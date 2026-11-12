import Foundation

/// The last 24 hours of battery charge, recorded by this app about once a minute.
/// macOS keeps no history an app can read, so this only covers time the app was running;
/// gaps are kept as gaps rather than drawn across.
struct BatteryHistory: Codable, Equatable, Sendable {
    struct Sample: Codable, Equatable, Sendable {
        let date: Date
        let percent: Int
        /// On the power adapter (charging, charged, or held at a charge limit).
        let onPower: Bool
    }

    private(set) var samples: [Sample] = []

    static let window: TimeInterval = 24 * 60 * 60
    static let spacing: TimeInterval = 60
    /// Samples further apart than this are drawn as separate lines: the app wasn't running.
    static let maxGap: TimeInterval = 150

    init(samples: [Sample] = []) { self.samples = samples }

    /// Records `sample` if a minute has passed since the last one, or if the power state
    /// changed (so plugging in shows at once, not up to a minute later). Returns whether it
    /// was recorded, which is when the caller should save.
    @discardableResult
    mutating func record(_ sample: Sample) -> Bool {
        if let last = samples.last,
           sample.date >= last.date,
           sample.date.timeIntervalSince(last.date) < Self.spacing,
           sample.onPower == last.onPower {
            return false
        }
        // The clock moved back (manual change, time-zone bugs): drop the "future" samples so
        // the series stays in order.
        samples.removeAll { $0.date > sample.date }
        samples.append(sample)
        samples.removeAll { sample.date.timeIntervalSince($0.date) > Self.window }
        return true
    }

    /// Whether any recorded time was on power, i.e. whether the graph draws an on-power bar.
    var hasOnPowerTime: Bool { samples.contains(where: \.onPower) }

    /// Runs of samples with no gap longer than `maxGap`, each drawn as its own line.
    var segments: [[Sample]] {
        var result: [[Sample]] = []
        for sample in samples {
            if let previous = result.last?.last,
               sample.date.timeIntervalSince(previous.date) <= Self.maxGap {
                result[result.count - 1].append(sample)
            } else {
                result.append([sample])
            }
        }
        return result
    }
}

/// Loads and saves the history; behind a protocol so tests never touch the real file.
protocol BatteryHistoryStoring: Sendable {
    func load() -> BatteryHistory
    func save(_ history: BatteryHistory)
}

struct BatteryHistoryFile: BatteryHistoryStoring {
    let url: URL

    /// ~/Library/Application Support/ca.peter-jones.macOSmonitor/battery-history.json
    /// (the app isn't sandboxed, so this is the real Application Support, not a container).
    static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = Bundle.main.bundleIdentifier ?? "macOSmonitor"
        return support.appending(path: folder).appending(path: "battery-history.json")
    }

    init(url: URL = Self.defaultURL) { self.url = url }

    /// A missing or unreadable file starts a fresh history rather than failing.
    func load() -> BatteryHistory {
        guard let data = try? Data(contentsOf: url),
              let history = try? JSONDecoder().decode(BatteryHistory.self, from: data)
        else { return BatteryHistory() }
        return history
    }

    /// Best effort: losing a minute of history is not worth an error dialog.
    func save(_ history: BatteryHistory) {
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
