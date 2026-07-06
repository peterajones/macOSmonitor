# System Vitals Header (Milestone 7) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A live system-vitals header bar above the table showing CPU%, memory used/total, cores, thermal, low-power, uptime, and OS.

**Architecture:** A `SystemVitals` snapshot value type; a `HostStats` shim isolating Mach `host_processor_info`/`host_statistics64`; a `SystemVitalsSampler` actor computing CPU% from tick deltas + reading memory and `ProcessInfo` facts; `ProcessListModel` publishes `vitals` each tick; `ContentView` puts a `SystemVitalsView` above the table.

**Tech Stack:** Swift, SwiftUI, `ProcessInfo`, Mach host stats via Darwin, Swift Testing, Xcode 26.

## Global Constraints

- **Platform / project:** existing `macOSmonitor` macOS app, non-sandboxed, `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated`. Test import: `@testable import macOSmonitor`.
- **Build:** `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' build`
- **Test:** `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test` (MUST scope to `macOSmonitorTests`; the UI-test target times out under CLI).
- **Verified Mach facts (do not re-derive):** `host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount)` with `var info: processor_info_array_t? = nil`; rebind via `info.withMemoryRebound(to: processor_cpu_load_info.self, capacity: Int(count))`, `cpu_ticks` is `(user, system, idle, nice)` (`.0/.1/.2/.3`); `vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))`. `host_statistics64(mach_host_self(), HOST_VM_INFO64, …)` into `vm_statistics64_data_t` (count = `sizeof(vm_statistics64_data_t)/sizeof(integer_t)`); used = `(active_count + wire_count + compressor_page_count) × UInt64(vm_page_size)`. `ProcessInfo`: `.processorCount`, `.activeProcessorCount`, `.thermalState`, `.isLowPowerModeEnabled`, `.systemUptime`, `.operatingSystemVersion`, `.physicalMemory`.
- **CPU% is self-normalizing:** `100 × Δbusy / Δtotal`; no wall clock. First tick → 0.
- **SourceKit** "No such module 'Testing'" / "Cannot find type" diagnostics are indexer lag — trust `xcodebuild` only.

---

### Task 1: `SystemVitals` value type + formatting

**Files:**
- Create: `macOSmonitor/SystemVitals.swift`
- Test: `macOSmonitorTests/SystemVitalsTests.swift`

**Interfaces:**
- Produces: `struct SystemVitals: Equatable, Sendable` (fields per spec) with computeds `cpuText`, `memoryText`, `coresText`, `uptimeText`.

- [ ] **Step 1: Write the failing tests**

Create `macOSmonitorTests/SystemVitalsTests.swift`:

```swift
import Testing
@testable import macOSmonitor

struct SystemVitalsTests {
    private func make(cpu: Double = 0, used: UInt64 = 0, total: UInt64 = 0,
                      cores: Int = 8, uptime: TimeInterval = 0) -> SystemVitals {
        SystemVitals(cpuUsagePercent: cpu, usedMemoryBytes: used, totalMemoryBytes: total,
                     coreCount: cores, activeCoreCount: cores, thermalState: "Nominal",
                     lowPowerMode: false, uptime: uptime, osVersion: "macOS 26.5")
    }

    @Test func cpuTextRoundsToWholePercent() {
        #expect(make(cpu: 34.4).cpuText == "CPU 34%")
    }

    @Test func memoryTextIsDecimalGB() {
        #expect(make(used: 12_300_000_000, total: 32_000_000_000).memoryText == "12.3 / 32 GB")
    }

    @Test func coresText() {
        #expect(make(cores: 10).coresText == "10 cores")
    }

    @Test func uptimeTextDaysHours() {
        #expect(make(uptime: 3 * 86_400 + 4 * 3_600 + 30 * 60).uptimeText == "up 3d 4h")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests build-for-testing 2>&1 | grep -iE 'error:|cannot find'`
Expected: FAIL — `cannot find 'SystemVitals' in scope`.

- [ ] **Step 3: Implement**

Create `macOSmonitor/SystemVitals.swift`:

```swift
import Foundation

/// A snapshot of system-wide vitals shown in the header bar.
struct SystemVitals: Equatable, Sendable {
    let cpuUsagePercent: Double
    let usedMemoryBytes: UInt64
    let totalMemoryBytes: UInt64
    let coreCount: Int
    let activeCoreCount: Int
    let thermalState: String     // "Nominal" / "Fair" / "Serious" / "Critical"
    let lowPowerMode: Bool
    let uptime: TimeInterval
    let osVersion: String        // e.g. "macOS 26.5"

    var cpuText: String { "CPU \(Int(cpuUsagePercent.rounded()))%" }

    var memoryText: String {
        let usedGB = Double(usedMemoryBytes) / 1_000_000_000
        let totalGB = Double(totalMemoryBytes) / 1_000_000_000
        return String(format: "%.1f / %.0f GB", usedGB, totalGB)
    }

    var coresText: String { "\(coreCount) cores" }

    var uptimeText: String {
        let s = Int(uptime)
        let d = s / 86_400, h = (s % 86_400) / 3_600, m = (s % 3_600) / 60
        if d > 0 { return "up \(d)d \(h)h" }
        if h > 0 { return "up \(h)h \(m)m" }
        return "up \(m)m"
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test 2>&1 | grep -iE 'SystemVitalsTests.*(passed|failed)|TEST (SUCCEEDED|FAILED)'`
Expected: `** TEST SUCCEEDED **`, all four format tests pass.

- [ ] **Step 5: Commit**

```bash
git add macOSmonitor/SystemVitals.swift macOSmonitorTests/SystemVitalsTests.swift
git commit -m "feat: add SystemVitals snapshot value type with formatting"
```

---

### Task 2: `HostStats` — Mach host CPU/memory shim

**Files:**
- Modify: `macOSmonitor/SystemVitals.swift` (append protocol + `HostStats`)
- Test: `macOSmonitorTests/HostStatsTests.swift`

**Interfaces:**
- Produces:
  - `protocol HostStatsProviding: Sendable { func cpuTicks() -> (busy: UInt64, total: UInt64)?; func memory() -> (used: UInt64, total: UInt64)? }`
  - `struct HostStats: HostStatsProviding` (real Mach implementation).

- [ ] **Step 1: Write the failing integration test**

Create `macOSmonitorTests/HostStatsTests.swift`:

```swift
import Testing
import Foundation
@testable import macOSmonitor

struct HostStatsTests {
    let sut = HostStats()

    @Test func cpuTicksAccumulate() {
        #expect((sut.cpuTicks()?.total ?? 0) > 0)
    }

    @Test func memoryIsSaneAgainstPhysical() {
        let mem = sut.memory()
        #expect(mem?.total == ProcessInfo.processInfo.physicalMemory)
        #expect((mem?.used ?? 0) > 0)
        #expect((mem?.used ?? .max) < (mem?.total ?? 0))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests build-for-testing 2>&1 | grep -iE 'error:|cannot find'`
Expected: FAIL — `cannot find 'HostStats' in scope`.

- [ ] **Step 3: Implement**

Append to `macOSmonitor/SystemVitals.swift`:

```swift
import Darwin
import Darwin.Mach

/// Raw host CPU/memory reads, isolated behind a protocol so the sampler can be tested with a fake.
protocol HostStatsProviding: Sendable {
    func cpuTicks() -> (busy: UInt64, total: UInt64)?
    func memory() -> (used: UInt64, total: UInt64)?
}

struct HostStats: HostStatsProviding {
    func cpuTicks() -> (busy: UInt64, total: UInt64)? {
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
        var busy: UInt64 = 0, total: UInt64 = 0
        info.withMemoryRebound(to: processor_cpu_load_info.self, capacity: Int(cpuCount)) { ptr in
            for i in 0..<Int(cpuCount) {
                let t = ptr[i].cpu_ticks          // (user, system, idle, nice)
                let active = UInt64(t.0) + UInt64(t.1) + UInt64(t.3)
                busy += active
                total += active + UInt64(t.2)
            }
        }
        return (busy, total)
    }

    func memory() -> (used: UInt64, total: UInt64)? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size
                                           / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_page_size)
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count)
                    + UInt64(stats.compressor_page_count)) * page
        return (used, ProcessInfo.processInfo.physicalMemory)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test 2>&1 | grep -iE 'HostStatsTests.*(passed|failed)|TEST (SUCCEEDED|FAILED)'`
Expected: `** TEST SUCCEEDED **` — CPU ticks positive; memory total equals physical RAM and 0 < used < total.

- [ ] **Step 5: Commit**

```bash
git add macOSmonitor/SystemVitals.swift macOSmonitorTests/HostStatsTests.swift
git commit -m "feat: add HostStats Mach shim for host CPU ticks and memory"
```

---

### Task 3: `SystemVitalsSampler` — CPU% delta + vitals assembly

**Files:**
- Create: `macOSmonitor/SystemVitalsSampler.swift`
- Test: `macOSmonitorTests/SystemVitalsSamplerTests.swift`

**Interfaces:**
- Consumes: `SystemVitals`, `HostStatsProviding` (Tasks 1–2).
- Produces:
  - `protocol SystemVitalsSampling: Sendable { func sample() async -> SystemVitals }`
  - `actor SystemVitalsSampler: SystemVitalsSampling` with `init(host: any HostStatsProviding = HostStats())`.

- [ ] **Step 1: Write the failing test**

Create `macOSmonitorTests/SystemVitalsSamplerTests.swift`:

```swift
import Testing
@testable import macOSmonitor

final class FakeHostStats: HostStatsProviding, @unchecked Sendable {
    var ticks: (busy: UInt64, total: UInt64)?
    var mem: (used: UInt64, total: UInt64)?
    func cpuTicks() -> (busy: UInt64, total: UInt64)? { ticks }
    func memory() -> (used: UInt64, total: UInt64)? { mem }
}

struct SystemVitalsSamplerTests {
    @Test func firstTickZeroThenDeltaPercent() async {
        let fake = FakeHostStats()
        fake.mem = (used: 1_000, total: 2_000)
        fake.ticks = (busy: 100, total: 1_000)
        let sampler = SystemVitalsSampler(host: fake)

        let first = await sampler.sample()
        #expect(first.cpuUsagePercent == 0)             // no baseline yet
        #expect(first.usedMemoryBytes == 1_000)
        #expect(first.totalMemoryBytes == 2_000)

        fake.ticks = (busy: 150, total: 1_100)          // +50 busy / +100 total → 50%
        let second = await sampler.sample()
        #expect(second.cpuUsagePercent == 50)
    }

    @Test func vitalsReflectRealProcessInfoFacts() async {
        let sampler = SystemVitalsSampler(host: FakeHostStats())
        let v = await sampler.sample()
        #expect(v.coreCount == ProcessInfo.processInfo.processorCount)
        #expect(v.osVersion.hasPrefix("macOS "))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests build-for-testing 2>&1 | grep -iE 'error:|cannot find'`
Expected: FAIL — `cannot find 'SystemVitalsSampler' in scope`.

- [ ] **Step 3: Implement**

Create `macOSmonitor/SystemVitalsSampler.swift`:

```swift
import Foundation

protocol SystemVitalsSampling: Sendable {
    func sample() async -> SystemVitals
}

/// Assembles a `SystemVitals` each tick: CPU% from host tick deltas (self-normalizing,
/// no wall clock), memory from the host shim, and the rest from `ProcessInfo`. Actor so
/// the syscalls run off the main thread; holds the previous CPU ticks for the delta.
actor SystemVitalsSampler: SystemVitalsSampling {
    private let host: any HostStatsProviding
    private var previousTicks: (busy: UInt64, total: UInt64)?

    init(host: any HostStatsProviding = HostStats()) {
        self.host = host
    }

    func sample() -> SystemVitals {
        var cpuPercent = 0.0
        if let ticks = host.cpuTicks() {
            if let previous = previousTicks, ticks.total > previous.total {
                let deltaBusy = ticks.busy - previous.busy
                let deltaTotal = ticks.total - previous.total
                if deltaTotal > 0 { cpuPercent = 100.0 * Double(deltaBusy) / Double(deltaTotal) }
            }
            previousTicks = ticks
        }

        let info = ProcessInfo.processInfo
        let memory = host.memory()
        let version = info.operatingSystemVersion

        return SystemVitals(
            cpuUsagePercent: cpuPercent,
            usedMemoryBytes: memory?.used ?? 0,
            totalMemoryBytes: memory?.total ?? info.physicalMemory,
            coreCount: info.processorCount,
            activeCoreCount: info.activeProcessorCount,
            thermalState: Self.thermalName(info.thermalState),
            lowPowerMode: info.isLowPowerModeEnabled,
            uptime: info.systemUptime,
            osVersion: "macOS \(version.majorVersion).\(version.minorVersion)"
        )
    }

    private static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test 2>&1 | grep -iE 'SystemVitalsSampler.*(passed|failed)|TEST (SUCCEEDED|FAILED)'`
Expected: `** TEST SUCCEEDED **` — first tick 0%, second 50%; core count matches ProcessInfo.

- [ ] **Step 5: Commit**

```bash
git add macOSmonitor/SystemVitalsSampler.swift macOSmonitorTests/SystemVitalsSamplerTests.swift
git commit -m "feat: add SystemVitalsSampler actor with self-normalizing CPU%"
```

---

### Task 4: `ProcessListModel` — publish `vitals`

**Files:**
- Modify: `macOSmonitor/ProcessListModel.swift`
- Test: `macOSmonitorTests/ProcessListModelTests.swift` (add a fake + case)

**Interfaces:**
- Consumes: `SystemVitals`, `SystemVitalsSampling` (Tasks 1/3).
- Produces: `private(set) var vitals: SystemVitals?`; injected `vitalsSampler: any SystemVitalsSampling = SystemVitalsSampler()`; `refreshOnce()` publishes `vitals`.

- [ ] **Step 1: Add the failing test**

In `macOSmonitorTests/ProcessListModelTests.swift`, add this fake at file scope (after `FakePortProvider`):

```swift
final class FakeVitalsSampler: SystemVitalsSampling, @unchecked Sendable {
    var next = SystemVitals(cpuUsagePercent: 5, usedMemoryBytes: 1, totalMemoryBytes: 2,
                            coreCount: 8, activeCoreCount: 8, thermalState: "Nominal",
                            lowPowerMode: false, uptime: 60, osVersion: "macOS 26.5")
    private(set) var callCount = 0
    func sample() async -> SystemVitals { callCount += 1; return next }
}
```

And add this test inside `struct ProcessListModelTests`:

```swift
    @Test func refreshOncePublishesVitals() async {
        let model = ProcessListModel(sampler: FakeSampler(), vitalsSampler: FakeVitalsSampler())
        #expect(model.vitals == nil)
        await model.refreshOnce()
        #expect(model.vitals?.coreCount == 8)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests build-for-testing 2>&1 | grep -iE 'error:'`
Expected: FAIL — extra argument `vitalsSampler` / no member `vitals`.

- [ ] **Step 3: Update the model**

In `macOSmonitor/ProcessListModel.swift`:

(a) Add the stored property after `selectedPorts`:

```swift
    /// Latest system-wide vitals for the header; nil until the first sample.
    private(set) var vitals: SystemVitals?
```

(b) Add the dependency + init parameter (place `vitalsSampler` after `portProvider`):

```swift
    private let portProvider: any ProcessPortProviding
    private let vitalsSampler: any SystemVitalsSampling
    private let interval: Duration

    init(sampler: any ProcessSampling = ProcessSampler(),
         terminator: any ProcessTerminating = ProcessTerminator(),
         detailProvider: any ProcessDetailProviding = ProcInfo(),
         portProvider: any ProcessPortProviding = ProcInfo(),
         vitalsSampler: any SystemVitalsSampling = SystemVitalsSampler(),
         interval: Duration = .seconds(1)) {
        self.sampler = sampler
        self.terminator = terminator
        self.detailProvider = detailProvider
        self.portProvider = portProvider
        self.vitalsSampler = vitalsSampler
        self.interval = interval
    }
```

(c) Publish vitals in `refreshOnce()` (after the existing rows + `refreshSelection()` lines):

```swift
    func refreshOnce() async {
        rows = await sampler.sample()
        refreshSelection()
        vitals = await vitalsSampler.sample()
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test 2>&1 | grep -iE 'refreshOncePublishesVitals.*(passed|failed)|TEST (SUCCEEDED|FAILED)'`
Expected: `** TEST SUCCEEDED **`, including the new test; existing model tests still pass.

- [ ] **Step 5: Commit**

```bash
git add macOSmonitor/ProcessListModel.swift macOSmonitorTests/ProcessListModelTests.swift
git commit -m "feat: publish system vitals from ProcessListModel each tick"
```

---

### Task 5: `SystemVitalsView` header + `ContentView` layout

**Files:**
- Create: `macOSmonitor/SystemVitalsView.swift`
- Modify: `macOSmonitor/ContentView.swift`

**Interfaces:**
- Consumes: `ProcessListModel.vitals` (Task 4), `SystemVitals` computeds (Task 1).
- Produces: the header UI. No unit test (SwiftUI views); validated by build + manual verification.

- [ ] **Step 1: Create the header view**

Create `macOSmonitor/SystemVitalsView.swift`:

```swift
import SwiftUI

/// A full-width header bar of labeled system-vital stat items.
struct SystemVitalsView: View {
    let vitals: SystemVitals?

    var body: some View {
        HStack(spacing: 16) {
            item("CPU", vitals?.cpuText ?? "—")
            item("Memory", vitals?.memoryText ?? "—")
            item("Cores", vitals?.coresText ?? "—")
            item("Thermal", vitals?.thermalState ?? "—")
            if vitals?.lowPowerMode == true { item("Power", "Low Power") }
            item("Uptime", vitals?.uptimeText ?? "—")
            item("OS", vitals?.osVersion ?? "—")
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func item(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout).monospacedDigit()
        }
    }
}
```

- [ ] **Step 2: Wrap the table with the header in `ContentView`**

In `macOSmonitor/ContentView.swift`, replace this block (the `ProcessTableView(...)` through the end of its `.contextMenu { … }`):

```swift
        ProcessTableView(
            data: model.rows.filter { $0.matches(searchText) }.sorted(using: sortOrder),
            selection: $model.selectedPID,
            sortOrder: $sortOrder
        )
        .contextMenu(forSelectionType: pid_t.self) { ids in
            let row = ids.first.flatMap { id in model.rows.first(where: { $0.id == id }) }
            Button("Quit") { requestTermination(row, force: false) }
                .disabled(row?.canTerminate != true)
            Button("Force Quit") { requestTermination(row, force: true) }
                .disabled(row?.canTerminate != true)
        }
```

with the VStack-wrapped version (the header + divider above the table; the `.contextMenu` stays on the table):

```swift
        VStack(spacing: 0) {
            SystemVitalsView(vitals: model.vitals)
            Divider()
            ProcessTableView(
                data: model.rows.filter { $0.matches(searchText) }.sorted(using: sortOrder),
                selection: $model.selectedPID,
                sortOrder: $sortOrder
            )
            .contextMenu(forSelectionType: pid_t.self) { ids in
                let row = ids.first.flatMap { id in model.rows.first(where: { $0.id == id }) }
                Button("Quit") { requestTermination(row, force: false) }
                    .disabled(row?.canTerminate != true)
                Button("Force Quit") { requestTermination(row, force: true) }
                    .disabled(row?.canTerminate != true)
            }
        }
```

The following modifiers (`.toolbar`, `.frame`, `.navigationTitle`, `.searchable`, `.focusedSceneValue`, `.task`, `.onChange`, `.inspector`, `.confirmationDialog`, `.alert`) are unchanged — they now attach to the `VStack` instead of the table. Do NOT move `.contextMenu` — it must stay on `ProcessTableView` (inside the VStack), as shown.

- [ ] **Step 3: Build**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' build 2>&1 | grep -iE 'error:|BUILD (SUCCEEDED|FAILED)'`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run the full unit suite (nothing regressed)**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test 2>&1 | grep -E 'TEST (SUCCEEDED|FAILED)'`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Manual verification**

Launch the app. Verify:
- A **header bar** sits above the table with CPU / Memory / Cores / Thermal / Uptime / OS.
- **CPU%** moves live; spawn `yes > /dev/null &` and watch it rise; kill it and watch it fall. Ballpark-match Activity Monitor's CPU load / `top`.
- **Memory used/total** is in the right ballpark vs Activity Monitor's Memory tab (used excludes cached).
- **Cores**, **Thermal** (likely "Nominal"), **Uptime**, **OS** are correct.
- The table, search, inspector, and Quit/Force-Quit all still work (the modifier migration didn't break them). Right-click a row → context menu still appears.

- [ ] **Step 6: Commit**

```bash
git add macOSmonitor/SystemVitalsView.swift macOSmonitor/ContentView.swift
git commit -m "feat: system vitals header bar above the process table"
```

---

## Definition of Done (Milestone 7)

- A header bar above the table shows CPU%, memory used/total, cores, thermal, uptime, OS (and Low Power when on).
- CPU% and memory update live and roughly match Activity Monitor.
- All existing features (table, search, inspector, termination, context menu) still work after the layout change.
- All unit + integration tests pass via `xcodebuild ... -only-testing:macOSmonitorTests test`.
- Each task committed separately.
