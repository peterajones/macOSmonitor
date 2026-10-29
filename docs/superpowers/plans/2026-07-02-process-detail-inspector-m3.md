# Process Detail Inspector (Milestone 3) Implementation Plan

**Status:** FOLDED into TODO.md

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a live-updating right-side inspector showing the selected process's path, PPID, start time, thread count, user, and status.

**Architecture:** A new `ProcessDetails` value + `ProcessDetailProviding` protocol implemented by `ProcInfo` (one `PROC_PIDTASKALLINFO` call + `proc_pidpath` + `getpwuid`); `ProcessListModel` gains `selectedPID`/`selectedDetails` and refreshes details each ~1 Hz tick; `ContentView` binds selection to the model and hosts a `.inspector` rendering a new `ProcessDetailView`.

**Tech Stack:** Swift, SwiftUI (`.inspector`, `Form`, `LabeledContent`, `ContentUnavailableView`), `libproc`/`getpwuid` via Darwin, Swift Testing, Xcode 26 (`xcodebuild`).

## Global Constraints

- **Platform / project:** existing `macOSmonitor` macOS app, non-sandboxed, `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated`. Test import: `@testable import macOSmonitor`.
- **No bridging header:** `proc_pidinfo`, `proc_taskallinfo`, `proc_pidpath`, `getpwuid`, `MAXPATHLEN` resolve via `import Darwin` (+ `import Foundation` for `Date`).
- **Gotcha:** `PROC_PIDPATHINFO_MAXSIZE` is NOT Swift-visible ("structure not supported"). Use `4 * Int(MAXPATHLEN)` (= 4096) for the path buffer. (Verified.)
- **`proc_taskallinfo`:** `.pbsd` (`proc_bsdinfo`) gives `pbi_ppid` (UInt32), `pbi_uid` (uid_t), `pbi_status` (UInt32), `pbi_start_tvsec` (UInt64); `.ptinfo` (`proc_taskinfo`) gives `pti_threadnum` (Int32). Call returns full struct size on success, less on EPERM/exit. (Verified.)
- **Status mapping** (by raw `pbi_status`): 1→Idle, 2→Running, 3→Sleeping, 4→Stopped, 5→Zombie, else Unknown. (Raw BSD constants avoided for Swift-visibility safety.)
- **Build:** `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' build`
- **Test:** `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test` (MUST scope to `macOSmonitorTests`; the UI-test target times out under CLI).
- **File placement:** app sources under `macOSmonitor/`, tests under `macOSmonitorTests/` (synchronized groups auto-include new files).

---

### Task 1: `ProcessDetails` + `ProcInfo.details(pid:)`

**Files:**
- Create: `macOSmonitor/ProcessDetails.swift`
- Test: `macOSmonitorTests/ProcessDetailsTests.swift`

**Interfaces:**
- Consumes: `ProcInfo` (existing).
- Produces:
  - `struct ProcessDetails: Equatable, Sendable { let path: String?; let parentPID: pid_t; let startDate: Date; let threadCount: Int; let user: String; let status: String }`
  - `protocol ProcessDetailProviding: Sendable { func details(pid: pid_t) -> ProcessDetails? }`
  - `extension ProcInfo: ProcessDetailProviding` — real impl; `nil` on EPERM/exit.

- [ ] **Step 1: Write the failing test**

Create `macOSmonitorTests/ProcessDetailsTests.swift`:

```swift
import Testing
import Darwin
@testable import macOSmonitor

struct ProcessDetailsTests {
    let sut = ProcInfo()

    @Test func detailsForSelfAreSane() {
        let details = sut.details(pid: getpid())
        #expect(details != nil)
        #expect((details?.threadCount ?? 0) >= 1)
        #expect((details?.parentPID ?? 0) > 0)
        #expect(details?.path?.isEmpty == false)
    }

    @Test func userMatchesCurrentUser() {
        let expected = getpwuid(getuid()).flatMap { $0.pointee.pw_name }.map { String(cString: $0) }
        #expect(sut.details(pid: getpid())?.user == expected)
    }

    // Root-owned processes deny PROC_PIDTASKALLINFO to a normal user; skipped under root.
    @Test(.enabled(if: getuid() != 0))
    func deniedProcessHasNoDetails() {
        #expect(sut.details(pid: 1) == nil)   // pid 1 = launchd
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests build-for-testing 2>&1 | grep -iE 'error:|cannot find'`
Expected: FAIL — `value of type 'ProcInfo' has no member 'details'` (and `cannot find type 'ProcessDetails'`).

- [ ] **Step 3: Write the implementation**

Create `macOSmonitor/ProcessDetails.swift`:

```swift
import Darwin
import Foundation

/// Static-ish detail about one process, shown in the inspector.
struct ProcessDetails: Equatable, Sendable {
    let path: String?
    let parentPID: pid_t
    let startDate: Date
    let threadCount: Int
    let user: String
    let status: String
}

/// Fetches per-process detail. Implemented by `ProcInfo`; behind a protocol so the
/// model can be tested with a fake.
protocol ProcessDetailProviding: Sendable {
    func details(pid: pid_t) -> ProcessDetails?
}

extension ProcInfo: ProcessDetailProviding {
    func details(pid: pid_t) -> ProcessDetails? {
        var info = proc_taskallinfo()
        let size = Int32(MemoryLayout<proc_taskallinfo>.size)
        // One call yields BSD info (.pbsd) + task info (.ptinfo). Short return = EPERM/exit.
        guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, size) == size else { return nil }
        let bsd = info.pbsd
        let task = info.ptinfo

        // PROC_PIDPATHINFO_MAXSIZE isn't Swift-visible; it's 4 * MAXPATHLEN.
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path = pathLength > 0 ? String(cString: pathBuffer) : nil

        return ProcessDetails(
            path: path,
            parentPID: pid_t(bsd.pbi_ppid),
            startDate: Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec)),
            threadCount: Int(task.pti_threadnum),
            user: Self.username(forUID: bsd.pbi_uid),
            status: Self.statusName(bsd.pbi_status)
        )
    }

    private static func username(forUID uid: uid_t) -> String {
        if let pw = getpwuid(uid), let name = pw.pointee.pw_name {
            return String(cString: name)
        }
        return "uid \(uid)"
    }

    private static func statusName(_ status: UInt32) -> String {
        switch status {
        case 1: return "Idle"
        case 2: return "Running"
        case 3: return "Sleeping"
        case 4: return "Stopped"
        case 5: return "Zombie"
        default: return "Unknown"
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test 2>&1 | grep -iE 'ProcessDetails.*(passed|failed)|TEST (SUCCEEDED|FAILED)'`
Expected: `** TEST SUCCEEDED **`, all `ProcessDetailsTests` pass.

- [ ] **Step 5: Commit**

```bash
git add macOSmonitor/ProcessDetails.swift macOSmonitorTests/ProcessDetailsTests.swift
git commit -m "feat: add ProcessDetails and ProcInfo.details(pid:) via PROC_PIDTASKALLINFO"
```

---

### Task 2: `ProcessListModel` — selection + live details

**Files:**
- Modify: `macOSmonitor/ProcessListModel.swift`
- Test: `macOSmonitorTests/ProcessListModelTests.swift` (add a fake + case)

**Interfaces:**
- Consumes: `ProcessDetails`, `ProcessDetailProviding` (Task 1).
- Produces:
  - `var selectedPID: pid_t?` and `private(set) var selectedDetails: ProcessDetails?` on `ProcessListModel`.
  - `init(sampler:terminator:detailProvider:interval:)` now takes `detailProvider: any ProcessDetailProviding = ProcInfo()`.
  - `func refreshDetails()` — sets `selectedDetails` from `selectedPID`.
  - `refreshOnce()` calls `refreshDetails()` after assigning rows.

- [ ] **Step 1: Add the failing test**

In `macOSmonitorTests/ProcessListModelTests.swift`, add this fake at file scope (after `FakeTerminator`):

```swift
final class FakeDetailProvider: ProcessDetailProviding, @unchecked Sendable {
    var result: ProcessDetails?
    private(set) var lastPID: pid_t?
    func details(pid: pid_t) -> ProcessDetails? { lastPID = pid; return result }
}
```

And add inside `struct ProcessListModelTests`:

```swift
    @Test func refreshDetailsPublishesForSelectedPID() {
        let detail = ProcessDetails(path: "/bin/x", parentPID: 1,
                                    startDate: Date(timeIntervalSince1970: 0),
                                    threadCount: 3, user: "me", status: "Running")
        let fake = FakeDetailProvider()
        fake.result = detail
        let model = ProcessListModel(sampler: FakeSampler(), detailProvider: fake)

        model.selectedPID = 55
        model.refreshDetails()
        #expect(fake.lastPID == 55)
        #expect(model.selectedDetails == detail)

        model.selectedPID = nil
        model.refreshDetails()
        #expect(model.selectedDetails == nil)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests build-for-testing 2>&1 | grep -iE 'error:'`
Expected: FAIL — extra argument `detailProvider` / no member `selectedPID` / `refreshDetails` / `selectedDetails`.

- [ ] **Step 3: Update the model**

Replace the full contents of `macOSmonitor/ProcessListModel.swift`:

```swift
import Foundation
import Observation

@MainActor
@Observable
final class ProcessListModel {
    private(set) var rows: [ProcessInfoRow] = []

    /// Currently selected process (single source of truth, bound to the table).
    var selectedPID: pid_t?
    /// Detail for the selected process; nil when nothing selected or access is denied.
    private(set) var selectedDetails: ProcessDetails?

    private let sampler: any ProcessSampling
    private let terminator: any ProcessTerminating
    private let detailProvider: any ProcessDetailProviding
    private let interval: Duration

    init(sampler: any ProcessSampling = ProcessSampler(),
         terminator: any ProcessTerminating = ProcessTerminator(),
         detailProvider: any ProcessDetailProviding = ProcInfo(),
         interval: Duration = .seconds(1)) {
        self.sampler = sampler
        self.terminator = terminator
        self.detailProvider = detailProvider
        self.interval = interval
    }

    /// One sample → publish rows, then refresh the selected process's details (live cadence).
    func refreshOnce() async {
        rows = await sampler.sample()
        refreshDetails()
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

    /// Refresh `selectedDetails` for the current `selectedPID` (nil if none/denied).
    func refreshDetails() {
        selectedDetails = selectedPID.flatMap { detailProvider.details(pid: $0) }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test 2>&1 | grep -iE 'refreshDetails.*(passed|failed)|TEST (SUCCEEDED|FAILED)'`
Expected: `** TEST SUCCEEDED **`, including `refreshDetailsPublishesForSelectedPID`. Existing model tests still pass.

- [ ] **Step 5: Commit**

```bash
git add macOSmonitor/ProcessListModel.swift macOSmonitorTests/ProcessListModelTests.swift
git commit -m "feat: add selection + live detail refresh to ProcessListModel"
```

---

### Task 3: `ProcessDetailView` + inspector wiring in `ContentView`

**Files:**
- Create: `macOSmonitor/ProcessDetailView.swift`
- Modify: `macOSmonitor/ContentView.swift` (replace entirely)

**Interfaces:**
- Consumes: `ProcessListModel` (`selectedPID`, `selectedDetails`, `refreshDetails`), `ProcessInfoRow`, `ProcessDetails` (Tasks 1–2).
- Produces: the M3 UI. No unit test (SwiftUI views); validated by build + manual inspection.

- [ ] **Step 1: Create the detail view**

Create `macOSmonitor/ProcessDetailView.swift`:

```swift
import SwiftUI

/// Inspector content: renders three states — no selection, denied, or full detail.
struct ProcessDetailView: View {
    let row: ProcessInfoRow?
    let details: ProcessDetails?

    var body: some View {
        if let row {
            Form {
                Section("Process") {
                    LabeledContent("Name", value: row.name)
                    LabeledContent("PID", value: String(row.pid))
                    LabeledContent("CPU %", value: row.cpuPercent.map { String(format: "%.1f", $0) } ?? "—")
                    LabeledContent("Memory", value: row.memoryBytes.map {
                        ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory)
                    } ?? "—")
                }
                if let details {
                    Section("Details") {
                        LabeledContent("User", value: details.user)
                        LabeledContent("Status", value: details.status)
                        LabeledContent("Parent PID", value: String(details.parentPID))
                        LabeledContent("Threads", value: String(details.threadCount))
                        LabeledContent("Started",
                                       value: details.startDate.formatted(date: .abbreviated, time: .standard))
                        LabeledContent("Path", value: details.path ?? "—")
                    }
                } else {
                    Section {
                        Text("Details unavailable (permission denied).")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("No Selection", systemImage: "cpu",
                                   description: Text("Select a process to see details."))
        }
    }
}
```

- [ ] **Step 2: Rewrite ContentView to bind selection + host the inspector**

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
    @State private var showInspector = true
    @State private var pendingTermination: PendingTermination?
    @State private var errorMessage: String?

    var body: some View {
        @Bindable var model = model   // enables $model.selectedPID binding

        Table(model.rows.sorted(using: sortOrder), selection: $model.selectedPID, sortOrder: $sortOrder) {
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
            ToolbarItem {
                Button { showInspector.toggle() } label: {
                    Label("Toggle Inspector", systemImage: "sidebar.trailing")
                }
            }
        }
        .frame(minWidth: 720, minHeight: 400)
        .navigationTitle("macOSmonitor")
        .task { await model.run() }
        .onChange(of: model.selectedPID) { model.refreshDetails() }
        .inspector(isPresented: $showInspector) {
            ProcessDetailView(row: selectedRow, details: model.selectedDetails)
                .inspectorColumnWidth(min: 240, ideal: 300, max: 420)
        }
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
        guard let pid = model.selectedPID else { return nil }
        return model.rows.first { $0.id == pid }
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
            break
        case .denied:
            errorMessage = "Couldn’t terminate “\(item.name)”: permission denied."
        case .noSuchProcess:
            errorMessage = "“\(item.name)” is no longer running."
        case .failure(let reason):
            errorMessage = "Couldn’t terminate “\(item.name)”: \(reason)."
        }
    }

    /// Bridges an optional-state binding to the Bool binding dialogs/alerts want.
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

- [ ] **Step 3: Build**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' build 2>&1 | grep -iE 'error:|BUILD (SUCCEEDED|FAILED)'`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run the full unit suite (nothing regressed)**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test 2>&1 | grep -E 'TEST (SUCCEEDED|FAILED)'`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Manual verification**

Launch the app (inspector shows on the right by default). Verify:
- Selecting a process fills the inspector: Name/PID/CPU/Memory, then User, Status, Parent PID, Threads, Started, Path. Cross-check a couple against `ps -p <pid> -o ppid,user,lstart,nthr` or Activity Monitor's inspector.
- Thread count / Status update live (~1 s) while a busy app stays selected.
- Selecting a "—" row (e.g. root-owned `launchd`) shows "Details unavailable (permission denied)."
- Deselecting (⌘-click the selected row) shows the "No Selection" placeholder.
- The toolbar inspector button hides/shows the panel.
- Quit / Force Quit still work on the selected process (M2 regression check).

- [ ] **Step 6: Commit**

```bash
git add macOSmonitor/ProcessDetailView.swift macOSmonitor/ContentView.swift
git commit -m "feat: live process detail inspector bound to selection"
```

---

## Definition of Done (Milestone 3)

- The inspector shows the selected process's path, PPID, start time, thread count, user, and status, plus the echoed Name/PID/CPU/Memory.
- Details update live while a process is selected.
- Denied ("—") and no-selection states render their placeholders; nothing crashes.
- The inspector toggles from the toolbar and is shown by default.
- Quit/Force Quit still function (selection now sourced from the model).
- All unit tests pass via `xcodebuild ... -only-testing:macOSmonitorTests test`.
- Each task committed separately.
