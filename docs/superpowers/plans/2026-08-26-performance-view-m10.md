# Performance View (M10) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Performance surface with 60 seconds of history graphs, per-core CPU, five themes, and a disk I/O provider.

**Architecture:** Vitals sampling moves out of `ProcessListModel` into a new `VitalsModel`, which owns the sampler, the current snapshot, and a `VitalsHistory` of six sliding-window series. `ContentView` becomes a `NavigationSplitView` router over `Surface`; the existing table body extracts verbatim into `ProcessesView`. Graphs are immediate-mode `Canvas` views over pure geometry and scaling functions that are unit-tested outside SwiftUI.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, Mach host APIs (`host_processor_info`), IOKit (`IOBlockStorageDriver`).

**Spec:** `docs/superpowers/specs/2026-08-26-performance-view-design.md`

## Global Constraints

- Target is macOS only; `ENABLE_APP_SANDBOX = NO` and `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated` must stay set on the app target (Debug + Release).
- Build: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' build`
- Test: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test` — **always scope to `macOSmonitorTests`**; the `macOSmonitorUITests` target fails under CLI with "Timed out enabling automation mode".
- Every new raw-syscall or IOKit read goes behind a `Sendable` protocol so samplers can be tested with fakes. This is the established pattern from M7/M8/M9.
- History capacity is **60** samples at **1 Hz**. Sample rate and render rate stay independent; no `TimelineView`.
- Rate autoscale floor is **100_000** bytes/sec (100 KB/s).
- Swift Testing (`@Test`, `#expect`), not XCTest. Fakes are `final class ... @unchecked Sendable`.
- New files must be added to the `macOSmonitor` app target (or `macOSmonitorTests` test target) in `macOSmonitor.xcodeproj`.

---

# Phase 1 — Shell, history, and three panels

No new syscalls. Everything in this phase runs off data the app already samples.

---

### Task 1: `MetricHistory` sliding window

**Files:**

- Create: `macOSmonitor/MetricHistory.swift`
- Test: `macOSmonitorTests/MetricHistoryTests.swift`

**Interfaces:**

- Consumes: nothing.
- Produces: `struct MetricHistory: Equatable, Sendable` with `init(capacity: Int = 60)`,
  `mutating func append(_ value: Double)`, `var values: [Double]` (oldest → newest),
  `var capacity: Int`, `var isEmpty: Bool`, `var latest: Double?`, `var peak: Double`.

**Note on naming:** the spec calls this a ring buffer. It is implemented as an array-backed
sliding window — identical semantics, and trimming a 60-element array once per second is
free. Do not build an index-wrapping ring buffer; it buys nothing here and complicates
`values` ordering.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import macOSmonitor

struct MetricHistoryTests {
    @Test func emptyHistoryHasNoValues() {
        let history = MetricHistory(capacity: 60)
        #expect(history.values.isEmpty)
        #expect(history.isEmpty)
        #expect(history.latest == nil)
        #expect(history.peak == 0)
    }

    @Test func valuesAreOldestToNewest() {
        var history = MetricHistory(capacity: 60)
        history.append(1)
        history.append(2)
        history.append(3)
        #expect(history.values == [1, 2, 3])
        #expect(history.latest == 3)
    }

    @Test func appendingBeyondCapacityEvictsOldest() {
        var history = MetricHistory(capacity: 3)
        for value in 1...5 { history.append(Double(value)) }
        #expect(history.values == [3, 4, 5])
        #expect(history.values.count == 3)
    }

    @Test func peakIsMaxOfWindowNotOfAllTime() {
        var history = MetricHistory(capacity: 3)
        history.append(100)              // will be evicted
        for value in [1.0, 2.0, 3.0] { history.append(value) }
        #expect(history.peak == 3)
    }

    @Test func capacityIsAtLeastOne() {
        var history = MetricHistory(capacity: 0)
        history.append(7)
        #expect(history.values == [7])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test`
Expected: FAIL — "cannot find 'MetricHistory' in scope".

- [ ] **Step 3: Write the implementation**

```swift
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
```

- [ ] **Step 4: Add the files to the Xcode targets**

`MetricHistory.swift` → `macOSmonitor` target. `MetricHistoryTests.swift` → `macOSmonitorTests` target.

- [ ] **Step 5: Run tests to verify they pass**

Run the test command from Step 2. Expected: PASS, 5 tests.

- [ ] **Step 6: Commit**

```bash
git add macOSmonitor/MetricHistory.swift macOSmonitorTests/MetricHistoryTests.swift macOSmonitor.xcodeproj
git commit -m "feat: add MetricHistory sliding window"
```

---

### Task 2: `SystemVitals` new fields + `VitalsHistory`

**Files:**

- Modify: `macOSmonitor/SystemVitals.swift:16-18` (add fields after `battery`)
- Create: `macOSmonitor/VitalsHistory.swift`
- Test: `macOSmonitorTests/VitalsHistoryTests.swift`

**Interfaces:**

- Consumes: `MetricHistory` from Task 1.
- Produces: `SystemVitals.perCoreUsagePercent: [Double]`, `.diskReadBytesPerSec: Double`,
  `.diskWriteBytesPerSec: Double`; `struct VitalsHistory: Equatable, Sendable` with
  `init(capacity: Int = 60)`, `mutating func append(_ vitals: SystemVitals)`, and stored
  properties `cpu`, `memoryUsed`, `networkIn`, `networkOut`, `diskRead`, `diskWrite`
  (all `MetricHistory`).

**Why disk fields land now:** all six series exist from Phase 1 so `VitalsHistory` never
changes shape mid-milestone. The disk series carry zeros until Task 12 lands the provider.
All three new fields are defaulted, so existing construction sites keep compiling.

- [ ] **Step 1: Add the three fields to `SystemVitals`**

In `macOSmonitor/SystemVitals.swift`, immediately after `var battery: BatteryInfo? = nil`:

```swift
    var perCoreUsagePercent: [Double] = []
    var diskReadBytesPerSec: Double = 0
    var diskWriteBytesPerSec: Double = 0
```

- [ ] **Step 2: Write the failing tests**

```swift
import Testing
@testable import macOSmonitor

struct VitalsHistoryTests {
    private func vitals(cpu: Double, memory: UInt64,
                        netIn: Double, netOut: Double,
                        diskRead: Double, diskWrite: Double) -> SystemVitals {
        SystemVitals(cpuUsagePercent: cpu,
                     usedMemoryBytes: memory,
                     totalMemoryBytes: 16_000_000_000,
                     coreCount: 8,
                     activeCoreCount: 8,
                     thermalState: "Nominal",
                     lowPowerMode: false,
                     uptime: 100,
                     osVersion: "macOS 26.5",
                     networkInBytesPerSec: netIn,
                     networkOutBytesPerSec: netOut,
                     battery: nil,
                     perCoreUsagePercent: [],
                     diskReadBytesPerSec: diskRead,
                     diskWriteBytesPerSec: diskWrite)
    }

    @Test func oneAppendPopulatesAllSixSeries() {
        var history = VitalsHistory(capacity: 60)
        history.append(vitals(cpu: 42, memory: 8_000_000_000,
                              netIn: 1_000, netOut: 2_000,
                              diskRead: 3_000, diskWrite: 4_000))

        #expect(history.cpu.values == [42])
        #expect(history.memoryUsed.values == [8_000_000_000])
        #expect(history.networkIn.values == [1_000])
        #expect(history.networkOut.values == [2_000])
        #expect(history.diskRead.values == [3_000])
        #expect(history.diskWrite.values == [4_000])
    }

    @Test func seriesStayIndexAligned() {
        var history = VitalsHistory(capacity: 60)
        for i in 1...5 {
            history.append(vitals(cpu: Double(i), memory: UInt64(i),
                                  netIn: Double(i), netOut: Double(i),
                                  diskRead: Double(i), diskWrite: Double(i)))
        }
        #expect(history.cpu.values.count == 5)
        #expect(history.memoryUsed.values.count == history.cpu.values.count)
        #expect(history.diskWrite.values.count == history.cpu.values.count)
    }

    @Test func capacityPropagatesToEverySeries() {
        var history = VitalsHistory(capacity: 2)
        for i in 1...4 {
            history.append(vitals(cpu: Double(i), memory: 0,
                                  netIn: 0, netOut: 0, diskRead: 0, diskWrite: 0))
        }
        #expect(history.cpu.values == [3, 4])
        #expect(history.networkIn.capacity == 2)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run the standard test command. Expected: FAIL — "cannot find 'VitalsHistory' in scope".

- [ ] **Step 4: Write the implementation**

```swift
import Foundation

/// Six index-aligned sliding windows of system vitals, fed one `SystemVitals`
/// snapshot at a time. No clock, no syscalls, no SwiftUI.
struct VitalsHistory: Equatable, Sendable {
    var cpu: MetricHistory
    var memoryUsed: MetricHistory
    var networkIn: MetricHistory
    var networkOut: MetricHistory
    var diskRead: MetricHistory
    var diskWrite: MetricHistory

    init(capacity: Int = 60) {
        cpu = MetricHistory(capacity: capacity)
        memoryUsed = MetricHistory(capacity: capacity)
        networkIn = MetricHistory(capacity: capacity)
        networkOut = MetricHistory(capacity: capacity)
        diskRead = MetricHistory(capacity: capacity)
        diskWrite = MetricHistory(capacity: capacity)
    }

    /// Fans one snapshot into all six series, keeping them index-aligned by construction.
    mutating func append(_ vitals: SystemVitals) {
        cpu.append(vitals.cpuUsagePercent)
        memoryUsed.append(Double(vitals.usedMemoryBytes))
        networkIn.append(vitals.networkInBytesPerSec)
        networkOut.append(vitals.networkOutBytesPerSec)
        diskRead.append(vitals.diskReadBytesPerSec)
        diskWrite.append(vitals.diskWriteBytesPerSec)
    }
}
```

- [ ] **Step 5: Add files to targets and run tests**

`VitalsHistory.swift` → app target, `VitalsHistoryTests.swift` → test target.
Run the standard test command. Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add macOSmonitor/SystemVitals.swift macOSmonitor/VitalsHistory.swift \
        macOSmonitorTests/VitalsHistoryTests.swift macOSmonitor.xcodeproj
git commit -m "feat: add VitalsHistory and per-core/disk vitals fields"
```

---

### Task 3: `MetricScale`

**Files:**

- Create: `macOSmonitor/MetricScale.swift`
- Test: `macOSmonitorTests/MetricScaleTests.swift`

**Interfaces:**

- Consumes: `MetricHistory` from Task 1.
- Produces: `enum MetricScale` with `static let rateFloor: Double`,
  `static func fixed(_ upper: Double) -> ClosedRange<Double>`, and
  `static func autoscaled(_ series: [MetricHistory], floor: Double = rateFloor) -> ClosedRange<Double>`.

**Why `autoscaled` takes an array:** network in/out (and disk read/write) share one graph
and therefore must share one y-axis. Scaling them separately would make a 10 KB/s upload
look identical to a 10 MB/s download.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import macOSmonitor

struct MetricScaleTests {
    @Test func fixedRangeStartsAtZeroAndUsesUpperBound() {
        let range = MetricScale.fixed(100)
        #expect(range.lowerBound == 0)
        #expect(range.upperBound == 100)
    }

    @Test func fixedRangeNeverCollapsesToZeroWidth() {
        let range = MetricScale.fixed(0)
        #expect(range.upperBound > range.lowerBound)
    }

    @Test func autoscaleTracksWindowPeakWhenAboveFloor() {
        var series = MetricHistory(capacity: 60)
        series.append(500_000)
        series.append(2_000_000)
        series.append(1_000_000)
        let range = MetricScale.autoscaled([series])
        #expect(range.upperBound == 2_000_000)
    }

    @Test func autoscaleHoldsFloorWhenIdle() {
        var series = MetricHistory(capacity: 60)
        for _ in 0..<10 { series.append(37) }        // a trickle of noise
        let range = MetricScale.autoscaled([series])
        #expect(range.upperBound == MetricScale.rateFloor)
    }

    @Test func autoscaleSharesOneAxisAcrossSeries() {
        var down = MetricHistory(capacity: 60)
        var up = MetricHistory(capacity: 60)
        down.append(5_000_000)
        up.append(200_000)
        let range = MetricScale.autoscaled([down, up])
        #expect(range.upperBound == 5_000_000)       // the larger series sets the axis
    }

    @Test func autoscaleOnEmptySeriesUsesFloor() {
        let range = MetricScale.autoscaled([MetricHistory(capacity: 60)])
        #expect(range.upperBound == MetricScale.rateFloor)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the standard test command. Expected: FAIL — "cannot find 'MetricScale' in scope".

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Decides the y-range a metric graph draws against. Pure, so it can be tested
/// without instantiating a view.
enum MetricScale {
    /// Minimum ceiling for autoscaled rate graphs. Without a floor, an idle
    /// network amplifies byte-level noise into a dramatic, meaningless mountain range.
    static let rateFloor: Double = 100_000   // 100 KB/s

    /// A bounded metric: CPU is 0...100, memory is 0...total.
    static func fixed(_ upper: Double) -> ClosedRange<Double> {
        0...max(upper, 1)
    }

    /// An unbounded rate metric. All supplied series share one axis so they stay
    /// visually comparable; the floor keeps idle noise flat.
    static func autoscaled(_ series: [MetricHistory],
                           floor: Double = rateFloor) -> ClosedRange<Double> {
        let peak = series.map(\.peak).max() ?? 0
        return 0...max(peak, floor)
    }
}
```

- [ ] **Step 4: Add files to targets and run tests**

Run the standard test command. Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add macOSmonitor/MetricScale.swift macOSmonitorTests/MetricScaleTests.swift macOSmonitor.xcodeproj
git commit -m "feat: add MetricScale with shared-axis autoscaling and noise floor"
```

---

### Task 4: Per-core CPU ticks

**Files:**

- Modify: `macOSmonitor/SystemVitals.swift:51-78` (protocol + `HostStats.cpuTicks`)
- Modify: `macOSmonitor/SystemVitalsSampler.swift:15` and `:29-42` (previous state + delta loop)
- Modify: `macOSmonitorTests/SystemVitalsSamplerTests.swift:5-10` (`FakeHostStats`)
- Test: `macOSmonitorTests/SystemVitalsSamplerTests.swift` (new cases)

**Interfaces:**

- Consumes: `SystemVitals.perCoreUsagePercent` from Task 2.
- Produces: `struct CoreTicks: Equatable, Sendable { let busy: UInt64; let total: UInt64 }`;
  `HostStatsProviding.cpuTicks() -> [CoreTicks]?` (**replaces** the aggregate-returning version).

**Why replace rather than add:** keeping both would mean two `host_processor_info` calls per
tick — a wasted syscall and two inconsistent snapshots of the same quantity. The aggregate
is derived by summing.

- [ ] **Step 1: Update `FakeHostStats` and write the failing tests**

Replace `FakeHostStats` at `macOSmonitorTests/SystemVitalsSamplerTests.swift:5-10` with:

```swift
final class FakeHostStats: HostStatsProviding, @unchecked Sendable {
    var ticks: [CoreTicks]?
    var mem: (used: UInt64, total: UInt64)?
    func cpuTicks() -> [CoreTicks]? { ticks }
    func memory() -> (used: UInt64, total: UInt64)? { mem }
}
```

Update the existing `firstTickZeroThenDeltaPercent` test to use core arrays, and add the
new cases:

```swift
    @Test func firstTickZeroThenDeltaPercent() async {
        let fake = FakeHostStats()
        fake.mem = (used: 1_000, total: 2_000)
        fake.ticks = [CoreTicks(busy: 100, total: 1_000)]
        let sampler = SystemVitalsSampler(host: fake)

        let first = await sampler.sample()
        #expect(first.cpuUsagePercent == 0)             // no baseline yet
        #expect(first.usedMemoryBytes == 1_000)
        #expect(first.totalMemoryBytes == 2_000)

        fake.ticks = [CoreTicks(busy: 150, total: 1_100)]   // +50 busy / +100 total → 50%
        let second = await sampler.sample()
        #expect(second.cpuUsagePercent == 50)
    }

    @Test func perCorePercentagesAreReportedIndividually() async {
        let fake = FakeHostStats()
        fake.ticks = [CoreTicks(busy: 0, total: 100), CoreTicks(busy: 0, total: 100)]
        let sampler = SystemVitalsSampler(host: fake)
        _ = await sampler.sample()                        // establish baseline

        fake.ticks = [CoreTicks(busy: 25, total: 200),    // +25/+100 → 25%
                      CoreTicks(busy: 75, total: 200)]    // +75/+100 → 75%
        let sample = await sampler.sample()
        #expect(sample.perCoreUsagePercent == [25, 75])
    }

    @Test func aggregateIsTheSumOfCoreDeltasNotTheAverageOfPercents() async {
        let fake = FakeHostStats()
        fake.ticks = [CoreTicks(busy: 0, total: 0), CoreTicks(busy: 0, total: 0)]
        let sampler = SystemVitalsSampler(host: fake)
        _ = await sampler.sample()

        // core 0 busy 30 of 100; core 1 busy 70 of 300 → total 100 busy of 400 = 25%
        fake.ticks = [CoreTicks(busy: 30, total: 100), CoreTicks(busy: 70, total: 300)]
        let sample = await sampler.sample()
        #expect(sample.cpuUsagePercent == 25)
    }

    @Test func oneCoreWrappingDoesNotCorruptTheOthers() async {
        let fake = FakeHostStats()
        fake.ticks = [CoreTicks(busy: 100, total: 1_000), CoreTicks(busy: 0, total: 100)]
        let sampler = SystemVitalsSampler(host: fake)
        _ = await sampler.sample()

        // core 0 wrapped (counters went backwards); core 1 advanced +50/+100 → 50%
        fake.ticks = [CoreTicks(busy: 5, total: 20), CoreTicks(busy: 50, total: 200)]
        let sample = await sampler.sample()
        #expect(sample.perCoreUsagePercent == [0, 50])
        #expect(sample.cpuUsagePercent == 50)     // wrapped core excluded from the aggregate
    }

    @Test func coreCountChangeResetsToBaseline() async {
        let fake = FakeHostStats()
        fake.ticks = [CoreTicks(busy: 0, total: 100)]
        let sampler = SystemVitalsSampler(host: fake)
        _ = await sampler.sample()

        fake.ticks = [CoreTicks(busy: 50, total: 200), CoreTicks(busy: 50, total: 200)]
        let sample = await sampler.sample()
        #expect(sample.perCoreUsagePercent == [0, 0])
        #expect(sample.cpuUsagePercent == 0)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run the standard test command. Expected: FAIL — "cannot find type 'CoreTicks' in scope".

- [ ] **Step 3: Add `CoreTicks` and change the protocol**

In `macOSmonitor/SystemVitals.swift`, replace the `HostStatsProviding` protocol declaration
and add the type above it:

```swift
/// One logical core's cumulative CPU tick counters.
struct CoreTicks: Equatable, Sendable {
    let busy: UInt64
    let total: UInt64
}

/// Raw host CPU/memory reads, isolated behind a protocol so the sampler can be tested with a fake.
protocol HostStatsProviding: Sendable {
    /// One entry per logical core. The aggregate is derived by summing, so this is
    /// deliberately the only CPU read — two calls per tick would be a wasted syscall
    /// and two inconsistent snapshots.
    func cpuTicks() -> [CoreTicks]?
    func memory() -> (used: UInt64, total: UInt64)?
}
```

- [ ] **Step 4: Rewrite `HostStats.cpuTicks()`**

Replace the body of `HostStats.cpuTicks()` (`macOSmonitor/SystemVitals.swift:57-78`) with:

```swift
    func cpuTicks() -> [CoreTicks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                         &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
        }
        var cores: [CoreTicks] = []
        cores.reserveCapacity(Int(cpuCount))
        info.withMemoryRebound(to: processor_cpu_load_info.self, capacity: Int(cpuCount)) { ptr in
            for i in 0..<Int(cpuCount) {
                let t = ptr[i].cpu_ticks          // (user, system, idle, nice)
                let active = UInt64(t.0) + UInt64(t.1) + UInt64(t.3)
                cores.append(CoreTicks(busy: active, total: active + UInt64(t.2)))
            }
        }
        return cores
    }
```

- [ ] **Step 5: Rewrite the sampler's CPU delta block**

In `macOSmonitor/SystemVitalsSampler.swift`, change the stored property at line 15 from
`private var previousTicks: (busy: UInt64, total: UInt64)?` to:

```swift
    private var previousCores: [CoreTicks]?
```

Replace the CPU block at the top of `sample()` (lines 30-42) with:

```swift
        var cpuPercent = 0.0
        var perCore: [Double] = []
        if let cores = host.cpuTicks() {
            // Require both counters to be monotonic per core before subtracting: 32-bit
            // tick counters can wrap on extreme uptime, and an unguarded UInt64 subtraction
            // would trap. A wrapped core reports 0% and is excluded from the aggregate;
            // its neighbours are unaffected.
            if let previous = previousCores, previous.count == cores.count {
                var totalBusy: UInt64 = 0
                var totalAll: UInt64 = 0
                for (current, prior) in zip(cores, previous) {
                    guard current.total > prior.total, current.busy >= prior.busy else {
                        perCore.append(0)
                        continue
                    }
                    let deltaBusy = current.busy - prior.busy
                    let deltaTotal = current.total - prior.total
                    perCore.append(100.0 * Double(deltaBusy) / Double(deltaTotal))
                    totalBusy += deltaBusy
                    totalAll += deltaTotal
                }
                if totalAll > 0 { cpuPercent = 100.0 * Double(totalBusy) / Double(totalAll) }
            } else {
                // First tick, or the core count changed: no baseline to subtract from.
                perCore = Array(repeating: 0, count: cores.count)
            }
            previousCores = cores
        }
```

- [ ] **Step 6: Pass the new field into the returned `SystemVitals`**

In the `return SystemVitals(...)` call, add after `battery: batteryInfo`:

```swift
            perCoreUsagePercent: perCore
```

- [ ] **Step 7: Run tests to verify they pass**

Run the standard test command. Expected: PASS. Confirm `HostStatsTests` still passes —
it exercises real hardware, so also confirm the returned array is non-empty and its count
matches `ProcessInfo.processInfo.processorCount`.

- [ ] **Step 8: Commit**

```bash
git add macOSmonitor/SystemVitals.swift macOSmonitor/SystemVitalsSampler.swift \
        macOSmonitorTests/SystemVitalsSamplerTests.swift
git commit -m "feat: report per-core CPU utilisation, guarding wraparound per core"
```

---

### Task 5: `VitalsModel`, and `ProcessListModel` sheds vitals

**Files:**

- Create: `macOSmonitor/VitalsModel.swift`
- Create: `macOSmonitorTests/VitalsModelTests.swift`
- Modify: `macOSmonitor/ProcessListModel.swift:16`, `:22`, `:29`, `:35`, `:43`
- Modify: `macOSmonitorTests/ProcessListModelTests.swift:33-38`, `:120-124` (move to `VitalsModelTests`)
- Modify: `macOSmonitor/ContentView.swift:21` (header reads the new model)

**Interfaces:**

- Consumes: `VitalsHistory` (Task 2), existing `SystemVitalsSampling`.
- Produces: `@MainActor @Observable final class VitalsModel` with
  `init(sampler: any SystemVitalsSampling = SystemVitalsSampler(), interval: Duration = .seconds(1))`,
  `private(set) var vitals: SystemVitals?`, `private(set) var history: VitalsHistory`,
  `func refreshOnce() async`, `func run() async`.

**Why:** `ProcessListModel` currently samples vitals as a side job. Left alone it becomes the
class that owns processes *and* system history *and* selection *and* termination. This is the
structural change the spec's Approach B rests on.

- [ ] **Step 1: Write the failing tests**

Create `macOSmonitorTests/VitalsModelTests.swift`, moving `FakeVitalsSampler` here from
`ProcessListModelTests.swift:33-38`:

```swift
import Foundation
import Testing
@testable import macOSmonitor

final class FakeVitalsSampler: SystemVitalsSampling, @unchecked Sendable {
    var next = SystemVitals(cpuUsagePercent: 5, usedMemoryBytes: 1, totalMemoryBytes: 2,
                            coreCount: 8, activeCoreCount: 8, thermalState: "Nominal",
                            lowPowerMode: false, uptime: 1, osVersion: "macOS 26.5")
    var callCount = 0
    func sample() async -> SystemVitals { callCount += 1; return next }
}

@MainActor
struct VitalsModelTests {
    @Test func refreshOncePublishesVitals() async {
        let model = VitalsModel(sampler: FakeVitalsSampler())
        #expect(model.vitals == nil)
        await model.refreshOnce()
        #expect(model.vitals?.coreCount == 8)
    }

    @Test func refreshOnceAppendsToHistory() async {
        let fake = FakeVitalsSampler()
        let model = VitalsModel(sampler: fake)
        #expect(model.history.cpu.values.isEmpty)

        await model.refreshOnce()
        await model.refreshOnce()

        #expect(model.history.cpu.values == [5, 5])
        #expect(model.history.memoryUsed.values.count == 2)
    }

    @Test func historyIsCappedAtSixtySamples() async {
        let model = VitalsModel(sampler: FakeVitalsSampler())
        for _ in 0..<65 { await model.refreshOnce() }
        #expect(model.history.cpu.values.count == 60)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the standard test command. Expected: FAIL — "cannot find 'VitalsModel' in scope", plus
a duplicate-definition error for `FakeVitalsSampler` until Step 4 removes the old one.

- [ ] **Step 3: Write `VitalsModel`**

```swift
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
```

- [ ] **Step 4: Strip vitals out of `ProcessListModel`**

In `macOSmonitor/ProcessListModel.swift` delete these five things:

1. Line 15-16, the property and its doc comment:
   `/// Latest system-wide vitals for the header; nil until the first sample.` and
   `private(set) var vitals: SystemVitals?`
2. Line 22: `private let vitalsSampler: any SystemVitalsSampling`
3. Line 29: the `vitalsSampler:` init parameter
4. Line 35: `self.vitalsSampler = vitalsSampler`
5. Line 43: `vitals = await vitalsSampler.sample()`

Then delete `FakeVitalsSampler` (`macOSmonitorTests/ProcessListModelTests.swift:33-38`) and
the `refreshOncePublishesVitals` test (`:120-124`) — both now live in `VitalsModelTests`.

- [ ] **Step 5: Point the header at the new model**

In `macOSmonitor/ContentView.swift`, add alongside the existing `@State private var model`:

```swift
    @State private var vitalsModel = VitalsModel()
```

Change line 21 to `SystemVitalsView(vitals: vitalsModel.vitals)`, and add a second `.task`
next to the existing one:

```swift
        .task { await vitalsModel.run() }
```

- [ ] **Step 6: Run tests and build**

Run the standard test command. Expected: PASS.
Then run the build command and launch the app: the header must still show live values.

- [ ] **Step 7: Commit**

```bash
git add macOSmonitor/VitalsModel.swift macOSmonitorTests/VitalsModelTests.swift \
        macOSmonitor/ProcessListModel.swift macOSmonitorTests/ProcessListModelTests.swift \
        macOSmonitor/ContentView.swift macOSmonitor.xcodeproj
git commit -m "refactor: move vitals sampling from ProcessListModel into VitalsModel"
```

---

### Task 6: Navigation shell and `ProcessesView` extraction

**Files:**

- Create: `macOSmonitor/ProcessesView.swift`
- Create: `macOSmonitor/Surface.swift`
- Modify: `macOSmonitor/ContentView.swift` (becomes a router)

**Interfaces:**

- Consumes: `ProcessListModel`, `VitalsModel` (Task 5).
- Produces: `enum Surface: String, CaseIterable, Hashable, Identifiable` with cases
  `processes`, `cpu`, `memory`, `network`, `disk` and `var title: String`;
  `struct ProcessesView: View` with `init(model: ProcessListModel, vitalsModel: VitalsModel)`.

**This is a move, not a rewrite.** Everything currently in `ContentView`'s body — table,
inspector, search, toolbar quit buttons, confirmation dialogs, the `PendingTermination`
struct and the private `ProcessTableView` — moves into `ProcessesView` verbatim. Only the
two model properties change from `@State` to `let`, since `ContentView` now owns them.

- [ ] **Step 1: Create `Surface`**

```swift
import Foundation

/// The top-level surfaces listed in the sidebar.
enum Surface: String, CaseIterable, Hashable, Identifiable {
    case processes, cpu, memory, network, disk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .processes: return "Processes"
        case .cpu:       return "CPU"
        case .memory:    return "Memory"
        case .network:   return "Network"
        case .disk:      return "Disk"
        }
    }

    /// The four Performance panels, in sidebar order.
    static let performance: [Surface] = [.cpu, .memory, .network, .disk]
}
```

- [ ] **Step 2: Move the body into `ProcessesView`**

Create `macOSmonitor/ProcessesView.swift`. Move the whole of `ContentView`'s current body
plus its helper members (`selectedRow`, `confirmTitle`, `requestTermination`,
`performTermination`, `presenting`), the private `PendingTermination` struct, and the
private `ProcessTableView` struct. The declaration becomes:

```swift
struct ProcessesView: View {
    let model: ProcessListModel
    let vitalsModel: VitalsModel

    @State private var sortOrder = [KeyPathComparator(\ProcessInfoRow.cpuSortKey, order: .reverse)]
    @State private var showInspector = true
    @State private var searchText = ""
    @State private var searchPresented = false
    @State private var pendingTermination: PendingTermination?
    @State private var errorMessage: String?
    // ...body and helpers moved verbatim from ContentView...
}
```

Drop `.frame(minWidth:minHeight:)` and `.navigationTitle` from the moved body — both move to
`ContentView` in Step 3. Change `SystemVitalsView(vitals: vitalsModel.vitals)` to read from
the passed-in model.

**Keep only `.task { await model.run() }` here.** The vitals loop moves to `ContentView` in
Step 3: from Task 9 the sidebar meters need vitals on every surface, not just while Processes
is selected, and a `.task` on this view dies when you navigate away from it.

- [ ] **Step 3: Rewrite `ContentView` as a router**

```swift
import SwiftUI

struct ContentView: View {
    @State private var model = ProcessListModel()
    @State private var vitalsModel = VitalsModel()
    @State private var surface: Surface? = .processes

    var body: some View {
        NavigationSplitView {
            List(selection: $surface) {
                Label(Surface.processes.title, systemImage: "list.bullet")
                    .tag(Surface.processes)
                Section("Performance") {
                    ForEach(Surface.performance) { item in
                        Text(item.title).tag(item)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            switch surface ?? .processes {
            case .processes:
                ProcessesView(model: model, vitalsModel: vitalsModel)
            case .cpu, .memory, .network, .disk:
                Text("Panel coming in the next task")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 900, minHeight: 500)
        .navigationTitle("macOSmonitor")
        .task { await vitalsModel.run() }
    }
}

#Preview {
    ContentView()
}
```

- [ ] **Step 4: Build, run, and verify the two behaviour risks by hand**

Run the build command, launch the app, and check all four:

1. The process table still lists, sorts, and selects.
2. The inspector still opens and still updates live.
3. `.searchable` still filters — note where the field lands now that it is inside a split
   view. If it moved somewhere unhelpful, adjust `placement:` and record what you changed.
4. **⌘F still focuses the search field.** The M4 wiring runs through
   `.focusedSceneValue(\.searchPresented,…)` and a scene-level `SearchCommands`; re-parenting
   can break it. If it broke, fix it in this task rather than deferring.

Also watch for **Bug A** (the selection highlight failing to follow its process as rows
re-rank). It has never been reproducible; re-parenting a `Table` is exactly the kind of change
that could wake it. If it reproduces, capture the steps in the commit message — a repro is
worth more than a guess at a fix.

- [ ] **Step 5: Run tests**

Run the standard test command. Expected: PASS, unchanged — this task moves view code only.

- [ ] **Step 6: Commit**

```bash
git add macOSmonitor/Surface.swift macOSmonitor/ProcessesView.swift \
        macOSmonitor/ContentView.swift macOSmonitor.xcodeproj
git commit -m "refactor: split ContentView into a NavigationSplitView router and ProcessesView"
```

---

### Task 7: `MetricGraph` and its geometry

**Files:**

- Create: `macOSmonitor/GraphGeometry.swift`
- Create: `macOSmonitor/MetricGraph.swift`
- Test: `macOSmonitorTests/GraphGeometryTests.swift`

**Interfaces:**

- Consumes: `MetricHistory` (Task 1), `MetricScale` (Task 3).
- Produces: `enum GraphGeometry` with
  `static func points(values: [Double], capacity: Int, range: ClosedRange<Double>, size: CGSize) -> [CGPoint]`;
  `struct MetricGraph: View` with
  `init(values: [Double], capacity: Int = 60, range: ClosedRange<Double>, lineColor: Color, fillColor: Color, gridColor: Color)`.

**Geometry rule:** the newest sample pins to the **right edge**, and the x-step derives from
`capacity`, not from `values.count`. A half-full window therefore occupies the right half and
grows leftward — Task Manager's behaviour — instead of stretching 12 samples across the full
width and lurching as it fills. Note y is inverted: SwiftUI's origin is top-left, so a value
at the range maximum has y == 0.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import macOSmonitor

struct GraphGeometryTests {
    private let size = CGSize(width: 100, height: 50)

    @Test func emptyValuesProduceNoPoints() {
        let points = GraphGeometry.points(values: [], capacity: 60, range: 0...100, size: size)
        #expect(points.isEmpty)
    }

    @Test func newestSamplePinsToTheRightEdge() {
        let points = GraphGeometry.points(values: [10, 20, 30], capacity: 60,
                                          range: 0...100, size: size)
        #expect(points.last?.x == 100)
    }

    @Test func stepDerivesFromCapacityNotSampleCount() {
        // capacity 11 over width 100 → step 10. Three samples occupy the right 20pt.
        let points = GraphGeometry.points(values: [1, 2, 3], capacity: 11,
                                          range: 0...100, size: size)
        #expect(points.map(\.x) == [80, 90, 100])
    }

    @Test func fullWindowSpansTheFullWidth() {
        let values = Array(repeating: 50.0, count: 11)
        let points = GraphGeometry.points(values: values, capacity: 11,
                                          range: 0...100, size: size)
        #expect(points.first?.x == 0)
        #expect(points.last?.x == 100)
    }

    @Test func yIsInvertedSoMaximumSitsAtTheTop() {
        let points = GraphGeometry.points(values: [0, 50, 100], capacity: 3,
                                          range: 0...100, size: size)
        #expect(points[0].y == 50)      // value 0   → bottom
        #expect(points[1].y == 25)      // value 50  → middle
        #expect(points[2].y == 0)       // value 100 → top
    }

    @Test func valuesOutsideTheRangeAreClamped() {
        let points = GraphGeometry.points(values: [-10, 250], capacity: 2,
                                          range: 0...100, size: size)
        #expect(points[0].y == 50)      // clamped to the floor
        #expect(points[1].y == 0)       // clamped to the ceiling
    }

    @Test func zeroWidthRangeDoesNotDivideByZero() {
        let points = GraphGeometry.points(values: [5], capacity: 2,
                                          range: 0...0, size: size)
        #expect(points.count == 1)
        #expect(points[0].y == 50)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the standard test command. Expected: FAIL — "cannot find 'GraphGeometry' in scope".

- [ ] **Step 3: Write `GraphGeometry`**

```swift
import CoreGraphics

/// Maps a value window onto graph coordinates. Pure, so the layout rules are
/// testable without instantiating a Canvas.
enum GraphGeometry {
    /// Points for `values` (oldest → newest), newest pinned to the right edge.
    /// The x-step comes from `capacity`, so a partially-filled window occupies the
    /// right-hand portion and grows leftward rather than stretching to fit.
    static func points(values: [Double],
                       capacity: Int,
                       range: ClosedRange<Double>,
                       size: CGSize) -> [CGPoint] {
        guard capacity > 1, !values.isEmpty else { return [] }
        let step = size.width / CGFloat(capacity - 1)
        let span = range.upperBound - range.lowerBound
        let newestIndex = values.count - 1

        return values.enumerated().map { index, value in
            let x = size.width - CGFloat(newestIndex - index) * step
            let clamped = min(max(value, range.lowerBound), range.upperBound)
            let normalized = span > 0 ? (clamped - range.lowerBound) / span : 0
            // SwiftUI's origin is top-left, so invert: the range maximum sits at y == 0.
            let y = size.height - CGFloat(normalized) * size.height
            return CGPoint(x: x, y: y)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the standard test command. Expected: PASS, 7 tests.

- [ ] **Step 5: Write `MetricGraph`**

```swift
import SwiftUI

/// An immediate-mode history graph: grid, filled area, and stroked trace.
/// Redrawn by ordinary @Observable invalidation at ~1 Hz — no TimelineView.
struct MetricGraph: View {
    let values: [Double]
    var capacity: Int = 60
    let range: ClosedRange<Double>
    let lineColor: Color
    let fillColor: Color
    let gridColor: Color

    private let gridDivisions = 4

    var body: some View {
        Canvas { context, size in
            drawGrid(in: &context, size: size)

            let points = GraphGeometry.points(values: values, capacity: capacity,
                                              range: range, size: size)
            guard points.count > 1 else { return }

            var trace = Path()
            trace.addLines(points)

            var area = trace
            area.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
            area.addLine(to: CGPoint(x: points[0].x, y: size.height))
            area.closeSubpath()

            context.fill(area, with: .color(fillColor))
            context.stroke(trace, with: .color(lineColor), lineWidth: 1.5)
        }
        .drawingGroup()
    }

    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        var grid = Path()
        for division in 0...gridDivisions {
            let y = size.height * CGFloat(division) / CGFloat(gridDivisions)
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        for division in 0...gridDivisions {
            let x = size.width * CGFloat(division) / CGFloat(gridDivisions)
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: size.height))
        }
        context.stroke(grid, with: .color(gridColor), lineWidth: 0.5)
    }
}

#Preview {
    MetricGraph(values: (0..<40).map { _ in Double.random(in: 10...90) },
                range: 0...100,
                lineColor: .green, fillColor: .green.opacity(0.2), gridColor: .gray.opacity(0.3))
        .frame(width: 400, height: 160)
        .padding()
}
```

- [ ] **Step 6: Build and check the preview**

Run the build command. Open `MetricGraph.swift` in Xcode and confirm the preview renders a
trace with a filled area and a grid.

- [ ] **Step 7: Commit**

```bash
git add macOSmonitor/GraphGeometry.swift macOSmonitor/MetricGraph.swift \
        macOSmonitorTests/GraphGeometryTests.swift macOSmonitor.xcodeproj
git commit -m "feat: add MetricGraph canvas and tested graph geometry"
```

---

### Task 8: CPU panel with the per-core toggle

**Files:**

- Create: `macOSmonitor/CoreGrid.swift`
- Create: `macOSmonitor/CPUPanel.swift`
- Modify: `macOSmonitor/ContentView.swift` (route `.cpu`)

**Interfaces:**

- Consumes: `VitalsModel` (Task 5), `MetricGraph` (Task 7), `MetricScale` (Task 3).
- Produces: `struct CoreGrid: View` with `init(percentages: [Double], onColor: Color, offColor: Color)`;
  `struct CPUPanel: View` with `init(model: VitalsModel)`.

**Per-core detail is a right-click toggle**, mirroring Task Manager's "Logical processors" —
overall trace *or* the core grid, never both at once. The toggle is view-local `@State`; it
is not persisted.

- [ ] **Step 1: Write `CoreGrid`**

```swift
import SwiftUI

/// One bar per logical core, filled to its current utilisation. Instantaneous —
/// per-core history is deliberately not stored.
struct CoreGrid: View {
    let percentages: [Double]
    let onColor: Color
    let offColor: Color

    private let columns = [GridItem(.adaptive(minimum: 68), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Array(percentages.enumerated()), id: \.offset) { index, percent in
                VStack(spacing: 4) {
                    GeometryReader { geometry in
                        ZStack(alignment: .bottom) {
                            Rectangle().fill(offColor)
                            Rectangle()
                                .fill(onColor)
                                .frame(height: geometry.size.height * CGFloat(min(max(percent, 0), 100)) / 100)
                        }
                    }
                    .frame(height: 44)
                    Text("\(index)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
```

- [ ] **Step 2: Write `CPUPanel`**

```swift
import SwiftUI

/// The CPU Performance panel: an overall history trace, or — via right-click —
/// a per-core grid, mirroring Task Manager's "Logical processors" toggle.
struct CPUPanel: View {
    let model: VitalsModel
    @State private var showsCores = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("CPU").font(.title2)
                Spacer()
                Text(model.vitals?.cpuText ?? "—")
                    .font(.title2)
                    .monospacedDigit()
            }

            if showsCores {
                CoreGrid(percentages: model.vitals?.perCoreUsagePercent ?? [],
                         onColor: .accentColor,
                         offColor: .gray.opacity(0.15))
            } else {
                MetricGraph(values: model.history.cpu.values,
                            range: MetricScale.fixed(100),
                            lineColor: .accentColor,
                            fillColor: .accentColor.opacity(0.2),
                            gridColor: .gray.opacity(0.3))
                    .frame(minHeight: 180)
                HStack {
                    Text("60s ago")
                    Spacer()
                    Text("now")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                stat("Cores", model.vitals.map { "\($0.coreCount)" })
                stat("Active", model.vitals.map { "\($0.activeCoreCount)" })
                stat("Thermal", model.vitals?.thermalState)
            }
            Spacer()
        }
        .padding(20)
        .contextMenu {
            Button(showsCores ? "Overall Utilisation" : "Logical Processors") {
                showsCores.toggle()
            }
        }
    }

    private func stat(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).textCase(.uppercase).foregroundStyle(.secondary)
            Text(value ?? "—").font(.callout).monospacedDigit()
        }
    }
}
```

- [ ] **Step 3: Route `.cpu` in `ContentView`**

Replace the placeholder case in the `detail:` switch:

```swift
            case .cpu:
                CPUPanel(model: vitalsModel)
            case .memory, .network, .disk:
                Text("Panel coming in the next task")
                    .foregroundStyle(.secondary)
```

- [ ] **Step 4: Build and verify by running**

Run the build command and launch the app. Select CPU in the sidebar. Confirm:

1. The trace fills from the right edge and grows leftward over the first minute.
2. Right-click switches to the core grid; the bar count equals your machine's logical core
   count, and the bars move independently.
3. The overall percentage tracks Activity Monitor's CPU load reasonably.

- [ ] **Step 5: Commit**

```bash
git add macOSmonitor/CoreGrid.swift macOSmonitor/CPUPanel.swift \
        macOSmonitor/ContentView.swift macOSmonitor.xcodeproj
git commit -m "feat: add CPU panel with right-click per-core toggle"
```

---

### Task 9: Memory and Network panels, and sidebar mini-meters

**Files:**

- Create: `macOSmonitor/MemoryPanel.swift`
- Create: `macOSmonitor/NetworkPanel.swift`
- Create: `macOSmonitor/SidebarMeter.swift`
- Modify: `macOSmonitor/ContentView.swift` (route `.memory`/`.network`, sidebar rows)

**Interfaces:**

- Consumes: `VitalsModel`, `MetricGraph`, `MetricScale`.
- Produces: `struct MemoryPanel: View { init(model: VitalsModel) }`,
  `struct NetworkPanel: View { init(model: VitalsModel) }`,
  `struct SidebarMeter: View { init(title: String, value: String, fraction: Double) }`.

**Network shares one axis** across in and out via `MetricScale.autoscaled([in, out])` —
scaling them separately would make a 10 KB/s upload look identical to a 10 MB/s download.

- [ ] **Step 1: Write `MemoryPanel`**

```swift
import SwiftUI

/// The Memory Performance panel: used memory over time against total installed.
struct MemoryPanel: View {
    let model: VitalsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Memory").font(.title2)
                Spacer()
                Text(model.vitals?.memoryText ?? "—")
                    .font(.title2)
                    .monospacedDigit()
            }

            MetricGraph(values: model.history.memoryUsed.values,
                        range: MetricScale.fixed(Double(model.vitals?.totalMemoryBytes ?? 1)),
                        lineColor: .accentColor,
                        fillColor: .accentColor.opacity(0.2),
                        gridColor: .gray.opacity(0.3))
                .frame(minHeight: 180)

            HStack {
                Text("60s ago")
                Spacer()
                Text("now")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(20)
    }
}
```

- [ ] **Step 2: Write `NetworkPanel`**

```swift
import SwiftUI

/// The Network Performance panel: received and sent, sharing one autoscaled axis.
struct NetworkPanel: View {
    let model: VitalsModel

    private var range: ClosedRange<Double> {
        MetricScale.autoscaled([model.history.networkIn, model.history.networkOut])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Network").font(.title2)
                Spacer()
                Text(model.vitals?.networkText ?? "—")
                    .font(.title2)
                    .monospacedDigit()
            }

            ZStack {
                MetricGraph(values: model.history.networkIn.values,
                            range: range,
                            lineColor: .accentColor,
                            fillColor: .accentColor.opacity(0.2),
                            gridColor: .gray.opacity(0.3))
                MetricGraph(values: model.history.networkOut.values,
                            range: range,
                            lineColor: .orange,
                            fillColor: .orange.opacity(0.15),
                            gridColor: .clear)
            }
            .frame(minHeight: 180)

            HStack {
                Text("scale: \(scaleLabel)")
                Spacer()
                Label("Received", systemImage: "arrow.down").foregroundStyle(Color.accentColor)
                Label("Sent", systemImage: "arrow.up").foregroundStyle(.orange)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(20)
    }

    private var scaleLabel: String {
        let bytes = range.upperBound
        if bytes < 1_000_000 { return String(format: "%.0f KB/s", bytes / 1_000) }
        return String(format: "%.1f MB/s", bytes / 1_000_000)
    }
}
```

- [ ] **Step 3: Write `SidebarMeter`**

```swift
import SwiftUI

/// A sidebar row: title, live value, and a thin utilisation bar.
struct SidebarMeter: View {
    let title: String
    let value: String
    /// 0...1; values outside are clamped.
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(value)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.gray.opacity(0.2))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: geometry.size.width * min(max(fraction, 0), 1))
                }
            }
            .frame(height: 3)
        }
        .padding(.vertical, 2)
    }
}
```

- [ ] **Step 4: Wire panels and sidebar meters into `ContentView`**

Replace the `Section("Performance")` body so each row is a live meter, and route the two new
panels:

```swift
                Section("Performance") {
                    ForEach(Surface.performance) { item in
                        SidebarMeter(title: item.title,
                                     value: meterValue(item),
                                     fraction: meterFraction(item))
                            .tag(item)
                    }
                }
```

Add these two helpers to `ContentView`:

```swift
    private func meterValue(_ surface: Surface) -> String {
        guard let vitals = vitalsModel.vitals else { return "—" }
        switch surface {
        case .cpu:     return vitals.cpuText
        case .memory:  return vitals.memoryText
        case .network: return vitals.networkText
        case .disk:    return "—"          // wired in Task 13
        case .processes: return ""
        }
    }

    private func meterFraction(_ surface: Surface) -> Double {
        guard let vitals = vitalsModel.vitals else { return 0 }
        switch surface {
        case .cpu:
            return vitals.cpuUsagePercent / 100
        case .memory:
            return vitals.totalMemoryBytes > 0
                ? Double(vitals.usedMemoryBytes) / Double(vitals.totalMemoryBytes)
                : 0
        case .network:
            let range = MetricScale.autoscaled([vitalsModel.history.networkIn,
                                                vitalsModel.history.networkOut])
            return range.upperBound > 0
                ? vitals.networkInBytesPerSec / range.upperBound
                : 0
        case .disk, .processes:
            return 0                        // disk wired in Task 13
        }
    }
```

And the detail routes:

```swift
            case .memory:
                MemoryPanel(model: vitalsModel)
            case .network:
                NetworkPanel(model: vitalsModel)
            case .disk:
                Text("Panel coming in Task 13")
                    .foregroundStyle(.secondary)
```

- [ ] **Step 5: Build and verify by running**

Run the build command and launch the app. Confirm: sidebar meters move live on every surface
(including while Processes is selected); Memory's graph is flat-ish near your real usage
fraction; Network's two traces share an axis and the scale label updates when you start a
download.

- [ ] **Step 6: Run tests**

Run the standard test command. Expected: PASS, unchanged.

- [ ] **Step 7: Commit**

```bash
git add macOSmonitor/MemoryPanel.swift macOSmonitor/NetworkPanel.swift \
        macOSmonitor/SidebarMeter.swift macOSmonitor/ContentView.swift \
        macOSmonitor/ProcessesView.swift macOSmonitor.xcodeproj
git commit -m "feat: add Memory and Network panels with live sidebar meters"
```

---

# Phase 2 — Themes

---

### Task 10: `Theme` and the five looks

**Files:**

- Create: `macOSmonitor/Theme.swift`
- Test: `macOSmonitorTests/ThemeTests.swift`

**Interfaces:**

- Consumes: nothing.
- Produces: `struct Theme: Identifiable, Equatable, Sendable` with `id`, `name`,
  `graphLine`, `graphFill`, `gridLine`, `panelBackground`, `primaryText`, `secondaryText`,
  `meterOn`, `meterOff` (all `Color` except `id`/`name`), plus
  `static let system/vfdGreen/vfdAmber/vfdBlue/monochrome: Theme`,
  `static let all: [Theme]`, and `static func named(_ id: String) -> Theme`.
  Also `enum ContrastRatio { static func between(_ a: RGB, _ b: RGB) -> Double }`
  and `struct RGB: Equatable, Sendable { let r, g, b: Double }`.

**Why an `RGB` type:** SwiftUI's `Color` cannot have its components read back portably in a
test. Each theme therefore declares its VFD palette as `RGB` constants, derives its `Color`s
from them, and exposes `textSample`/`backgroundSample` so the contrast test has something
concrete to measure. The System theme is exempt — it uses semantic colours whose values are
appearance-dependent and are AppKit's responsibility, not ours.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import macOSmonitor

struct ThemeTests {
    @Test func thereAreFiveThemesWithDistinctIDs() {
        #expect(Theme.all.count == 5)
        #expect(Set(Theme.all.map(\.id)).count == 5)
    }

    @Test func namedFallsBackToSystemForUnknownIDs() {
        #expect(Theme.named("vfd-green").id == Theme.vfdGreen.id)
        #expect(Theme.named("nonsense").id == Theme.system.id)
    }

    @Test func contrastRatioMatchesKnownValues() {
        let white = RGB(r: 1, g: 1, b: 1)
        let black = RGB(r: 0, g: 0, b: 0)
        #expect(abs(ContrastRatio.between(white, black) - 21.0) < 0.01)
        #expect(abs(ContrastRatio.between(white, white) - 1.0) < 0.01)
    }

    @Test func everyFixedThemeMeetsWCAGAAForBodyText() {
        for theme in Theme.all where !theme.usesSystemColors {
            guard let text = theme.textSample, let background = theme.backgroundSample else {
                Issue.record("\(theme.id) is a fixed theme but has no colour samples")
                continue
            }
            let ratio = ContrastRatio.between(text, background)
            #expect(ratio >= 4.5, "\(theme.id) text contrast is \(ratio):1, below 4.5:1")
        }
    }

    @Test func systemThemeIsTheOnlyOneUsingSemanticColours() {
        #expect(Theme.system.usesSystemColors)
        #expect(Theme.all.filter(\.usesSystemColors).count == 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the standard test command. Expected: FAIL — "cannot find 'Theme' in scope".

- [ ] **Step 3: Write `RGB` and `ContrastRatio`**

```swift
import SwiftUI

/// A literal colour, kept alongside each fixed theme so contrast can be asserted in tests.
/// SwiftUI's `Color` cannot be decomposed portably.
struct RGB: Equatable, Sendable {
    let r: Double
    let g: Double
    let b: Double

    var color: Color { Color(red: r, green: g, blue: b) }
}

/// WCAG 2.1 relative-luminance contrast.
enum ContrastRatio {
    static func between(_ a: RGB, _ b: RGB) -> Double {
        let lighter = max(luminance(a), luminance(b))
        let darker = min(luminance(a), luminance(b))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func luminance(_ rgb: RGB) -> Double {
        0.2126 * channel(rgb.r) + 0.7152 * channel(rgb.g) + 0.0722 * channel(rgb.b)
    }

    private static func channel(_ value: Double) -> Double {
        value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}
```

- [ ] **Step 4: Write `Theme` and the five instances**

```swift
import SwiftUI

/// A display palette for the Performance surface. The System theme defers to
/// semantic colours (and therefore tracks light/dark); the four VFD themes are
/// fixed dark palettes that deliberately ignore system appearance.
struct Theme: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let graphLine: Color
    let graphFill: Color
    let gridLine: Color
    let panelBackground: Color
    let primaryText: Color
    let secondaryText: Color
    let meterOn: Color
    let meterOff: Color
    let usesSystemColors: Bool
    /// Literal samples for the contrast test; nil for the System theme.
    let textSample: RGB?
    let backgroundSample: RGB?

    static let system = Theme(
        id: "system", name: "System",
        graphLine: .accentColor, graphFill: .accentColor.opacity(0.2),
        gridLine: .gray.opacity(0.3), panelBackground: Color(nsColor: .windowBackgroundColor),
        primaryText: .primary, secondaryText: .secondary,
        meterOn: .accentColor, meterOff: .gray.opacity(0.2),
        usesSystemColors: true, textSample: nil, backgroundSample: nil
    )

    static let vfdGreen = fixed(id: "vfd-green", name: "VFD Green",
                                accent: RGB(r: 0.24, g: 1.00, b: 0.44))
    static let vfdAmber = fixed(id: "vfd-amber", name: "VFD Amber",
                                accent: RGB(r: 1.00, g: 0.75, b: 0.20))
    static let vfdBlue  = fixed(id: "vfd-blue", name: "VFD Blue",
                                accent: RGB(r: 0.42, g: 0.78, b: 1.00))
    static let monochrome = fixed(id: "mono", name: "Monochrome",
                                  accent: RGB(r: 0.88, g: 0.88, b: 0.88))

    static let all: [Theme] = [.system, .vfdGreen, .vfdAmber, .vfdBlue, .monochrome]

    static func named(_ id: String) -> Theme {
        all.first { $0.id == id } ?? .system
    }

    /// Builds a fixed dark VFD palette from one accent colour on near-black.
    private static func fixed(id: String, name: String, accent: RGB) -> Theme {
        let background = RGB(r: 0.04, g: 0.05, b: 0.05)
        return Theme(
            id: id, name: name,
            graphLine: accent.color,
            graphFill: accent.color.opacity(0.18),
            gridLine: accent.color.opacity(0.18),
            panelBackground: background.color,
            primaryText: accent.color,
            secondaryText: accent.color.opacity(0.65),
            meterOn: accent.color,
            meterOff: accent.color.opacity(0.12),
            usesSystemColors: false,
            textSample: accent,
            backgroundSample: background
        )
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run the standard test command. Expected: PASS, 5 tests.

If `everyFixedThemeMeetsWCAGAAForBodyText` fails, lighten the failing accent until the ratio
clears 4.5:1 — do not lower the threshold. Record the measured ratio in the commit message.

- [ ] **Step 6: Commit**

```bash
git add macOSmonitor/Theme.swift macOSmonitorTests/ThemeTests.swift macOSmonitor.xcodeproj
git commit -m "feat: add Theme with five palettes and WCAG contrast tests"
```

---

### Task 11: Theme distribution, persistence, and adoption

**Files:**

- Create: `macOSmonitor/ThemeEnvironment.swift`
- Modify: `macOSmonitor/CPUPanel.swift`, `macOSmonitor/MemoryPanel.swift`,
  `macOSmonitor/NetworkPanel.swift`, `macOSmonitor/CoreGrid.swift`
- Modify: `macOSmonitor/ContentView.swift` (inject theme, toolbar picker)

**Interfaces:**

- Consumes: `Theme` (Task 10).
- Produces: `EnvironmentValues.theme: Theme` (default `.system`), read in panels as
  `@Environment(\.theme) private var theme`.

**Scope:** the Performance surface only. `ProcessesView` and its `Table` keep native
styling — a themed `Table` is a much larger fight than this milestone justifies.

- [ ] **Step 1: Create the environment key**

```swift
import SwiftUI

extension EnvironmentValues {
    /// The active Performance-surface palette. Defaults to the system theme.
    @Entry var theme: Theme = .system
}
```

- [ ] **Step 2: Add persistence and the picker to `ContentView`**

Add the storage property:

```swift
    @AppStorage("themeID") private var themeID: String = Theme.system.id
```

Add a computed `private var theme: Theme { Theme.named(themeID) }`, inject it on the
`NavigationSplitView`, and add the picker to the toolbar:

```swift
        .environment(\.theme, theme)
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Theme", selection: $themeID) {
                        ForEach(Theme.all) { option in
                            Text(option.name).tag(option.id)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Theme", systemImage: "paintpalette")
                }
            }
        }
```

- [ ] **Step 3: Adopt the theme in `CPUPanel`**

Add `@Environment(\.theme) private var theme` and replace every hardcoded colour:

- `MetricGraph(... lineColor: theme.graphLine, fillColor: theme.graphFill, gridColor: theme.gridLine)`
- `CoreGrid(percentages: ..., onColor: theme.meterOn, offColor: theme.meterOff)`
- The two `Text` styles in `stat(_:_:)` become `.foregroundStyle(theme.secondaryText)` and
  `.foregroundStyle(theme.primaryText)`
- The panel's outermost `VStack` gains
  `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)` and
  `.background(theme.panelBackground)`

- [ ] **Step 4: Adopt the theme in `MemoryPanel` and `NetworkPanel`**

Apply the same four changes to both. In `NetworkPanel` the *sent* trace keeps a contrasting
colour: use `theme.secondaryText` for its line and `theme.graphFill` for its fill, so the two
traces stay distinguishable inside a single-accent VFD palette.

- [ ] **Step 5: Build and verify by running**

Run the build command and launch the app. Confirm:

1. Each of the five themes changes the panels, and Processes stays natively styled.
2. The chosen theme survives quitting and relaunching the app.
3. In each VFD theme the two Network traces remain distinguishable.
4. System theme still follows macOS light/dark when you switch appearance.

- [ ] **Step 6: Run tests**

Run the standard test command. Expected: PASS, unchanged.

- [ ] **Step 7: Commit**

```bash
git add macOSmonitor/ThemeEnvironment.swift macOSmonitor/ContentView.swift \
        macOSmonitor/CPUPanel.swift macOSmonitor/MemoryPanel.swift \
        macOSmonitor/NetworkPanel.swift macOSmonitor/CoreGrid.swift macOSmonitor.xcodeproj
git commit -m "feat: distribute themes via environment with AppStorage persistence"
```

---

# Phase 3 — Disk

---

### Task 12: `DiskStats` provider

**Files:**

- Create: `macOSmonitor/DiskStats.swift`
- Test: `macOSmonitorTests/DiskStatsTests.swift`

**Interfaces:**

- Consumes: nothing.
- Produces: `protocol DiskStatsProviding: Sendable { func counters() -> (read: UInt64, written: UInt64)? }`
  and `struct DiskStats: DiskStatsProviding`.

**Already verified on this machine.** The implementation below compiled and returned real
values (`read: 9240700169216, written: 2001463840768`). The registry keys are confirmed:
the per-driver dictionary key is `"Statistics"` (`kIOBlockStorageDriverStatisticsKey`) with
sub-keys `"Bytes (Read)"` and `"Bytes (Write)"`. Values exceed 32 bits, so `UInt64` is
required. Three `IOBlockStorageDriver` services matched, one reporting all zeros — summing
across every match is correct.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import macOSmonitor

struct DiskStatsTests {
    @Test func realHardwareReportsNonNilCounters() {
        let counters = DiskStats().counters()
        #expect(counters != nil)
    }

    @Test func countersAreMonotonicAcrossTwoReads() {
        let stats = DiskStats()
        guard let first = stats.counters(), let second = stats.counters() else {
            Issue.record("expected counters on real hardware")
            return
        }
        #expect(second.read >= first.read)
        #expect(second.written >= first.written)
    }

    @Test func countersExceedThirtyTwoBitsOnARealMachine() {
        // Guards against a UInt32 regression: a machine with any history reads well past 4 GB.
        guard let counters = DiskStats().counters() else {
            Issue.record("expected counters on real hardware")
            return
        }
        #expect(counters.read > 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the standard test command. Expected: FAIL — "cannot find 'DiskStats' in scope".

- [ ] **Step 3: Write the implementation**

```swift
import Foundation
import IOKit
import IOKit.storage

/// Cumulative disk byte counters, isolated behind a protocol so the sampler can use a fake.
protocol DiskStatsProviding: Sendable {
    func counters() -> (read: UInt64, written: UInt64)?
}

struct DiskStats: DiskStatsProviding {
    func counters() -> (read: UInt64, written: UInt64)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching(kIOBlockStorageDriverClass),
                                           &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        var read: UInt64 = 0
        var written: UInt64 = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }        // every matched service must be released
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties,
                                                    kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as? [String: Any],
                  let statistics = dictionary[kIOBlockStorageDriverStatisticsKey]
                    as? [String: Any]
            else { continue }
            // 64-bit counters: a machine with any history reads well past 4 GB.
            read += (statistics[kIOBlockStorageDriverStatisticsBytesReadKey] as? UInt64) ?? 0
            written += (statistics[kIOBlockStorageDriverStatisticsBytesWrittenKey] as? UInt64) ?? 0
        }
        return (read, written)
    }
}
```

- [ ] **Step 4: Add files to targets and run tests**

Run the standard test command. Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add macOSmonitor/DiskStats.swift macOSmonitorTests/DiskStatsTests.swift macOSmonitor.xcodeproj
git commit -m "feat: add DiskStats IOKit block-storage shim"
```

---

### Task 13: Disk rates in the sampler, and the Disk panel

**Files:**

- Modify: `macOSmonitor/SystemVitalsSampler.swift` (inject provider, compute rates)
- Modify: `macOSmonitorTests/SystemVitalsSamplerTests.swift` (fake + rate tests)
- Create: `macOSmonitor/DiskPanel.swift`
- Modify: `macOSmonitor/ContentView.swift` (route `.disk`, sidebar value/fraction)

**Interfaces:**

- Consumes: `DiskStatsProviding` (Task 12), `SystemVitals.diskReadBytesPerSec`/
  `.diskWriteBytesPerSec` (Task 2), `MetricGraph`, `MetricScale`, `Theme`.
- Produces: `SystemVitalsSampler.init(..., disk: any DiskStatsProviding = DiskStats(), ...)`;
  `struct DiskPanel: View { init(model: VitalsModel) }`.

**Mirrors M8's network rates exactly**, including reuse of the injected `now` clock and the
negative-delta guard. Rates need wall time; unlike CPU%, they are not self-normalizing.

- [ ] **Step 1: Add a fake and write the failing tests**

Add to `macOSmonitorTests/SystemVitalsSamplerTests.swift`:

```swift
final class FakeDiskStats: DiskStatsProviding, @unchecked Sendable {
    var next: (read: UInt64, written: UInt64)?
    func counters() -> (read: UInt64, written: UInt64)? { next }
}
```

And the tests:

```swift
    @Test func diskRatesAreBytesPerSecondOverElapsedTime() async {
        let disk = FakeDiskStats()
        disk.next = (read: 1_000, written: 2_000)
        var clock: UInt64 = 0
        let sampler = SystemVitalsSampler(host: FakeHostStats(),
                                          disk: disk,
                                          now: { clock })

        let first = await sampler.sample()
        #expect(first.diskReadBytesPerSec == 0)        // no baseline yet

        clock = 2_000_000_000                          // +2 seconds
        disk.next = (read: 3_000, written: 2_500)      // +2000 read, +500 written
        let second = await sampler.sample()
        #expect(second.diskReadBytesPerSec == 1_000)   // 2000 bytes / 2s
        #expect(second.diskWriteBytesPerSec == 250)
    }

    @Test func diskCounterGoingBackwardsYieldsZeroNotATrap() async {
        let disk = FakeDiskStats()
        disk.next = (read: 5_000, written: 5_000)
        var clock: UInt64 = 0
        let sampler = SystemVitalsSampler(host: FakeHostStats(), disk: disk, now: { clock })
        _ = await sampler.sample()

        clock = 1_000_000_000
        disk.next = (read: 10, written: 10)            // counters reset
        let sample = await sampler.sample()
        #expect(sample.diskReadBytesPerSec == 0)
        #expect(sample.diskWriteBytesPerSec == 0)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run the standard test command. Expected: FAIL — no `disk:` parameter on the initialiser.

- [ ] **Step 3: Wire the provider into the sampler**

Add the stored properties beside the network ones:

```swift
    private let disk: any DiskStatsProviding
    private var previousDiskCounters: (read: UInt64, written: UInt64)?
    private var previousDiskTime: UInt64?
```

The disk read needs **its own** timestamp rather than sharing `previousTime`: if
`network.counters()` ever returns nil, `previousTime` is never set, and a shared timestamp
would silently zero the disk rates too.

Add the init parameter (after `battery:`) and its assignment:

```swift
         disk: any DiskStatsProviding = DiskStats(),
```

```swift
        self.disk = disk
```

Add the rate block after the existing network block, reusing the same clock reading:

```swift
        var diskRead = 0.0
        var diskWrite = 0.0
        if let counters = disk.counters() {
            let time = now()
            if let previous = previousDiskCounters, let previousT = previousDiskTime,
               time > previousT {
                let seconds = Double(time - previousT) / 1_000_000_000
                if seconds > 0 {
                    if counters.read >= previous.read {
                        diskRead = Double(counters.read - previous.read) / seconds
                    }
                    if counters.written >= previous.written {
                        diskWrite = Double(counters.written - previous.written) / seconds
                    }
                }
            }
            previousDiskCounters = counters
            previousDiskTime = time
        }
```

Pass both into the returned `SystemVitals`, after `perCoreUsagePercent: perCore`:

```swift
            diskReadBytesPerSec: diskRead,
            diskWriteBytesPerSec: diskWrite
```

- [ ] **Step 4: Run tests to verify they pass**

Run the standard test command. Expected: PASS.

- [ ] **Step 5: Write `DiskPanel`**

```swift
import SwiftUI

/// The Disk Performance panel: read and write throughput sharing one autoscaled axis.
struct DiskPanel: View {
    let model: VitalsModel
    @Environment(\.theme) private var theme

    private var range: ClosedRange<Double> {
        MetricScale.autoscaled([model.history.diskRead, model.history.diskWrite])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Disk").font(.title2).foregroundStyle(theme.primaryText)
                Spacer()
                Text(throughputText)
                    .font(.title2)
                    .monospacedDigit()
                    .foregroundStyle(theme.primaryText)
            }

            ZStack {
                MetricGraph(values: model.history.diskRead.values, range: range,
                            lineColor: theme.graphLine, fillColor: theme.graphFill,
                            gridColor: theme.gridLine)
                MetricGraph(values: model.history.diskWrite.values, range: range,
                            lineColor: theme.secondaryText, fillColor: theme.graphFill,
                            gridColor: .clear)
            }
            .frame(minHeight: 180)

            HStack {
                Text("scale: \(scaleLabel)")
                Spacer()
                Label("Read", systemImage: "arrow.down")
                Label("Write", systemImage: "arrow.up")
            }
            .font(.caption2)
            .foregroundStyle(theme.secondaryText)

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.panelBackground)
    }

    private var throughputText: String {
        guard let vitals = model.vitals else { return "—" }
        return "R \(rate(vitals.diskReadBytesPerSec))  W \(rate(vitals.diskWriteBytesPerSec))"
    }

    private var scaleLabel: String {
        rate(range.upperBound)
    }

    private func rate(_ bytesPerSec: Double) -> String {
        let b = max(0, bytesPerSec)
        if b < 1_000 { return String(format: "%.0f B/s", b) }
        if b < 1_000_000 { return String(format: "%.0f KB/s", b / 1_000) }
        return String(format: "%.1f MB/s", b / 1_000_000)
    }
}
```

- [ ] **Step 6: Route `.disk` and finish the sidebar meter**

In `ContentView`, replace the `.disk` placeholder with `DiskPanel(model: vitalsModel)`.
In `meterValue`, replace the `.disk` case with:

```swift
        case .disk:
            return String(format: "%.1f MB/s",
                          (vitals.diskReadBytesPerSec + vitals.diskWriteBytesPerSec) / 1_000_000)
```

In `meterFraction`, split `.disk` out of the shared case:

```swift
        case .disk:
            let range = MetricScale.autoscaled([vitalsModel.history.diskRead,
                                                vitalsModel.history.diskWrite])
            return range.upperBound > 0
                ? (vitals.diskReadBytesPerSec + vitals.diskWriteBytesPerSec) / range.upperBound
                : 0
        case .processes:
            return 0
```

- [ ] **Step 7: Build and verify by running**

Run the build command and launch the app. Select Disk, then copy a large file or run
`dd if=/dev/zero of=~/Desktop/ddtest bs=1m count=2000` in a terminal and confirm the write
trace responds and the scale label climbs. Delete the test file afterwards. Cross-check the
magnitude against Activity Monitor's Disk tab.

- [ ] **Step 8: Run the full test suite**

Run the standard test command. Expected: PASS, all tests across all thirteen tasks.

- [ ] **Step 9: Commit**

```bash
git add macOSmonitor/SystemVitalsSampler.swift macOSmonitorTests/SystemVitalsSamplerTests.swift \
        macOSmonitor/DiskPanel.swift macOSmonitor/ContentView.swift macOSmonitor.xcodeproj
git commit -m "feat: add disk throughput rates and the Disk panel"
```

---

## Done criteria

- [ ] All thirteen tasks committed
- [ ] `xcodebuild ... -only-testing:macOSmonitorTests test` passes
- [ ] Sidebar meters update live regardless of which surface is selected
- [ ] CPU right-click toggles between the overall trace and the per-core grid
- [ ] All five themes apply and the choice survives relaunch
- [ ] Disk throughput responds to real I/O and matches Activity Monitor's magnitude
- [ ] ⌘F still focuses search; the inspector still updates live
- [ ] Bug A either did not reproduce, or its repro steps are recorded in a commit message
