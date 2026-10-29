# Summary Dashboard Implementation Plan (Milestone 11)

**Status:** FOLDED into TODO.md

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Summary dashboard as the app's default landing surface, composed entirely from data already sampled.

**Architecture:** A new `SummaryView` surface assembles compact cards from M10's existing pieces (`MetricGraph`, `MetricScale`, `VitalsModel`) plus two new shared components, `MeterBar` and `StatCard`. The four Performance panels are not touched. `ProcessListModel`'s sampling loop moves from `ProcessesView` up to `ContentView` so process data is available on every surface.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-08-28-summary-dashboard-design.md`

## Global Constraints

- **No new data sources.** No new providers, no new syscalls, no new IOKit or SMC reads. Every value comes from `VitalsModel` or `ProcessListModel` as they exist today.
- **Never edit `macOSmonitor.xcodeproj/project.pbxproj`, and never `git add` it.** The project uses `PBXFileSystemSynchronizedRootGroup` (objectVersion 77): files under `macOSmonitor/` and `macOSmonitorTests/` join their targets by directory automatically. There is no "add the file to the Xcode target" step.
- **Swift Testing only** — `import Testing`, `@Test`, `#expect`, `Issue.record`. Never XCTest.
- **Views read `@Observable` models directly inside `body`** — never snapshot into a local `let` first. This codebase has produced a "frozen panel" regression from exactly that, twice.
- **No `TimelineView`.**
- All scaling goes through `MetricScale`; no raw division inside a card.
- The Battery card is omitted entirely when `SystemVitals.battery` is nil (M9's rule).
- Do not `git add` the untracked `icons8-system-task-96.png` if present; it is the user's.

**Test command** (slow, ~1 min — run for RED and GREEN, not after every edit):

```bash
xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test
```

Count results by grepping the log for `"' passed "` / `"' failed "` and `** TEST SUCCEEDED **`. **Tee one run to a log and grep the log twice** rather than running twice.

**Baseline: 100 tests passing before Task 1.**

**Known environment noise:** SourceKit in this project routinely emits phantom "cannot find type X in scope" / "no such module 'Testing'" errors right after a file changes. `xcodebuild` is the source of truth. Also: `xcodebuild` only emits warnings for files it actually recompiled, so never claim "zero warnings" from an incremental run.

---

### Task 1: `Metric` and per-metric theme colours

**Files:**

- Create: `macOSmonitor/Metric.swift`
- Modify: `macOSmonitor/Theme.swift`
- Test: `macOSmonitorTests/MetricColorTests.swift`

**Interfaces:**

- Consumes: `RGB`, `ContrastRatio`, `Theme` (all existing in `Theme.swift`).
- Produces: `enum Metric: String, CaseIterable, Hashable { case cpu, memory, network, disk, battery, thermal }` and `func Theme.color(for: Metric) -> Color`, plus `static let Theme.systemMetricSamples: [Metric: RGB]`.

**Why the threshold is 3:1, not 4.5:1.** These hues colour graph strokes and meter fills, not body text. WCAG 2.1 SC 1.4.11 (Non-text Contrast) sets 3:1 for graphical objects; 4.5:1 (SC 1.4.3) governs text and is already covered by M10's `ThemeTests`.

- [ ] **Step 1: Create `Metric.swift`**

```swift
import Foundation

/// A measurable quantity the UI can colour-code.
///
/// Deliberately separate from `Surface`, which also carries non-metric cases
/// (`.processes`, `.summary`) that would need meaningless colour entries.
enum Metric: String, CaseIterable, Hashable, Sendable {
    case cpu, memory, network, disk, battery, thermal
}
```

- [ ] **Step 2: Write the failing tests**

Create `macOSmonitorTests/MetricColorTests.swift`:

```swift
import Testing
import AppKit
@testable import macOSmonitor

@MainActor
struct MetricColorTests {

    /// Resolves the real system window background at a given appearance, so the
    /// contrast assertion measures what actually ships rather than a guessed constant.
    private func windowBackground(_ name: NSAppearance.Name) -> RGB? {
        guard let appearance = NSAppearance(named: name) else { return nil }
        var result: RGB?
        appearance.performAsCurrentDrawingAppearance {
            if let c = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) {
                result = RGB(r: Double(c.redComponent),
                             g: Double(c.greenComponent),
                             b: Double(c.blueComponent))
            }
        }
        return result
    }

    @Test func everyFixedThemeUsesItsAccentForEveryMetric() {
        for theme in Theme.all where !theme.usesSystemColors {
            for metric in Metric.allCases {
                #expect(theme.color(for: metric) == theme.graphLine,
                        "\(theme.name) should be monochrome for \(metric)")
            }
        }
    }

    @Test func systemThemeGivesEveryMetricItsOwnHue() {
        #expect(Theme.systemMetricSamples.count == Metric.allCases.count)
        for metric in Metric.allCases {
            #expect(Theme.systemMetricSamples[metric] != nil, "missing hue for \(metric)")
        }
        // No two metrics may share a hue, or the dashboard's colour coding is a lie.
        let samples = Metric.allCases.compactMap { Theme.systemMetricSamples[$0] }
        for i in samples.indices {
            for j in samples.indices where j > i {
                #expect(samples[i] != samples[j], "hues \(i) and \(j) collide")
            }
        }
    }

    @Test func systemHuesAreLegibleInBothAppearances() {
        guard let light = windowBackground(.aqua),
              let dark = windowBackground(.darkAqua) else {
            Issue.record("could not resolve NSColor.windowBackgroundColor in both appearances")
            return
        }
        for metric in Metric.allCases {
            guard let hue = Theme.systemMetricSamples[metric] else {
                Issue.record("missing hue for \(metric)")
                continue
            }
            // WCAG 2.1 SC 1.4.11 Non-text Contrast: 3:1 for graphical objects.
            #expect(ContrastRatio.between(hue, light) >= 3.0,
                    "\(metric) fails against light background")
            #expect(ContrastRatio.between(hue, dark) >= 3.0,
                    "\(metric) fails against dark background")
        }
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run the standard test command. Expected: FAIL — "cannot find 'Metric' in scope" and "value of type 'Theme' has no member 'color'".

- [ ] **Step 4: Add the lookup to `Theme.swift`**

Add inside `struct Theme`, after the `static let system` declaration:

```swift
    /// Per-metric hues for the System palette, as literal samples so contrast is testable.
    /// Starting point is TMOG's own coding; any hue failing the 3:1 test is replaced.
    static let systemMetricSamples: [Metric: RGB] = [
        .cpu:     RGB(r: 0.13, g: 0.55, b: 0.24),
        .memory:  RGB(r: 0.48, g: 0.24, b: 0.72),
        .network: RGB(r: 0.10, g: 0.40, b: 0.78),
        .disk:    RGB(r: 0.70, g: 0.38, b: 0.05),
        .battery: RGB(r: 0.08, g: 0.48, b: 0.44),
        .thermal: RGB(r: 0.72, g: 0.18, b: 0.22),
    ]

    /// The colour this palette uses for a metric.
    ///
    /// The four fixed palettes answer with their single accent: a real vacuum
    /// fluorescent display has one phosphor, so monochrome is authentic here rather
    /// than a fallback.
    func color(for metric: Metric) -> Color {
        guard usesSystemColors else { return graphLine }
        return (Theme.systemMetricSamples[metric] ?? RGB(r: 0.5, g: 0.5, b: 0.5)).color
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run the standard test command. Expected: PASS, 103 tests.

**If a hue fails the 3:1 assertion**, darken or lighten that entry until it passes against BOTH backgrounds and still does not collide with another. Do not lower the threshold. Record the final values in your report.

- [ ] **Step 6: Commit**

```bash
git add macOSmonitor/Metric.swift macOSmonitor/Theme.swift macOSmonitorTests/MetricColorTests.swift
git commit -m "feat: add Metric and per-metric theme colours"
```

---

### Task 2: `MeterBar`

**Files:**

- Create: `macOSmonitor/MeterBar.swift`
- Test: `macOSmonitorTests/MeterBarTests.swift`

**Interfaces:**

- Consumes: nothing.
- Produces: `struct MeterBar: View` with `init(fraction: Double, orientation: MeterBar.Orientation, onColor: Color, offColor: Color)`, `enum MeterBar.Orientation { case horizontal, vertical }`, and `static func MeterBar.clampedFraction(_ value: Double) -> Double`.

**This component's interface is the seam for M12**, which re-renders it as stacked LED segments without touching any call site. Keep the interface exactly as specified.

- [ ] **Step 1: Write the failing tests**

Create `macOSmonitorTests/MeterBarTests.swift`:

```swift
import Testing
@testable import macOSmonitor

struct MeterBarTests {
    @Test func passesThroughValuesInRange() {
        #expect(MeterBar.clampedFraction(0) == 0)
        #expect(MeterBar.clampedFraction(0.5) == 0.5)
        #expect(MeterBar.clampedFraction(1) == 1)
    }

    @Test func clampsOutOfRangeValues() {
        #expect(MeterBar.clampedFraction(-0.5) == 0)
        #expect(MeterBar.clampedFraction(1.5) == 1)
    }

    /// A non-finite fraction would otherwise produce a NaN frame height, which
    /// SwiftUI renders as a blank view with no error.
    @Test func mapsNonFiniteValuesToZero() {
        #expect(MeterBar.clampedFraction(.nan) == 0)
        #expect(MeterBar.clampedFraction(.infinity) == 0)
        #expect(MeterBar.clampedFraction(-.infinity) == 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the standard test command. Expected: FAIL — "cannot find 'MeterBar' in scope".

- [ ] **Step 3: Write the implementation**

Create `macOSmonitor/MeterBar.swift`:

```swift
import SwiftUI

/// A utilisation meter: a track with a proportional fill, in either orientation.
///
/// M12 re-renders this as stacked LED segments. The interface is fixed now so that
/// milestone changes only this file.
struct MeterBar: View {
    enum Orientation { case horizontal, vertical }

    let fraction: Double
    let orientation: Orientation
    let onColor: Color
    let offColor: Color

    /// Clamps to 0...1, mapping non-finite input to 0 so a bad fraction can never
    /// produce a negative, infinite, or NaN frame.
    static func clampedFraction(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: orientation == .horizontal ? .leading : .bottom) {
                Capsule().fill(offColor)
                Capsule()
                    .fill(onColor)
                    .frame(
                        width: orientation == .horizontal
                            ? geometry.size.width * MeterBar.clampedFraction(fraction)
                            : nil,
                        height: orientation == .vertical
                            ? geometry.size.height * MeterBar.clampedFraction(fraction)
                            : nil
                    )
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the standard test command. Expected: PASS, 106 tests.

- [ ] **Step 5: Commit**

```bash
git add macOSmonitor/MeterBar.swift macOSmonitorTests/MeterBarTests.swift
git commit -m "feat: add MeterBar, a themed utilisation meter"
```

---

### Task 3: `SidebarMeter` adopts `MeterBar` and the theme

**Files:**

- Modify: `macOSmonitor/SidebarMeter.swift`
- Modify: `macOSmonitor/Surface.swift`
- Modify: `macOSmonitor/ContentView.swift`

**Interfaces:**

- Consumes: `MeterBar` (Task 2), `Metric` and `Theme.color(for:)` (Task 1).
- Produces: `SidebarMeter(title:value:fraction:metric:)` and `var Surface.metric: Metric?`.

This closes a known gap: `SidebarMeter` currently hardcodes `.secondary`, `.gray.opacity(0.2)` and `Color.accentColor`, so sidebar meters stay system-coloured beside a themed panel. No new tests — this is a view change, verified by hand in Step 5.

- [ ] **Step 1: Add the metric mapping to `Surface.swift`**

Add inside `enum Surface`, after `title`:

```swift
    /// The metric this surface displays, if any. `.processes` shows a table, not a metric.
    var metric: Metric? {
        switch self {
        case .cpu:       return .cpu
        case .memory:    return .memory
        case .network:   return .network
        case .disk:      return .disk
        case .processes: return nil
        }
    }
```

- [ ] **Step 2: Rewrite `SidebarMeter.swift`**

Replace the whole file with:

```swift
import SwiftUI

/// A sidebar row: title, live value, and a thin utilisation meter in the metric's colour.
struct SidebarMeter: View {
    let title: String
    let value: String
    /// 0...1; values outside are clamped by `MeterBar`.
    let fraction: Double
    let metric: Metric

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(value)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(theme.secondaryText)
            }
            MeterBar(fraction: fraction,
                     orientation: .horizontal,
                     onColor: theme.color(for: metric),
                     offColor: theme.meterOff)
                .frame(height: 3)
        }
        .padding(.vertical, 2)
    }
}
```

Note the title `Text` keeps its default colour deliberately: it is a sidebar list row and must stay legible against the system sidebar background under every theme, including the fixed dark palettes.

- [ ] **Step 3: Update the call site in `ContentView.swift`**

Replace the `ForEach` inside the `Section("Performance")` with:

```swift
                    ForEach(Surface.performance) { item in
                        if let metric = item.metric {
                            SidebarMeter(title: item.title,
                                         value: meterValue(item),
                                         fraction: meterFraction(item),
                                         metric: metric)
                                .tag(item)
                        }
                    }
```

- [ ] **Step 4: Build and run the tests**

Run the standard test command. Expected: PASS, 106 tests (unchanged — this is a view change).

- [ ] **Step 5: Verify by hand**

Launch the app. Switch to VFD Green, then VFD Amber. Confirm the four sidebar meter bars now render in the theme's accent rather than the system blue accent. Switch to System and confirm each meter shows its own hue (CPU green, Memory purple, Network blue, Disk orange). Report what you actually observed.

- [ ] **Step 6: Commit**

```bash
git add macOSmonitor/SidebarMeter.swift macOSmonitor/Surface.swift macOSmonitor/ContentView.swift
git commit -m "feat: sidebar meters follow the theme and their metric colour"
```

---

### Task 4: `topByCPU`

**Files:**

- Modify: `macOSmonitor/ProcessInfoRow.swift`
- Modify: `macOSmonitor/ProcessListModel.swift`
- Test: `macOSmonitorTests/TopByCPUTests.swift`

**Interfaces:**

- Consumes: `ProcessInfoRow` (existing; memberwise init is `ProcessInfoRow(pid:name:cpuPercent:memoryBytes:cpuTimeNanos:)`, the last defaulted to nil).
- Produces: `static func ProcessInfoRow.topByCPU(_ rows: [ProcessInfoRow], limit: Int) -> [ProcessInfoRow]` and the thin wrapper `func ProcessListModel.topByCPU(limit: Int) -> [ProcessInfoRow]`.

**Why the logic is a static function on `ProcessInfoRow` rather than only a model method:** `ProcessListModel.rows` is `private(set)`, so testing a model method would require constructing the model with a fake sampler and awaiting a refresh. A pure function over an array needs none of that, and the model keeps the convenient call site.

**Ties break by ascending PID deliberately.** Swift's `sorted` is not guaranteed stable, and many processes sit at exactly 0% CPU. Without a tiebreak, rows at equal CPU could reorder on every 1 Hz tick, making the card flicker.

- [ ] **Step 1: Write the failing tests**

Create `macOSmonitorTests/TopByCPUTests.swift`:

```swift
import Testing
@testable import macOSmonitor

struct TopByCPUTests {
    private func row(_ pid: pid_t, _ cpu: Double?) -> ProcessInfoRow {
        ProcessInfoRow(pid: pid, name: "p\(pid)", cpuPercent: cpu, memoryBytes: 1)
    }

    @Test func ordersByCPUDescending() {
        let rows = [row(1, 5), row(2, 90), row(3, 40)]
        let top = ProcessInfoRow.topByCPU(rows, limit: 3)
        #expect(top.map(\.pid) == [2, 3, 1])
    }

    @Test func honoursTheLimit() {
        let rows = [row(1, 5), row(2, 90), row(3, 40)]
        #expect(ProcessInfoRow.topByCPU(rows, limit: 2).map(\.pid) == [2, 3])
    }

    @Test func limitLargerThanInputReturnsEverything() {
        let rows = [row(1, 5), row(2, 90)]
        #expect(ProcessInfoRow.topByCPU(rows, limit: 99).count == 2)
    }

    @Test func emptyInputReturnsEmpty() {
        #expect(ProcessInfoRow.topByCPU([], limit: 8).isEmpty)
    }

    @Test func nonPositiveLimitReturnsEmpty() {
        #expect(ProcessInfoRow.topByCPU([row(1, 5)], limit: 0).isEmpty)
        #expect(ProcessInfoRow.topByCPU([row(1, 5)], limit: -3).isEmpty)
    }

    /// Deterministic tie order stops the card reshuffling every tick when many
    /// processes sit at exactly 0%.
    @Test func tiesBreakByAscendingPID() {
        let rows = [row(9, 0), row(3, 0), row(7, 0)]
        #expect(ProcessInfoRow.topByCPU(rows, limit: 3).map(\.pid) == [3, 7, 9])
    }

    /// A denied process reports nil CPU and must sink below any readable process.
    @Test func unreadableCPUSinksToTheBottom() {
        let rows = [row(1, nil), row(2, 0)]
        #expect(ProcessInfoRow.topByCPU(rows, limit: 2).map(\.pid) == [2, 1])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the standard test command. Expected: FAIL — "type 'ProcessInfoRow' has no member 'topByCPU'".

- [ ] **Step 3: Add the pure function to `ProcessInfoRow.swift`**

Add inside `struct ProcessInfoRow`, after `canTerminate`:

```swift
    /// The `limit` highest-CPU rows, descending, ties broken by ascending PID.
    ///
    /// The tiebreak matters: Swift's `sorted` is not guaranteed stable and many
    /// processes sit at exactly 0%, so without it the list would reshuffle every tick.
    /// `cpuSortKey` is -1 for unreadable processes, sinking them below 0% ones.
    static func topByCPU(_ rows: [ProcessInfoRow], limit: Int) -> [ProcessInfoRow] {
        guard limit > 0 else { return [] }
        let sorted = rows.sorted {
            $0.cpuSortKey == $1.cpuSortKey ? $0.pid < $1.pid : $0.cpuSortKey > $1.cpuSortKey
        }
        return Array(sorted.prefix(limit))
    }
```

- [ ] **Step 4: Add the wrapper to `ProcessListModel.swift`**

Add as a method on `ProcessListModel`, after `refreshOnce()`:

```swift
    /// The `limit` highest-CPU rows, for the Summary dashboard's process card.
    func topByCPU(limit: Int) -> [ProcessInfoRow] {
        ProcessInfoRow.topByCPU(rows, limit: limit)
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run the standard test command. Expected: PASS, 113 tests.

- [ ] **Step 6: Commit**

```bash
git add macOSmonitor/ProcessInfoRow.swift macOSmonitor/ProcessListModel.swift macOSmonitorTests/TopByCPUTests.swift
git commit -m "feat: add topByCPU with a deterministic tiebreak"
```

---

### Task 5: Move process sampling app-wide, and test loop cancellation

**Files:**

- Modify: `macOSmonitor/ContentView.swift`
- Modify: `macOSmonitor/ProcessesView.swift`
- Test: `macOSmonitorTests/VitalsModelTests.swift`
- Test: `macOSmonitorTests/ProcessListModelTests.swift`

**Interfaces:**

- Consumes: `VitalsModel.run()`, `ProcessListModel.run()` (both existing), `FakeVitalsSampler` (in `VitalsModelTests.swift`), `FakeSampler` (in `ProcessListModelTests.swift`, exposes `private(set) var callCount`).
- Produces: no new API.

`ProcessListModel.run()` currently starts from `ProcessesView`'s `.task` and is cancelled on navigation away. Summary needs process data, so the loop moves to `ContentView` beside the vitals loop. This is the milestone's one real risk — see Step 6.

The cancellation tests close a gap M10's whole-branch review named: `run()` is the only lifecycle code these models have, it is duplicated across both, and `try? await Task.sleep` swallowing cancellation is exactly the kind of thing that reads correctly and behaves wrongly.

- [ ] **Step 1: Write the failing cancellation tests**

Add to `macOSmonitorTests/VitalsModelTests.swift`, inside `struct VitalsModelTests`:

```swift
    /// `run()` swallows the sleep's cancellation error, so the loop must exit on the
    /// `Task.isCancelled` check instead. Without that it would spin forever.
    @Test func runStopsSamplingAfterCancellation() async {
        let sampler = FakeVitalsSampler()
        let model = VitalsModel(sampler: sampler, interval: .milliseconds(10))

        let task = Task { await model.run() }
        try? await Task.sleep(for: .milliseconds(60))
        task.cancel()
        _ = await task.value

        let countAtCancel = sampler.callCount
        #expect(countAtCancel > 0, "loop should have sampled at least once before cancelling")

        try? await Task.sleep(for: .milliseconds(80))
        #expect(sampler.callCount == countAtCancel, "loop kept sampling after cancellation")
    }
```

Add to `macOSmonitorTests/ProcessListModelTests.swift`, inside the test struct. **Check the struct's isolation first:** `ProcessListModel` is `@MainActor`, so if the enclosing test struct is not already annotated `@MainActor`, mark this test `@Test @MainActor` instead of plain `@Test`.

```swift
    @Test func runStopsSamplingAfterCancellation() async {
        let sampler = FakeSampler()
        let model = ProcessListModel(sampler: sampler, interval: .milliseconds(10))

        let task = Task { await model.run() }
        try? await Task.sleep(for: .milliseconds(60))
        task.cancel()
        _ = await task.value

        let countAtCancel = sampler.callCount
        #expect(countAtCancel > 0, "loop should have sampled at least once before cancelling")

        try? await Task.sleep(for: .milliseconds(80))
        #expect(sampler.callCount == countAtCancel, "loop kept sampling after cancellation")
    }
```

- [ ] **Step 2: Run tests to verify they pass**

These test EXISTING behaviour, so they should pass immediately — that is the point. Run the standard test command. Expected: PASS, 115 tests.

**If either fails, stop and report BLOCKED.** A failure means one of the run loops does not actually stop on cancellation, which is a real defect that must be understood before the loop is moved to a longer-lived owner.

- [ ] **Step 3: Move the loop to `ContentView.swift`**

Change the `.task` line near the end of `ContentView`'s `body` from:

```swift
        .task { await vitalsModel.run() }
```

to:

```swift
        .task { await vitalsModel.run() }
        .task { await model.run() }
```

- [ ] **Step 4: Remove the loop from `ProcessesView.swift`**

Delete this line from `ProcessesView`'s `body` modifier chain:

```swift
        .task { await model.run() }
```

Leave `.onChange(of: model.selectedPID) { model.refreshSelection() }` exactly as it is.

- [ ] **Step 5: Run the tests**

Run the standard test command. Expected: PASS, 115 tests.

- [ ] **Step 6: Measure the app's own cost — REQUIRED**

The app lists itself, so this claim is measurable rather than assumed.

1. Check out the previous commit's build (`git stash` your changes, build, run) OR use the currently installed build from before this task.
2. Launch the app, leave it on the **Processes** surface, let it settle 60 seconds, and record macOSmonitor's own CPU% and Memory from its own table.
3. Restore your changes, rebuild, relaunch, and this time leave it on a **Performance** panel (where process sampling previously stopped and now continues) for 60 seconds. Record its CPU% and Memory again.
4. Note whether macOSmonitor appears in the top five rows when sorted by CPU% descending.

**Put both readings in your report.** If macOSmonitor now appears in its own top five CPU consumers, report `DONE_WITH_CONCERNS` and say so plainly — the spec names that as a failure of the milestone's own goal, and the pre-agreed remedy is a slower sampling cadence on non-Processes surfaces.

- [ ] **Step 7: Commit**

```bash
git add macOSmonitor/ContentView.swift macOSmonitor/ProcessesView.swift macOSmonitorTests/VitalsModelTests.swift macOSmonitorTests/ProcessListModelTests.swift
git commit -m "feat: sample processes app-wide; test both run loops cancel"
```

---

### Task 6: The Summary surface and `StatCard`

**Files:**

- Create: `macOSmonitor/StatCard.swift`
- Create: `macOSmonitor/SummaryView.swift`
- Modify: `macOSmonitor/Surface.swift`
- Modify: `macOSmonitor/ContentView.swift`

**Interfaces:**

- Consumes: `MeterBar` (Task 2), `Metric` / `Theme.color(for:)` (Task 1), `VitalsModel` (existing), `SystemVitals.diskText` / `.networkText` / `.thermalState` / `.battery` (existing).
- Produces: `struct StatCard: View` with `init(title:value:metric:fraction:)` (`fraction` defaults to nil), `struct SummaryView: View` with `init(model:vitalsModel:surface:)`, and `Surface.summary`.

This task lands the bottom row of the dashboard — four real cards with live data — so `StatCard` has a consumer from its first commit.

- [ ] **Step 1: Create `StatCard.swift`**

```swift
import SwiftUI

/// One small dashboard cell: a title, a live value, and an optional utilisation meter.
///
/// Used four times in the Summary's bottom row. Thermal passes no fraction because
/// thermal pressure is a category, not a proportion.
struct StatCard: View {
    let title: String
    let value: String
    let metric: Metric
    /// 0...1 utilisation; when nil no meter is drawn.
    var fraction: Double? = nil

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                Spacer()
            }
            Text(value)
                .font(.title3)
                .monospacedDigit()
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let fraction {
                MeterBar(fraction: fraction,
                         orientation: .horizontal,
                         onColor: theme.color(for: metric),
                         offColor: theme.meterOff)
                    .frame(height: 4)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.panelBackground)
    }
}
```

- [ ] **Step 2: Add `.summary` to `Surface.swift`**

Change the case list, `title`, and `metric` so `.summary` is present and listed first:

```swift
enum Surface: String, CaseIterable, Hashable, Identifiable {
    case summary, processes, cpu, memory, network, disk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .summary:   return "Summary"
        case .processes: return "Processes"
        case .cpu:       return "CPU"
        case .memory:    return "Memory"
        case .network:   return "Network"
        case .disk:      return "Disk"
        }
    }

    /// The metric this surface displays, if any. `.processes` shows a table, not a metric.
    var metric: Metric? {
        switch self {
        case .cpu:       return .cpu
        case .memory:    return .memory
        case .network:   return .network
        case .disk:      return .disk
        case .summary, .processes: return nil
        }
    }

    /// The four Performance panels, in sidebar order.
    static let performance: [Surface] = [.cpu, .memory, .network, .disk]
}
```

- [ ] **Step 3: Create `SummaryView.swift` with the bottom row**

```swift
import SwiftUI

/// The Summary dashboard: the app's landing surface.
///
/// Composes cards from data already sampled — no provider of its own. The upper
/// regions arrive in later tasks; the bottom stat row is here from the start.
struct SummaryView: View {
    let model: ProcessListModel
    let vitalsModel: VitalsModel
    @Binding var surface: Surface?

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            Spacer()          // replaced by the CPU/top-processes row in Task 7
            statRow
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.panelBackground)
    }

    private var statRow: some View {
        HStack(spacing: 12) {
            StatCard(title: "Disk",
                     value: vitalsModel.vitals?.diskText ?? "—",
                     metric: .disk)
            StatCard(title: "Network",
                     value: vitalsModel.vitals?.networkText ?? "—",
                     metric: .network)
            if let battery = vitalsModel.vitals?.battery {
                StatCard(title: "Battery",
                         value: battery.displayText,
                         metric: .battery)
            }
            StatCard(title: "Thermal",
                     value: vitalsModel.vitals?.thermalState ?? "—",
                     metric: .thermal)
        }
    }
}
```

The Battery card is inside `if let battery` so a machine without one shows three cards rather than a gap — M9's rule.

- [ ] **Step 4: Route `.summary` in `ContentView.swift`**

Change the surface default:

```swift
    @State private var surface: Surface? = .summary
```

Add a sidebar row for it, immediately above the existing `Label(Surface.processes.title, ...)` line:

```swift
                Label(Surface.summary.title, systemImage: "square.grid.2x2")
                    .tag(Surface.summary)
```

Add the routing case as the first case of the detail `switch`:

```swift
            case .summary:
                SummaryView(model: model, vitalsModel: vitalsModel, surface: $surface)
```

and change the switch's subject from `surface ?? .processes` to `surface ?? .summary`.

- [ ] **Step 5: Build and run the tests**

Run the standard test command. Expected: PASS, 115 tests (unchanged — view work).

- [ ] **Step 6: Verify by hand**

Launch the app. Confirm it opens on Summary, that the sidebar lists Summary first, that the four (or three) stat cards show live values that change, and that navigating to Processes and back still works.

- [ ] **Step 7: Commit**

```bash
git add macOSmonitor/StatCard.swift macOSmonitor/SummaryView.swift macOSmonitor/Surface.swift macOSmonitor/ContentView.swift
git commit -m "feat: add the Summary surface with its stat row"
```

---

### Task 7: CPU overview card and the meter strip

**Files:**

- Create: `macOSmonitor/CPUOverviewCard.swift`
- Modify: `macOSmonitor/SummaryView.swift`

**Interfaces:**

- Consumes: `MetricGraph(values:range:lineColor:fillColor:gridColor:)`, `MetricScale.fixed(_:)`, `VitalsModel.history.cpu`, `SystemVitals.cpuText`, `SystemVitals.coreCount` (all existing); `MeterBar` (Task 2); `Theme.color(for:)` (Task 1).
- Produces: `struct CPUOverviewCard: View` with `init(model: VitalsModel)`.

- [ ] **Step 1: Create `CPUOverviewCard.swift`**

```swift
import SwiftUI

/// The Summary's CPU cell: the utilisation trace plus the logical-processor count.
struct CPUOverviewCard: View {
    let model: VitalsModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("CPU Overview")
                    .font(.headline)
                    .foregroundStyle(theme.primaryText)
                Spacer()
                Text(model.vitals?.cpuText ?? "—")
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(theme.color(for: .cpu))
            }

            MetricGraph(values: model.history.cpu.values,
                        range: MetricScale.fixed(100),
                        lineColor: theme.color(for: .cpu),
                        fillColor: theme.graphFill,
                        gridColor: theme.gridLine)
                .frame(minHeight: 120)

            Text("\(model.vitals?.coreCount ?? 0) logical processors")
                .font(.caption2)
                .foregroundStyle(theme.secondaryText)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.panelBackground)
    }
}
```

- [ ] **Step 2: Add the strip and the card to `SummaryView.swift`**

Replace the `Spacer()` placeholder in `body` with `topRow`, and add these two computed properties to `SummaryView`:

```swift
    private var topRow: some View {
        HStack(alignment: .top, spacing: 12) {
            meterStrip
            CPUOverviewCard(model: vitalsModel)
        }
    }

    /// CPU and Memory only: they are the two metrics with a genuine 0-100% ceiling.
    /// Disk and Network rates have no natural maximum, so a "percent full" meter for
    /// them would be a fraction of a recent autoscaled peak — it would look like a
    /// utilisation reading without being one.
    private var meterStrip: some View {
        HStack(alignment: .bottom, spacing: 10) {
            verticalMeter(title: "CPU", metric: .cpu, fraction: cpuFraction)
            verticalMeter(title: "MEM", metric: .memory, fraction: memoryFraction)
        }
        .frame(width: 76)
    }

    private func verticalMeter(title: String, metric: Metric, fraction: Double) -> some View {
        VStack(spacing: 6) {
            MeterBar(fraction: fraction,
                     orientation: .vertical,
                     onColor: theme.color(for: metric),
                     offColor: theme.meterOff)
                .frame(width: 14)
            Text(title)
                .font(.caption2)
                .foregroundStyle(theme.secondaryText)
        }
    }

    private var cpuFraction: Double {
        (vitalsModel.vitals?.cpuUsagePercent ?? 0) / 100
    }

    private var memoryFraction: Double {
        guard let vitals = vitalsModel.vitals, vitals.totalMemoryBytes > 0 else { return 0 }
        return Double(vitals.usedMemoryBytes) / Double(vitals.totalMemoryBytes)
    }
```

- [ ] **Step 3: Build and run the tests**

Run the standard test command. Expected: PASS, 115 tests.

- [ ] **Step 4: Verify by hand**

Launch the app. Confirm the CPU trace grows on the Summary surface, the headline percentage tracks it, the logical-processor count matches this Mac, and the two vertical meters fill from the bottom and move independently.

- [ ] **Step 5: Commit**

```bash
git add macOSmonitor/CPUOverviewCard.swift macOSmonitor/SummaryView.swift
git commit -m "feat: add the CPU overview card and meter strip"
```

---

### Task 8: Memory card

**Files:**

- Create: `macOSmonitor/MemoryCard.swift`
- Modify: `macOSmonitor/SummaryView.swift`

**Interfaces:**

- Consumes: `MetricGraph`, `MetricScale.fixed(_:)`, `VitalsModel.history.memoryUsed`, `SystemVitals.memoryText`, `SystemVitals.totalMemoryBytes` (all existing); `Theme.color(for:)` (Task 1).
- Produces: `struct MemoryCard: View` with `init(model: VitalsModel)`.

- [ ] **Step 1: Create `MemoryCard.swift`**

```swift
import SwiftUI

/// The Summary's full-width memory band: used memory over time against total installed.
struct MemoryCard: View {
    let model: VitalsModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Memory")
                    .font(.headline)
                    .foregroundStyle(theme.primaryText)
                Spacer()
                Text(model.vitals?.memoryText ?? "—")
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(theme.color(for: .memory))
            }

            MetricGraph(values: model.history.memoryUsed.values,
                        range: MetricScale.fixed(Double(model.vitals?.totalMemoryBytes ?? 1)),
                        lineColor: theme.color(for: .memory),
                        fillColor: theme.graphFill,
                        gridColor: theme.gridLine)
                .frame(minHeight: 90)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.panelBackground)
    }
}
```

- [ ] **Step 2: Insert it into `SummaryView.body`**

The `VStack` becomes:

```swift
        VStack(spacing: 12) {
            topRow
            MemoryCard(model: vitalsModel)
            statRow
        }
```

- [ ] **Step 3: Build and run the tests**

Run the standard test command. Expected: PASS, 115 tests.

- [ ] **Step 4: Verify by hand**

Launch the app and confirm the memory band renders full width, its trace tracks real usage, and the headline matches Activity Monitor's memory used figure to within a reasonable margin.

- [ ] **Step 5: Commit**

```bash
git add macOSmonitor/MemoryCard.swift macOSmonitor/SummaryView.swift
git commit -m "feat: add the Summary memory card"
```

---

### Task 9: Top processes card

**Files:**

- Create: `macOSmonitor/TopProcessesCard.swift`
- Modify: `macOSmonitor/SummaryView.swift`

**Interfaces:**

- Consumes: `ProcessListModel.topByCPU(limit:)` (Task 4), `ProcessInfoRow.pid` / `.name` / `.cpuText` (all existing; `cpuText` is the same property the Processes table's CPU column renders).
- Produces: `struct TopProcessesCard: View` with `init(model: ProcessListModel, limit: Int = 8)`.

- [ ] **Step 1: Create `TopProcessesCard.swift`**

```swift
import SwiftUI

/// The Summary's process cell: the busiest processes by CPU.
///
/// Read-only by design — selecting and terminating live on the Processes surface.
struct TopProcessesCard: View {
    let model: ProcessListModel
    var limit: Int = 8

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Top Processes")
                .font(.headline)
                .foregroundStyle(theme.primaryText)

            let rows = model.topByCPU(limit: limit)
            if rows.isEmpty {
                Text("Sampling…")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            } else {
                ForEach(rows) { row in
                    HStack(spacing: 8) {
                        Text(String(row.pid))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(theme.secondaryText)
                            .frame(width: 50, alignment: .trailing)
                        Text(row.name)
                            .font(.caption)
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 8)
                        Text(row.cpuText)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(theme.color(for: .cpu))
                            .frame(width: 50, alignment: .trailing)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.panelBackground)
    }
}
```

- [ ] **Step 2: Add it to the top row in `SummaryView.swift`**

`topRow` becomes:

```swift
    private var topRow: some View {
        HStack(alignment: .top, spacing: 12) {
            meterStrip
            CPUOverviewCard(model: vitalsModel)
            TopProcessesCard(model: model)
                .frame(width: 280)
        }
    }
```

- [ ] **Step 3: Build and run the tests**

Run the standard test command. Expected: PASS, 115 tests.

- [ ] **Step 4: Verify by hand**

Launch the app and confirm the list shows eight processes ordered by descending CPU, that the values update roughly once a second, and — importantly — that rows sitting at 0% do NOT visibly reshuffle between ticks (the PID tiebreak from Task 4). Cross-check the top few names against Activity Monitor.

- [ ] **Step 5: Commit**

```bash
git add macOSmonitor/TopProcessesCard.swift macOSmonitor/SummaryView.swift
git commit -m "feat: add the top processes card"
```

---

### Task 10: Card navigation and the full verification pass

**Files:**

- Modify: `macOSmonitor/SummaryView.swift`

**Interfaces:**

- Consumes: `Surface` (Task 6), the `surface` binding already held by `SummaryView`.
- Produces: no new API.

- [ ] **Step 1: Make the cards navigation targets**

Wrap each card in a plain `Button` that sets the bound surface. In `SummaryView`, replace the three card call sites as follows.

In `topRow`:

```swift
            Button { surface = .cpu } label: {
                CPUOverviewCard(model: vitalsModel)
            }
            .buttonStyle(.plain)

            Button { surface = .processes } label: {
                TopProcessesCard(model: model)
                    .frame(width: 280)
            }
            .buttonStyle(.plain)
```

In `body`, the memory band:

```swift
            Button { surface = .memory } label: {
                MemoryCard(model: vitalsModel)
            }
            .buttonStyle(.plain)
```

In `statRow`, wrap the Disk and Network cards:

```swift
            Button { surface = .disk } label: {
                StatCard(title: "Disk",
                         value: vitalsModel.vitals?.diskText ?? "—",
                         metric: .disk)
            }
            .buttonStyle(.plain)

            Button { surface = .network } label: {
                StatCard(title: "Network",
                         value: vitalsModel.vitals?.networkText ?? "—",
                         metric: .network)
            }
            .buttonStyle(.plain)
```

Leave the Battery and Thermal cards unwrapped: they have no corresponding surface to navigate to.

- [ ] **Step 2: Build and run the full suite**

Run the standard test command. Expected: PASS, 115 tests, and confirm the run is clean.

- [ ] **Step 3: Full hand-verification pass — report what you actually observed for each**

1. The app opens on Summary.
2. Clicking the CPU card selects the CPU panel; memory → Memory; disk → Disk; network → Network; top-processes → Processes. Battery and Thermal are not clickable.
3. Sidebar meters follow the theme (not the system accent) and keep updating live while Summary is displayed.
4. All five themes render legibly in system **Light** Mode and in **Dark** Mode. Pay particular attention to the System theme, where the per-metric hues sit on an adaptive background.
5. The layout holds together at the 900×500 minimum window size. **If it does not, report it — do not redesign.** The spec lists this as an open question with a reflow rule as the expected remedy.

- [ ] **Step 4: Commit**

```bash
git add macOSmonitor/SummaryView.swift
git commit -m "feat: make Summary cards navigate to their panels"
```

---

## Done criteria

- [ ] All ten tasks committed
- [ ] `xcodebuild ... -only-testing:macOSmonitorTests test` passes with 115 tests
- [ ] The app launches on Summary and every card navigates to its panel
- [ ] Sidebar meters follow the active theme rather than the system accent
- [ ] Per-metric hues pass 3:1 contrast against both the light and dark system background
- [ ] Process rows on the Summary card do not reshuffle between ticks at equal CPU
- [ ] macOSmonitor's own CPU cost is recorded before and after Task 5, and it does not appear in its own top five
