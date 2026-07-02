# Process Termination (Milestone 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user Quit (SIGTERM) or Force Quit (SIGKILL) a selected process from a context menu and toolbar, each guarded by a confirmation dialog, with un-killable rows disabled and failures shown as alerts.

**Architecture:** One new syscall-isolating unit `ProcessTerminator` (wraps `kill()` behind a testable protocol, mirroring `ProcInfo`), a `canTerminate` flag on `ProcessInfoRow`, a `terminate(pid:force:)` method on `ProcessListModel`, and selection + menu/toolbar + dialog/alert wiring in `ContentView`.

**Tech Stack:** Swift, SwiftUI (`Table` selection, `.contextMenu(forSelectionType:)`, `.toolbar`, `.confirmationDialog`, `.alert`), `kill()` via Darwin, Swift Testing, Xcode 26 (`xcodebuild`).

## Global Constraints

- **Platform / project:** existing `macOSmonitor` macOS app, non-sandboxed, `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated`. Module/test import: `@testable import macOSmonitor`.
- **No bridging header:** `kill`, `SIGTERM`, `SIGKILL`, `EPERM`, `ESRCH`, `errno`, `strerror` resolve via `import Darwin` (+ `import Foundation` for `Process`). Verified.
- **Build:** `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' build`
- **Test:** `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test` (MUST scope to `macOSmonitorTests`; the UI-test target times out under CLI).
- **File placement:** app sources under `macOSmonitor/`, tests under `macOSmonitorTests/` (file-system-synchronized groups auto-include new files).
- **Ownership rule:** the user can only signal their own processes; `canTerminate = memoryBytes != nil` (readable ⟹ ownable ⟹ signalable). Still handle `kill()` errors for the display-vs-click race.
- **Signals:** Quit = `SIGTERM`, Force Quit = `SIGKILL`. Confirm both.

---

### Task 1: `ProcessTerminator` — the isolated `kill()` shim

**Files:**
- Create: `macOSmonitor/ProcessTerminator.swift`
- Test: `macOSmonitorTests/ProcessTerminatorTests.swift`

**Interfaces:**
- Produces:
  - `enum TerminationResult: Equatable, Sendable { case success; case denied; case noSuchProcess; case failure(String) }`
  - `protocol ProcessTerminating: Sendable { func terminate(pid: pid_t, force: Bool) -> TerminationResult }`
  - `struct ProcessTerminator: ProcessTerminating` — real impl calling `kill(pid, force ? SIGKILL : SIGTERM)`.

- [ ] **Step 1: Write the failing test**

Create `macOSmonitorTests/ProcessTerminatorTests.swift`:

```swift
import Testing
import Darwin
import Foundation
@testable import macOSmonitor

struct ProcessTerminatorTests {
    let sut = ProcessTerminator()

    @Test func terminatesAChildProcessWithSIGTERM() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["60"]
        try proc.run()
        let pid = pid_t(proc.processIdentifier)

        let result = sut.terminate(pid: pid, force: false)
        #expect(result == .success)

        proc.waitUntilExit()          // reap the child; returns promptly after SIGTERM
        #expect(proc.isRunning == false)
    }

    // Only meaningful as a non-root user; skipped under root so we never signal launchd as root.
    @Test(.enabled(if: getuid() != 0))
    func deniedForRootOwnedProcess() {
        #expect(sut.terminate(pid: 1, force: false) == .denied)   // pid 1 = launchd
    }

    @Test func noSuchProcessForReapedChild() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["0"]
        try proc.run()
        let pid = pid_t(proc.processIdentifier)
        proc.waitUntilExit()          // child exits and is reaped; pid is now gone

        #expect(sut.terminate(pid: pid, force: false) == .noSuchProcess)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests build-for-testing 2>&1 | grep -iE 'error:|cannot find'`
Expected: FAIL — `cannot find 'ProcessTerminator' in scope`.

- [ ] **Step 3: Write the implementation**

Create `macOSmonitor/ProcessTerminator.swift`:

```swift
import Darwin

/// Result of attempting to terminate a process.
enum TerminationResult: Equatable, Sendable {
    case success
    case denied          // EPERM — not our process
    case noSuchProcess   // ESRCH — already gone
    case failure(String) // any other errno, human-readable
}

/// Isolates the `kill()` syscall behind a protocol so the model can be tested with a fake.
protocol ProcessTerminating: Sendable {
    func terminate(pid: pid_t, force: Bool) -> TerminationResult
}

struct ProcessTerminator: ProcessTerminating {
    func terminate(pid: pid_t, force: Bool) -> TerminationResult {
        let signal = force ? SIGKILL : SIGTERM
        if kill(pid, signal) == 0 { return .success }
        switch errno {
        case EPERM: return .denied
        case ESRCH: return .noSuchProcess
        default:    return .failure(String(cString: strerror(errno)))
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test 2>&1 | grep -iE 'ProcessTerminator.*(passed|failed)|TEST (SUCCEEDED|FAILED)'`
Expected: `** TEST SUCCEEDED **`, all `ProcessTerminatorTests` pass.

- [ ] **Step 5: Commit**

```bash
git add macOSmonitor/ProcessTerminator.swift macOSmonitorTests/ProcessTerminatorTests.swift
git commit -m "feat: add ProcessTerminator kill() shim with errno mapping"
```

---

### Task 2: `canTerminate` on `ProcessInfoRow`

**Files:**
- Modify: `macOSmonitor/ProcessInfoRow.swift`
- Test: `macOSmonitorTests/ProcessInfoRowTests.swift` (add cases)

**Interfaces:**
- Produces: `var canTerminate: Bool { memoryBytes != nil }` on `ProcessInfoRow`.

- [ ] **Step 1: Add the failing tests**

Append to `macOSmonitorTests/ProcessInfoRowTests.swift` (inside `struct ProcessInfoRowTests`):

```swift
    @Test func ownedRowCanTerminate() {
        let owned = ProcessInfoRow(pid: 1, name: "mine", cpuPercent: nil, memoryBytes: 4096)
        #expect(owned.canTerminate == true)
    }

    @Test func deniedRowCannotTerminate() {
        let denied = ProcessInfoRow(pid: 2, name: "theirs", cpuPercent: nil, memoryBytes: nil)
        #expect(denied.canTerminate == false)
    }
```

Note: `ownedRowCanTerminate` uses `memoryBytes: 4096` with `cpuPercent: nil` deliberately — a just-baselined process we own (memory known, CPU% not yet) must still be terminable.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests build-for-testing 2>&1 | grep -iE 'error:|canTerminate'`
Expected: FAIL — `value of type 'ProcessInfoRow' has no member 'canTerminate'`.

- [ ] **Step 3: Add the property**

In `macOSmonitor/ProcessInfoRow.swift`, add below `memSortKey`:

```swift
    /// True when we could read this process's task info, which under the same euid
    /// ownership check means we can also signal it. Drives enabling of Quit/Force Quit.
    var canTerminate: Bool { memoryBytes != nil }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test 2>&1 | grep -iE 'ProcessInfoRow.*(passed|failed)|TEST (SUCCEEDED|FAILED)'`
Expected: `** TEST SUCCEEDED **`, both new cases pass.

- [ ] **Step 5: Commit**

```bash
git add macOSmonitor/ProcessInfoRow.swift macOSmonitorTests/ProcessInfoRowTests.swift
git commit -m "feat: add canTerminate ownership flag to ProcessInfoRow"
```

---

### Task 3: `terminate(pid:force:)` on `ProcessListModel`

**Files:**
- Modify: `macOSmonitor/ProcessListModel.swift`
- Test: `macOSmonitorTests/ProcessListModelTests.swift` (add a fake + case)

**Interfaces:**
- Consumes: `ProcessTerminating`, `TerminationResult` (Task 1).
- Produces:
  - `ProcessListModel.init(sampler:terminator:interval:)` now takes `terminator: any ProcessTerminating = ProcessTerminator()`.
  - `func terminate(pid: pid_t, force: Bool) -> TerminationResult` delegating to the terminator.

- [ ] **Step 1: Add the failing test**

Append to `macOSmonitorTests/ProcessListModelTests.swift` (after the existing `FakeSampler`, at file scope):

```swift
final class FakeTerminator: ProcessTerminating, @unchecked Sendable {
    private(set) var lastPID: pid_t?
    private(set) var lastForce: Bool?
    var result: TerminationResult = .success
    func terminate(pid: pid_t, force: Bool) -> TerminationResult {
        lastPID = pid; lastForce = force; return result
    }
}
```

And add inside `struct ProcessListModelTests`:

```swift
    @Test func terminateForwardsSignalChoiceAndReturnsResult() async {
        let fake = FakeTerminator()
        fake.result = .denied
        let model = ProcessListModel(sampler: FakeSampler(), terminator: fake)

        let result = model.terminate(pid: 4321, force: true)

        #expect(fake.lastPID == 4321)
        #expect(fake.lastForce == true)
        #expect(result == .denied)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests build-for-testing 2>&1 | grep -iE 'error:|terminator|terminate'`
Expected: FAIL — extra argument `terminator` in call / no member `terminate`.

- [ ] **Step 3: Update the model**

In `macOSmonitor/ProcessListModel.swift`, replace the stored properties + init and add the method. The full updated file:

```swift
import Foundation
import Observation

@MainActor
@Observable
final class ProcessListModel {
    private(set) var rows: [ProcessInfoRow] = []

    private let sampler: any ProcessSampling
    private let terminator: any ProcessTerminating
    private let interval: Duration

    init(sampler: any ProcessSampling = ProcessSampler(),
         terminator: any ProcessTerminating = ProcessTerminator(),
         interval: Duration = .seconds(1)) {
        self.sampler = sampler
        self.terminator = terminator
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

    /// Send SIGTERM (force == false) or SIGKILL (force == true) to a process.
    func terminate(pid: pid_t, force: Bool) -> TerminationResult {
        terminator.terminate(pid: pid, force: force)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test 2>&1 | grep -iE 'ProcessListModel.*(passed|failed)|TEST (SUCCEEDED|FAILED)'`
Expected: `** TEST SUCCEEDED **`, including `terminateForwardsSignalChoiceAndReturnsResult`.

- [ ] **Step 5: Commit**

```bash
git add macOSmonitor/ProcessListModel.swift macOSmonitorTests/ProcessListModelTests.swift
git commit -m "feat: add terminate(pid:force:) to ProcessListModel"
```

---

### Task 4: `ContentView` — selection, menu/toolbar, confirmation, alert (+ manual verification)

**Files:**
- Modify: `macOSmonitor/ContentView.swift` (replace entirely)

**Interfaces:**
- Consumes: `ProcessListModel.terminate(pid:force:)`, `ProcessInfoRow.canTerminate`, `TerminationResult` (Tasks 1–3).
- Produces: the M2 UI. No unit test (SwiftUI view); validated by build + manual termination of a throwaway process.

- [ ] **Step 1: Replace ContentView**

Overwrite `macOSmonitor/ContentView.swift`:

```swift
//
//  ContentView.swift
//  macOSmonitor
//

import SwiftUI

struct ContentView: View {
    @State private var model = ProcessListModel()
    @State private var sortOrder = [KeyPathComparator(\ProcessInfoRow.cpuSortKey, order: .reverse)]
    @State private var selection: pid_t?
    @State private var pendingTermination: PendingTermination?
    @State private var errorMessage: String?

    var body: some View {
        Table(model.rows.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
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
        .contextMenu(forSelectionType: pid_t.self) { ids in
            let row = ids.first.flatMap { id in model.rows.first(where: { $0.id == id }) }
            Button("Quit") { requestTermination(row, force: false) }
                .disabled(row?.canTerminate != true)
            Button("Force Quit") { requestTermination(row, force: true) }
                .disabled(row?.canTerminate != true)
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Quit") { requestTermination(selectedRow, force: false) }
                    .disabled(selectedRow?.canTerminate != true)
                Button("Force Quit") { requestTermination(selectedRow, force: true) }
                    .disabled(selectedRow?.canTerminate != true)
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .navigationTitle("macOSmonitor")
        .task { await model.run() }
        .confirmationDialog(
            confirmTitle,
            isPresented: presenting($pendingTermination),
            presenting: pendingTermination
        ) { item in
            Button(item.force ? "Force Quit" : "Quit", role: .destructive) {
                performTermination(item)
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(item.force
                 ? "Force-quitting “\(item.name)” ends it immediately; unsaved work is lost."
                 : "“\(item.name)” (PID \(item.pid)) will be asked to quit.")
        }
        .alert(
            "Couldn’t terminate process",
            isPresented: presenting($errorMessage),
            presenting: errorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Selection helpers

    private var selectedRow: ProcessInfoRow? {
        guard let selection else { return nil }
        return model.rows.first { $0.id == selection }
    }

    private var confirmTitle: String {
        guard let item = pendingTermination else { return "" }
        return item.force ? "Force Quit “\(item.name)”?" : "Quit “\(item.name)”?"
    }

    // MARK: - Actions

    private func requestTermination(_ row: ProcessInfoRow?, force: Bool) {
        guard let row, row.canTerminate else { return }
        pendingTermination = PendingTermination(pid: row.pid, name: row.name, force: force)
    }

    private func performTermination(_ item: PendingTermination) {
        switch model.terminate(pid: item.pid, force: item.force) {
        case .success:
            break   // process drops off the next ~1 Hz refresh
        case .denied:
            errorMessage = "Couldn’t terminate “\(item.name)”: permission denied."
        case .noSuchProcess:
            errorMessage = "“\(item.name)” is no longer running."
        case .failure(let reason):
            errorMessage = "Couldn’t terminate “\(item.name)”: \(reason)."
        }
    }

    /// Bridges an optional-state binding to the Bool binding `.confirmationDialog`/`.alert` want:
    /// present when non-nil, clear the state when dismissed.
    private func presenting<T>(_ source: Binding<T?>) -> Binding<Bool> {
        Binding(
            get: { source.wrappedValue != nil },
            set: { shown in if !shown { source.wrappedValue = nil } }
        )
    }
}

/// A pending Quit/Force-Quit awaiting confirmation.
private struct PendingTermination: Identifiable {
    let id = UUID()
    let pid: pid_t
    let name: String
    let force: Bool
}

#Preview {
    ContentView()
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' build 2>&1 | grep -iE 'error:|BUILD (SUCCEEDED|FAILED)'`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Run the full unit suite (nothing regressed)**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test 2>&1 | grep -E 'TEST (SUCCEEDED|FAILED)'`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Manual verification**

Spawn a throwaway process, then terminate it from the app:

```bash
/bin/sleep 600 &        # note the printed PID; shows in the table as "sleep"
```

In the running app, verify:
- Selecting the `sleep` row enables the **Quit** and **Force Quit** toolbar buttons; right-clicking it shows the same two menu items.
- **Quit** → a confirmation dialog naming `sleep` (with PID) appears; confirming makes `sleep` disappear from the table within ~1–2 s. (Re-spawn and repeat with **Force Quit**.)
- Selecting a **"—" row** (e.g. `launchd`, root-owned) leaves both toolbar buttons **disabled**, and its context-menu items are disabled.
- Cancelling the confirmation dialog leaves the process running.
- (Optional) `kill -9` the spawned `sleep` from Terminal *after* opening the confirmation dialog but *before* confirming, then confirm → an **alert** reports it is no longer running.

- [ ] **Step 5: Commit**

```bash
git add macOSmonitor/ContentView.swift
git commit -m "feat: terminate selected process via menu/toolbar with confirmation"
```

---

## Definition of Done (Milestone 2)

- Selecting an owned process and choosing Quit or Force Quit (from toolbar or context menu) terminates it after a confirmation dialog; it disappears on the next refresh.
- Quit/Force Quit are disabled for processes shown with "—".
- `kill()` failures (denied / gone / other) surface as an alert.
- All unit tests pass via `xcodebuild ... -only-testing:macOSmonitorTests test`.
- Each task committed separately.
