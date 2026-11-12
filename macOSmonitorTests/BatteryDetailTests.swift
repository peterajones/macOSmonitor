import Testing
import Foundation
@testable import macOSmonitor

final class FakeBatteryHealth: BatteryHealthProviding, @unchecked Sendable {
    var health: BatteryHealth?
    func read() -> BatteryHealth? { health }
}

final class FakeHistoryStore: BatteryHistoryStoring, @unchecked Sendable {
    var stored = BatteryHistory()
    private(set) var saveCount = 0
    func load() -> BatteryHistory { stored }
    func save(_ history: BatteryHistory) { stored = history; saveCount += 1 }
}

struct BatteryHealthTests {
    /// Shaped like this Mac's registry: capacities and temperature nested in BatteryData,
    /// and a negative amperage handed back as an unsigned 64-bit number.
    private let properties: [String: Any] = [
        "CycleCount": NSNumber(value: 97),
        "DesignCycleCount9C": NSNumber(value: 1000),
        "AppleRawMaxCapacity": NSNumber(value: 5237),      // not Apple's figure: must be ignored
        "Voltage": NSNumber(value: 12207),
        "Amperage": NSNumber(value: UInt64(bitPattern: -1500)),
        "BatteryData": ["NominalChargeCapacity": NSNumber(value: 5389),
                        "DesignCapacity": NSNumber(value: 6249),
                        "Temperature": NSNumber(value: 3179)] as [String: Any],
    ]

    @Test func parsesNestedKeysAndSignedAmperage() throws {
        let health = try #require(BatteryHealth(properties: properties))
        #expect(health.cycleCountText == "97 of 1000")
        #expect(health.amperageMilliamps == -1500)
        #expect(health.capacityText == "5389 of 6249 mAh")
        #expect(health.temperatureText == "31.8 °C")
    }

    /// System Information says 86% on this Mac: nominal ÷ design. Raw max ÷ design would be 84%.
    @Test func maximumCapacityMatchesSystemInformation() throws {
        #expect(try #require(BatteryHealth(properties: properties)).maximumCapacityText == "86%")
    }

    @Test func powerIsVoltsTimesAmpsWithDirection() throws {
        let draining = try #require(BatteryHealth(properties: properties))
        #expect(draining.powerText == "18.3 W from battery")     // 12.207 V × 1.5 A

        var charging = properties
        charging["Amperage"] = NSNumber(value: 2000)
        #expect(BatteryHealth(properties: charging)?.powerText == "24.4 W into battery")

        var idle = properties
        idle["Amperage"] = NSNumber(value: 0)
        #expect(BatteryHealth(properties: idle)?.powerText == "0.0 W (idle)")
    }

    /// macOS 27: the temperature is only on the AppleSmartBatteryPack child node.
    @Test func fallsBackToLaterSourcesForMissingKeys() throws {
        var battery = properties
        battery["BatteryData"] = ["NominalChargeCapacity": NSNumber(value: 5389),
                                  "DesignCapacity": NSNumber(value: 6249)] as [String: Any]
        let pack: [String: Any] = ["BatteryData": ["Temperature": NSNumber(value: 3189),
                                                   "CycleCount": NSNumber(value: 1)] as [String: Any]]
        let health = try #require(BatteryHealth(sources: [battery, pack]))
        #expect(health.temperatureText == "31.9 °C")
        #expect(health.cycleCount == 97)          // the first source wins where both have it
    }

    @Test func noCycleCountMeansNoBattery() {
        #expect(BatteryHealth(properties: ["Voltage": NSNumber(value: 12000)]) == nil)
    }

    /// Integration: only meaningful on a Mac with a battery, like the dev laptop.
    @Test(.enabled(if: BatteryStats().read() != nil))
    func readsThisMacsBattery() throws {
        let health = try #require(SmartBattery().read())
        #expect(health.cycleCount > 0)
        #expect((1...110).contains(try #require(health.maximumCapacityPercent)))
        #expect((0...60).contains(try #require(health.temperatureCelsius)))
    }
}

struct BatteryHistoryTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func sample(_ seconds: TimeInterval, _ percent: Int = 50, power: Bool = false) -> BatteryHistory.Sample {
        .init(date: t0.addingTimeInterval(seconds), percent: percent, onPower: power)
    }

    @Test func recordsAboutOnceAMinute() {
        var history = BatteryHistory()
        let recorded1 = history.record(sample(0))
        #expect(recorded1)
        let recorded2 = history.record(sample(59))
        #expect(!recorded2)
        let recorded3 = history.record(sample(60))
        #expect(recorded3)
        #expect(history.samples.map(\.date) == [t0, t0.addingTimeInterval(60)])
    }

    @Test func plugInIsRecordedAtOnce() {
        var history = BatteryHistory()
        history.record(sample(0))
        let recorded4 = history.record(sample(5, power: true))
        #expect(recorded4)
        let recorded5 = history.record(sample(10, power: true))
        #expect(!recorded5)
    }

    @Test func keepsOnly24Hours() {
        var history = BatteryHistory()
        history.record(sample(0))
        history.record(sample(120))
        history.record(sample(BatteryHistory.window + 60))
        #expect(history.samples.map(\.date) == [t0.addingTimeInterval(120),
                                                t0.addingTimeInterval(BatteryHistory.window + 60)])
    }

    @Test func clockMovingBackDropsTheFutureSamples() {
        var history = BatteryHistory()
        history.record(sample(0))
        history.record(sample(600))
        let recorded6 = history.record(sample(300))
        #expect(recorded6)
        #expect(history.samples.map(\.date) == [t0, t0.addingTimeInterval(300)])
    }

    /// 150 s is still one line (a delayed tick); 151 s is a gap where the app wasn't running.
    @Test func splitsIntoSegmentsAtGaps() {
        let history = BatteryHistory(samples: [sample(0), sample(60), sample(210), sample(361), sample(421)])
        let offsets = history.segments.map { segment in segment.map { $0.date.timeIntervalSince(t0) } }
        #expect(offsets == [[0, 60, 210], [361, 421]])
    }

    /// Drives whether the panel shows the bar's key: no bar, no key.
    @Test func knowsWhetherAnyTimeWasOnPower() {
        #expect(!BatteryHistory().hasOnPowerTime)
        #expect(!BatteryHistory(samples: [sample(0), sample(60)]).hasOnPowerTime)
        #expect(BatteryHistory(samples: [sample(0), sample(60, power: true), sample(120)]).hasOnPowerTime)
    }

    @Test func fileRoundTripsAndToleratesMissingOrBrokenFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = BatteryHistoryFile(url: folder.appending(path: "nested/history.json"))

        #expect(file.load() == BatteryHistory())                 // missing: empty, no error
        let history = BatteryHistory(samples: [sample(0, 80, power: true), sample(60, 79)])
        file.save(history)                                       // creates the folder
        #expect(file.load() == history)

        try Data("garbage".utf8).write(to: file.url)
        #expect(file.load() == BatteryHistory())
    }
}

@MainActor
struct BatteryModelTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private final class Clock: @unchecked Sendable { var date: Date; init(_ d: Date) { date = d } }

    @Test func recordsAndSavesOnlyWhenTheHistoryChanges() {
        let stats = FakeBatteryStats()
        stats.info = BatteryInfo(chargePercent: 80, state: .ac, timeRemainingMinutes: nil)
        let store = FakeHistoryStore()
        let clock = Clock(t0)
        let model = BatteryModel(stats: stats, healthProvider: FakeBatteryHealth(), store: store,
                                 now: { clock.date })

        model.refreshOnce()
        #expect(store.saveCount == 1)
        #expect(model.history.samples.last == .init(date: t0, percent: 80, onPower: true))

        clock.date = t0.addingTimeInterval(2)
        model.refreshOnce()                                   // same minute: nothing to save
        #expect(store.saveCount == 1)

        stats.info = BatteryInfo(chargePercent: 79, state: .discharging, timeRemainingMinutes: 300)
        clock.date = t0.addingTimeInterval(4)
        model.refreshOnce()                                   // unplugged: recorded at once
        #expect(store.saveCount == 2)
        #expect(model.history.samples.last?.onPower == false)
    }

    @Test func continuesTheSavedHistoryAndRecordsNothingWithoutABattery() {
        let store = FakeHistoryStore()
        store.stored = BatteryHistory(samples: [.init(date: t0, percent: 55, onPower: false)])
        let model = BatteryModel(stats: FakeBatteryStats(), healthProvider: FakeBatteryHealth(),
                                 store: store, now: { Date() })
        #expect(model.history == store.stored)                // loaded at launch

        model.refreshOnce()                                   // no battery (desktop)
        #expect(store.saveCount == 0)
        #expect(model.history.samples.count == 1)
    }

    @Test func statusNamesEachState() {
        #expect(BatteryModel.statusText(nil) == "—")
        let texts = [BatteryInfo.State.charging, .discharging, .charged, .ac].map {
            BatteryModel.statusText(BatteryInfo(chargePercent: 50, state: $0, timeRemainingMinutes: nil))
        }
        #expect(Set(texts).count == 4)
        #expect(texts[3].contains("not charging"))
    }
}

struct BatteryGraphGeometryTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let size = CGSize(width: 480, height: 200)

    private func sample(hoursAgo: Double, _ percent: Int, power: Bool = false) -> BatteryHistory.Sample {
        .init(date: now.addingTimeInterval(-hoursAgo * 3600), percent: percent, onPower: power)
    }

    /// 6 hours ago is 3/4 across; 80% is 1/5 down. Asymmetric numbers so swapped axes show.
    @Test func mapsTimeAcrossAndChargeUp() {
        func close(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9 }
        let p1 = BatteryGraphGeometry.point(sample(hoursAgo: 6, 80), now: now, in: size)
        #expect(close(p1, CGPoint(x: 360, y: 40)), "\(p1)")
        let p2 = BatteryGraphGeometry.point(sample(hoursAgo: 24, 0), now: now, in: size)
        #expect(close(p2, CGPoint(x: 0, y: 200)), "\(p2)")
    }

    @Test func onPowerSpansEndAtUnplugAndAtSegmentEnd() {
        let segments = [[sample(hoursAgo: 12, 40, power: true), sample(hoursAgo: 9, 70, power: true),
                         sample(hoursAgo: 6, 65)],
                        [sample(hoursAgo: 3, 50, power: true), sample(hoursAgo: 0, 60, power: true)]]
        #expect(BatteryGraphGeometry.onPowerSpans(segments, now: now, in: size) == [240...360, 420...480])
    }
}

struct BatterySurfaceTests {
    @Test func batteryPanelIsListedOnlyWithABattery() {
        #expect(Surface.performance(hasBattery: false) == [.cpu, .memory, .network, .disk])
        #expect(Surface.performance(hasBattery: true) == [.cpu, .memory, .network, .disk, .battery])
        #expect(Surface.battery.metric == .battery)
    }
}

/// Review-harness follow-ups: the registry fallback without hardware, and history edges.
struct BatteryFallbackAndHistoryEdgeTests {
    private let battery: [String: Any] = [
        "CycleCount": NSNumber(value: 97),
        "BatteryData": ["DesignCapacity": NSNumber(value: 6249)] as [String: Any],
    ]
    private let pack: [String: Any] = [
        "BatteryData": ["Temperature": NSNumber(value: 3189),
                        "NominalChargeCapacity": NSNumber(value: 5389)] as [String: Any],
    ]

    private func reader(_ classes: [String: [String: Any]]) -> SmartBattery {
        nonisolated(unsafe) let table = classes
        return SmartBattery(properties: { table[$0] })
    }

    /// macOS 27: temperature and full-charge capacity only on the pack node.
    @Test func readerFillsMissingKeysFromThePackNode() throws {
        let health = try #require(reader(["AppleSmartBattery": battery, "AppleSmartBatteryPack": pack]).read())
        #expect(health.temperatureText == "31.9 °C")
        #expect(health.maximumCapacityText == "86%")       // 5389 from the pack ÷ 6249 from the battery
    }

    @Test func readerWorksWithoutAPackNode() throws {
        let health = try #require(reader(["AppleSmartBattery": battery]).read())
        #expect(health.cycleCount == 97)
        #expect(health.temperatureCelsius == nil)
    }

    /// A pack node alone isn't a battery the app can describe: no cycle count, no reading.
    @Test func noBatteryNodeMeansNoReading() {
        #expect(reader(["AppleSmartBatteryPack": pack]).read() == nil)
        #expect(reader([:]).read() == nil)
    }

    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func sample(_ seconds: TimeInterval, power: Bool = false) -> BatteryHistory.Sample {
        .init(date: t0.addingTimeInterval(seconds), percent: 50, onPower: power)
    }

    /// A sample exactly 24 hours old is kept; once it is older, it is dropped.
    @Test func pruningKeepsTheFull24HourWindow() {
        var history = BatteryHistory()
        history.record(sample(0))
        history.record(sample(120))
        history.record(sample(BatteryHistory.window))             // t0 is exactly 24 h old: kept
        #expect(history.samples.first?.date == t0)
        history.record(sample(BatteryHistory.window + 60))        // t0 now 24 h + 1 min: dropped;
        #expect(history.samples.first?.date == t0.addingTimeInterval(120))   // 120 s is 23 h 59 m old
    }

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let size = CGSize(width: 480, height: 200)
    private func at(hoursAgo: Double, power: Bool) -> BatteryHistory.Sample {
        .init(date: now.addingTimeInterval(-hoursAgo * 3600), percent: 50, onPower: power)
    }

    /// One bar per on-power stretch: a segment on power throughout is one bar from its first
    /// sample to its last, and two on-power segments either side of a gap stay two bars.
    @Test func onPowerBarsCoverWholeSegmentsAndNeverBridgeGaps() {
        let segments = [[at(hoursAgo: 12, power: true), at(hoursAgo: 9, power: true)],
                        [at(hoursAgo: 6, power: true), at(hoursAgo: 3, power: true)]]
        #expect(BatteryGraphGeometry.onPowerSpans(segments, now: now, in: size) == [240...300, 360...420])
    }

    /// Plugging in mid-segment starts the bar at that sample, not at the segment's start.
    @Test func barStartsWherePowerWasConnected() {
        let segments = [[at(hoursAgo: 12, power: false), at(hoursAgo: 6, power: true), at(hoursAgo: 0, power: true)]]
        #expect(BatteryGraphGeometry.onPowerSpans(segments, now: now, in: size) == [360...480])
    }
}
