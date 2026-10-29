# Process Dashboard (Milestone 1) Implementation Plan

**Status:** FOLDED into TODO.md

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a read-only, live, sortable SwiftUI process table for macOS that tracks Activity Monitor's CPU% and memory figures.

**Architecture:** Four units with the unsafe C surface isolated to one file: `ProcInfo` (raw `libproc` syscalls) → `ProcessSampler` (an `actor` that diffs CPU-time snapshots off the main thread) → `ProcessListModel` (`@MainActor @Observable`, runs the ~1 Hz loop) → SwiftUI `Table`. Data flows one way: syscalls up to a finished `[ProcessInfoRow]` the view renders.

**Tech Stack:** Swift, SwiftUI (`Table`), Swift Concurrency (`actor`, `@Observable`), `libproc`/Darwin, Swift Testing (`import Testing`), Xcode 26 (`xcodebuild`).

## Global Constraints

- **Platform:** macOS app, non-sandboxed (App Sandbox capability removed). Xcode 26.x.
- **Module / product name:** `macOSmonitor`. Test target: `macOSmonitorTests`. Test import: `@testable import macOSmonitor`.
- **No bridging header:** all `libproc` symbols resolve via `import Darwin`.
- **CPU-time units:** `proc_taskinfo.pti_total_user`/`pti_total_system` are **Mach absolute-time ticks**, NOT nanoseconds. `ProcInfo` MUST convert ticks → nanoseconds with `mach_timebase_info` before returning. (Verified empirically: numer/denom = 125/3 on this machine; a busy core reads ~100% only after conversion.)
- **Decision A:** when `proc_pidinfo` is denied (EPERM, other users'/root processes) or the process has exited, emit a row with `name` + `pid` and `nil` CPU/memory. Never crash, never filter it out.
- **File placement:** app sources live under `macOSmonitor/`, tests under `macOSmonitorTests/`. Xcode uses file-system-synchronized groups, so files created on disk in those folders are automatically part of the target — no `.pbxproj` editing.
- **Build command:** `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' build`
- **Test command:** `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' test`

---

### Task 1: Create & configure the Xcode project

This is a manual setup task (Xcode's New Project GUI), folded together with build verification and the first commit. A subagent cannot click through Xcode — if you are a subagent, STOP and hand this task back to the human with the instructions below.

**Files:**
- Create: `macOSmonitor.xcodeproj` (via Xcode)
- Create: `macOSmonitor/macOSmonitorApp.swift` (generated)
- Create: `macOSmonitor/ContentView.swift` (generated placeholder, replaced in Task 6)
- Create: `macOSmonitorTests/` (generated test target)

**Interfaces:**
- Produces: a buildable `macOSmonitor` scheme and a `macOSmonitorTests` unit-test target using Swift Testing.

- [ ] **Step 1: Create the project in Xcode, then move it to the repo root**

The repo folder `/Users/pjones/Desktop/macOSmonitor/` already exists (with `.git` and `docs/`), but Xcode's New Project dialog insists on creating its *own* `macOSmonitor/` folder — which would collide or nest. So create it in a scratch location first, then move the generated files into the repo root.

In Xcode: File → New → Project → **macOS** → **App** → Next. Set:
- Product Name: `macOSmonitor`
- Interface: **SwiftUI**
- Language: **Swift**
- Testing System: **Swift Testing** (with **Include Tests** checked)
- Storage: **None** (no Core Data)

Save it to a scratch location — e.g. **`~/Desktop/`** is fine only if you then move it; to avoid any collision, save to **`~/Developer/`** (create it if needed). Uncheck "Create Git repository". Xcode produces `~/Developer/macOSmonitor/` containing `macOSmonitor.xcodeproj`, `macOSmonitor/`, and `macOSmonitorTests/`.

Then move those three items into the repo root and remove the now-empty scratch folder:

```bash
mv ~/Developer/macOSmonitor/macOSmonitor.xcodeproj \
   ~/Developer/macOSmonitor/macOSmonitor \
   ~/Developer/macOSmonitor/macOSmonitorTests \
   /Users/pjones/Desktop/macOSmonitor/
rmdir ~/Developer/macOSmonitor 2>/dev/null || true
```

Confirm `/Users/pjones/Desktop/macOSmonitor/macOSmonitor.xcodeproj` now exists at the repo root (so every `xcodebuild -project macOSmonitor.xcodeproj ...` command below runs from the repo root).

- [ ] **Step 2: Remove the App Sandbox capability**

Select the project → `macOSmonitor` target → **Signing & Capabilities**. If an **App Sandbox** capability is present, hover it and click the **×** to remove it. (Why: the sandbox blocks `proc_pidinfo` for processes we don't own, and even restricts enumeration. A non-sandboxed app can enumerate all PIDs and read full detail for the user's own processes — exactly M1's scope.) Confirm `macOSmonitor/macOSmonitor.entitlements` either no longer exists or no longer contains `com.apple.security.app-sandbox`.

- [ ] **Step 3: Verify it builds from the command line**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Verify the empty test target runs**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' test`
Expected: `** TEST SUCCEEDED **` (the template ships one trivial passing test).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore: scaffold non-sandboxed SwiftUI macOS app with tests"
```

---

### Task 2: `ProcInfo` — the isolated libproc shim

**Files:**
- Create: `macOSmonitor/ProcInfo.swift`
- Test: `macOSmonitorTests/ProcInfoTests.swift`

**Interfaces:**
- Produces:
  - `struct ProcTaskSample: Sendable { let residentBytes: UInt64; let cpuTimeNanos: UInt64 }`
  - `protocol ProcInfoProviding: Sendable { func listPIDs() -> [pid_t]; func sample(pid: pid_t) -> ProcTaskSample?; func name(pid: pid_t) -> String }`
  - `struct ProcInfo: ProcInfoProviding` — real implementation. `sample` returns `nil` on EPERM/exit; `cpuTimeNanos` is already converted from Mach ticks to nanoseconds.

- [ ] **Step 1: Write the failing test**

Create `macOSmonitorTests/ProcInfoTests.swift`:

```swift
import Testing
import Darwin
@testable import macOSmonitor

struct ProcInfoTests {
    let sut = ProcInfo()

    @Test func listPIDsIncludesOurOwnProcess() {
        #expect(sut.listPIDs().contains(getpid()))
    }

    @Test func sampleForSelfReportsMemory() {
        let sample = sut.sample(pid: getpid())
        #expect(sample != nil)
        #expect((sample?.residentBytes ?? 0) > 0)
    }

    @Test func nameForSelfIsNonEmpty() {
        #expect(!sut.name(pid: getpid()).isEmpty)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' test`
Expected: FAIL — compile error, `cannot find 'ProcInfo' in scope`.

- [ ] **Step 3: Write the implementation**

Create `macOSmonitor/ProcInfo.swift`:

```swift
import Darwin
import Foundation

/// One finished per-process sample. `cpuTimeNanos` is total (user+system) CPU
/// time already converted from Mach ticks to nanoseconds.
struct ProcTaskSample: Sendable {
    let residentBytes: UInt64
    let cpuTimeNanos: UInt64
}

/// Everything unsafe/C lives behind this protocol so `ProcessSampler` can be
/// tested with a fake and no other file touches raw syscalls.
protocol ProcInfoProviding: Sendable {
    func listPIDs() -> [pid_t]
    func sample(pid: pid_t) -> ProcTaskSample?
    func name(pid: pid_t) -> String
}

struct ProcInfo: ProcInfoProviding {
    // mach_timebase is constant for the life of the process; capture it once.
    private let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    func listPIDs() -> [pid_t] {
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return [] }
        let capacity = Int(needed) / MemoryLayout<pid_t>.stride
        var pids = [pid_t](repeating: 0, count: capacity)
        let written = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count))
        }
        guard written > 0 else { return [] }
        let count = Int(written) / MemoryLayout<pid_t>.stride
        return Array(pids.prefix(count).filter { $0 != 0 })
    }

    func sample(pid: pid_t) -> ProcTaskSample? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        // Returns `size` on success; 0/negative on EPERM or a vanished process.
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        let ticks = info.pti_total_user &+ info.pti_total_system
        let nanos = ticks &* UInt64(timebase.numer) / UInt64(timebase.denom)
        return ProcTaskSample(residentBytes: info.pti_resident_size, cpuTimeNanos: nanos)
    }

    func name(pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(2 * MAXCOMLEN))
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        if length > 0 { return String(cString: buffer) }
        return "(pid \(pid))"
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' test`
Expected: `** TEST SUCCEEDED **` — all three `ProcInfoTests` pass.

- [ ] **Step 5: Commit**

```bash
git add macOSmonitor/ProcInfo.swift macOSmonitorTests/ProcInfoTests.swift
git commit -m "feat: add ProcInfo libproc shim with mach-timebase CPU conversion"
```

---

### Task 3: `ProcessInfoRow` — the view data model

**Files:**
- Create: `macOSmonitor/ProcessInfoRow.swift`
- Test: `macOSmonitorTests/ProcessInfoRowTests.swift`

**Interfaces:**
- Produces: `struct ProcessInfoRow: Identifiable, Hashable, Sendable` with stored `pid: pid_t`, `name: String`, `cpuPercent: Double?`, `memoryBytes: UInt64?`; computed `id: pid_t` (= `pid`), `cpuSortKey: Double` (`cpuPercent ?? -1`), `memSortKey: UInt64` (`memoryBytes ?? 0`).
- Rationale: `Double?`/`UInt64?` are not `Comparable`, so SwiftUI `Table` cannot sort on them directly. The non-optional sort keys make columns sortable while denied rows (`nil`) sort to the bottom.

- [ ] **Step 1: Write the failing test**

Create `macOSmonitorTests/ProcessInfoRowTests.swift`:

```swift
import Testing
@testable import macOSmonitor

struct ProcessInfoRowTests {
    @Test func idEqualsPid() {
        let row = ProcessInfoRow(pid: 99, name: "x", cpuPercent: 1, memoryBytes: 1)
        #expect(row.id == 99)
    }

    @Test func sortKeysUseSentinelsWhenDetailMissing() {
        let denied = ProcessInfoRow(pid: 5, name: "x", cpuPercent: nil, memoryBytes: nil)
        #expect(denied.cpuSortKey == -1)
        #expect(denied.memSortKey == 0)
    }

    @Test func sortKeysPassThroughRealValues() {
        let live = ProcessInfoRow(pid: 6, name: "y", cpuPercent: 3.5, memoryBytes: 100)
        #expect(live.cpuSortKey == 3.5)
        #expect(live.memSortKey == 100)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' test`
Expected: FAIL — `cannot find 'ProcessInfoRow' in scope`.

- [ ] **Step 3: Write the implementation**

Create `macOSmonitor/ProcessInfoRow.swift`:

```swift
import Darwin

/// One row of the process table. `cpuPercent`/`memoryBytes` are optional so a
/// denied (EPERM) or not-yet-baselined process is represented truthfully
/// rather than with a fake zero.
struct ProcessInfoRow: Identifiable, Hashable, Sendable {
    let pid: pid_t
    let name: String
    var cpuPercent: Double?
    var memoryBytes: UInt64?

    var id: pid_t { pid }

    /// Non-optional keys so `Table` columns can sort; missing detail sinks to the bottom.
    var cpuSortKey: Double { cpuPercent ?? -1 }
    var memSortKey: UInt64 { memoryBytes ?? 0 }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' test`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add macOSmonitor/ProcessInfoRow.swift macOSmonitorTests/ProcessInfoRowTests.swift
git commit -m "feat: add ProcessInfoRow model with sortable keys"
```

---

### Task 4: `ProcessSampler` — the CPU-diffing engine

**Files:**
- Create: `macOSmonitor/ProcessSampler.swift`
- Test: `macOSmonitorTests/ProcessSamplerTests.swift`

**Interfaces:**
- Consumes: `ProcInfoProviding`, `ProcTaskSample` (Task 2); `ProcessInfoRow` (Task 3).
- Produces:
  - `protocol ProcessSampling: Sendable { func sample() async -> [ProcessInfoRow] }`
  - `actor ProcessSampler: ProcessSampling` with `init(source: any ProcInfoProviding = ProcInfo(), now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds })`. The injectable `now` (wall clock, nanoseconds) makes CPU% deterministically testable.
  - CPU% formula: `100 * Δ(cpuTimeNanos) / Δ(wall nanos)`; `nil` on the first tick (no baseline) and for denied processes.

- [ ] **Step 1: Write the failing test**

Create `macOSmonitorTests/ProcessSamplerTests.swift`:

```swift
import Testing
import Darwin
@testable import macOSmonitor

/// Scriptable stand-in for ProcInfo. Mutate `results` between `sample()` calls
/// to simulate successive ticks.
final class FakeProcInfo: ProcInfoProviding, @unchecked Sendable {
    var pids: [pid_t] = []
    var names: [pid_t: String] = [:]
    var results: [pid_t: ProcTaskSample] = [:]
    func listPIDs() -> [pid_t] { pids }
    func sample(pid: pid_t) -> ProcTaskSample? { results[pid] }
    func name(pid: pid_t) -> String { names[pid] ?? "(pid \(pid))" }
}

struct ProcessSamplerTests {
    @Test func firstTickHasNoCPUBaseline() async {
        let fake = FakeProcInfo()
        fake.pids = [42]; fake.names = [42: "worker"]
        fake.results = [42: ProcTaskSample(residentBytes: 1000, cpuTimeNanos: 0)]
        let sampler = ProcessSampler(source: fake, now: { 0 })

        let rows = await sampler.sample()
        #expect(rows.count == 1)
        #expect(rows.first?.cpuPercent == nil)
        #expect(rows.first?.memoryBytes == 1000)
    }

    @Test func cpuPercentIsDeltaOverWallTime() async {
        let fake = FakeProcInfo()
        fake.pids = [42]; fake.names = [42: "worker"]
        var clock: UInt64 = 0
        let sampler = ProcessSampler(source: fake, now: { clock })

        fake.results = [42: ProcTaskSample(residentBytes: 1000, cpuTimeNanos: 0)]
        _ = await sampler.sample()                       // establish baseline at t=0

        clock = 1_000_000_000                            // +1.0s wall
        fake.results = [42: ProcTaskSample(residentBytes: 1000, cpuTimeNanos: 500_000_000)] // +0.5s CPU
        let rows = await sampler.sample()

        #expect(rows.first?.cpuPercent == 50.0)
    }

    @Test func deniedProcessYieldsNamePidOnly() async {
        let fake = FakeProcInfo()
        fake.pids = [7]; fake.names = [7: "root-proc"]
        fake.results = [:]                               // sample() returns nil → EPERM path
        let sampler = ProcessSampler(source: fake, now: { 0 })

        let rows = await sampler.sample()
        #expect(rows.first?.name == "root-proc")
        #expect(rows.first?.cpuPercent == nil)
        #expect(rows.first?.memoryBytes == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' test`
Expected: FAIL — `cannot find 'ProcessSampler' in scope`.

- [ ] **Step 3: Write the implementation**

Create `macOSmonitor/ProcessSampler.swift`:

```swift
import Darwin
import Foundation

protocol ProcessSampling: Sendable {
    func sample() async -> [ProcessInfoRow]
}

/// Enumerates processes and computes CPU% by diffing each process's cumulative
/// CPU time against the previous tick. Runs off the main thread (plain actor).
actor ProcessSampler: ProcessSampling {
    private let source: any ProcInfoProviding
    private let now: @Sendable () -> UInt64
    private var previousCPU: [pid_t: UInt64] = [:]   // pid -> cpuTimeNanos last tick
    private var lastWallNanos: UInt64?

    init(source: any ProcInfoProviding = ProcInfo(),
         now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.source = source
        self.now = now
    }

    func sample() -> [ProcessInfoRow] {
        let wall = now()
        let wallDelta = lastWallNanos.map { wall &- $0 } ?? 0

        var rows: [ProcessInfoRow] = []
        var currentCPU: [pid_t: UInt64] = [:]

        for pid in source.listPIDs() {
            let name = source.name(pid: pid)
            guard let s = source.sample(pid: pid) else {
                // Denied (EPERM) or vanished: name + pid only (Decision A).
                rows.append(ProcessInfoRow(pid: pid, name: name, cpuPercent: nil, memoryBytes: nil))
                continue
            }
            currentCPU[pid] = s.cpuTimeNanos

            var cpuPercent: Double? = nil
            if let prev = previousCPU[pid], wallDelta > 0 {
                let cpuDelta = s.cpuTimeNanos >= prev ? s.cpuTimeNanos - prev : 0
                cpuPercent = 100.0 * Double(cpuDelta) / Double(wallDelta)
            }
            rows.append(ProcessInfoRow(pid: pid, name: name,
                                       cpuPercent: cpuPercent, memoryBytes: s.residentBytes))
        }

        previousCPU = currentCPU
        lastWallNanos = wall
        return rows
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' test`
Expected: `** TEST SUCCEEDED **` — all three sampler tests pass.

- [ ] **Step 5: Commit**

```bash
git add macOSmonitor/ProcessSampler.swift macOSmonitorTests/ProcessSamplerTests.swift
git commit -m "feat: add ProcessSampler actor with delta-based CPU%"
```

---

### Task 5: `ProcessListModel` — the observable refresh loop

**Files:**
- Create: `macOSmonitor/ProcessListModel.swift`
- Test: `macOSmonitorTests/ProcessListModelTests.swift`

**Interfaces:**
- Consumes: `ProcessSampling`, `ProcessInfoRow` (Task 4/3).
- Produces: `@MainActor @Observable final class ProcessListModel` with `private(set) var rows: [ProcessInfoRow]`, `init(sampler: any ProcessSampling = ProcessSampler(), interval: Duration = .seconds(1))`, `func refreshOnce() async` (one sample → assign), and `func run() async` (loop until `Task.isCancelled`, sleeping `interval` between ticks).

- [ ] **Step 1: Write the failing test**

Create `macOSmonitorTests/ProcessListModelTests.swift`:

```swift
import Testing
@testable import macOSmonitor

final class FakeSampler: ProcessSampling, @unchecked Sendable {
    var next: [ProcessInfoRow] = []
    private(set) var callCount = 0
    func sample() async -> [ProcessInfoRow] { callCount += 1; return next }
}

@MainActor
struct ProcessListModelTests {
    @Test func refreshOnceReplacesRowsFromSampler() async {
        let fake = FakeSampler()
        fake.next = [ProcessInfoRow(pid: 1, name: "a", cpuPercent: 12, memoryBytes: 2048)]
        let model = ProcessListModel(sampler: fake)

        #expect(model.rows.isEmpty)
        await model.refreshOnce()

        #expect(fake.callCount == 1)
        #expect(model.rows.count == 1)
        #expect(model.rows.first?.name == "a")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' test`
Expected: FAIL — `cannot find 'ProcessListModel' in scope`.

- [ ] **Step 3: Write the implementation**

Create `macOSmonitor/ProcessListModel.swift`:

```swift
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' test`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add macOSmonitor/ProcessListModel.swift macOSmonitorTests/ProcessListModelTests.swift
git commit -m "feat: add ProcessListModel observable refresh loop"
```

---

### Task 6: `ContentView` — the live sortable Table (and manual verification)

**Files:**
- Modify: `macOSmonitor/ContentView.swift` (replace the generated placeholder entirely)

**Interfaces:**
- Consumes: `ProcessListModel` (Task 5), `ProcessInfoRow` (Task 3).
- Produces: the app UI. No unit test (SwiftUI view); validated by build + manual side-by-side against Activity Monitor.

- [ ] **Step 1: Replace ContentView with the process table**

Overwrite `macOSmonitor/ContentView.swift`:

```swift
import SwiftUI

struct ContentView: View {
    @State private var model = ProcessListModel()
    @State private var sortOrder = [KeyPathComparator(\ProcessInfoRow.cpuSortKey, order: .reverse)]

    var body: some View {
        Table(model.rows.sorted(using: sortOrder), sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name)
            TableColumn("PID", value: \.pid) { row in
                Text(String(row.pid))
            }
            TableColumn("CPU %", value: \.cpuSortKey) { row in
                Text(row.cpuPercent.map { String(format: "%.1f", $0) } ?? "—")
                    .monospacedDigit()
            }
            TableColumn("Memory", value: \.memSortKey) { row in
                Text(row.memoryBytes.map {
                    ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory)
                } ?? "—")
                .monospacedDigit()
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .navigationTitle("macOSmonitor")
        .task { await model.run() }   // SwiftUI cancels this loop when the view goes away
    }
}

#Preview {
    ContentView()
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Run the full test suite (nothing regressed)**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' test`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Manual verification against Activity Monitor**

Launch the app (from Xcode's Run button, or open the built `.app`). Open **Activity Monitor** beside it. Verify:
- The table populates within ~1–2 seconds and refreshes continuously.
- Clicking each column header sorts by it; clicking again reverses; denied (root/other-user) rows show "—" for CPU/Memory and sort to the bottom of CPU.
- Your own busy processes' CPU% and Memory **track Activity Monitor's figures** (same ballpark, moving together). A brief CPU burner like `yes > /dev/null` in Terminal should appear near ~100% in both.
- **If CPU% is off by a large constant factor** (e.g. ~42×), the Mach-tick→nanosecond conversion in `ProcInfo.sample` regressed — revisit Task 2. (This should not happen; it is the one subtle correctness risk.)

- [ ] **Step 5: Commit**

```bash
git add macOSmonitor/ContentView.swift
git commit -m "feat: live sortable process Table wired to ProcessListModel"
```

---

## Definition of Done (Milestone 1)

- App launches to a live, ~1 Hz process table with Name / PID / CPU% / Memory.
- All four columns sort; denied processes show name+PID with "—" detail and sink on CPU sort.
- CPU% and memory visibly track Activity Monitor.
- All unit tests pass via `xcodebuild ... test`.
- Each task committed separately.
