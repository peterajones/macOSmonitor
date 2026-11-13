# Multi-select Termination Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Select several processes in the table and Quit / Force Quit / Send Signal to all of them with one confirmation.

**Architecture:** The table's selection becomes `Set<pid_t>` on `ProcessListModel`; `selectedPID` survives as a computed "exactly one" view of it, so the inspector and renice are untouched. A pure `ProcessBatch` turns a set of PIDs plus the rows currently shown into targets and a skipped count; the model sends a batch after re-checking each PID's name against the latest rows; a pure function turns outcomes into one message.

**Tech Stack:** Swift 6, SwiftUI `Table` multi-selection, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-13-multi-select-termination-design.md`

## Global Constraints

- Follow `CLAUDE.md`: never edit or `git add` `project.pbxproj` (new files join targets automatically); views read the model directly in `body`; Processes view state and the toolbar stay on `ContentView`; Swift Testing only.
- Before any test run, ask Peter to quit the app and wait until he says it's closed (`pgrep -x macOSmonitor` empty). Scope tests: `-only-testing:macOSmonitorTests`. Count with `grep -c "' passed on '"`.
- Mutation-check each new test group: delete or break the guarded line, see it fail, restore.
- Single selection must behave exactly as today, including dialog wording "Quit “name”?" and the existing single-process error strings.
- Do not commit per task. One commit for the feature after Peter's hand check, when he asks.

## Review Focus

1. **A selected PID that has exited** (in the selection, absent from rows) → not a target, not counted as skipped. Test in Task 2.
2. **A PID reused by a different program between confirm and send** → not signalled, reported "no longer running". Test in Task 3.
3. **Nothing actionable** (all hidden, all `canTerminate == false`) → actions disabled, no dialog opens. Test in Task 2 (`PendingTermination.request` returns nil).
4. **Selection grows from one to two rows** → the inspector's per-process state resets (Environment collapsed, nice draft cleared), since `selectedPID` goes 5 → nil. Test in Task 1.
5. **Resume on a batch** (no confirmation) → every target is sent SIGCONT, not just the first. Test in Task 3.

---

### Task 1: Selection becomes a set

**Files:**
- Modify: `macOSmonitor/ProcessListModel.swift:9-22, 163-169`
- Test: `macOSmonitorTests/ProcessListModelTests.swift`

**Interfaces:**
- Produces:
  - `var selectedPIDs: Set<pid_t>` — stored, the table's selection binding. Its `didSet` runs the existing reset rules (environment, open files, threads, nice draft, renice error) when the derived single PID changes.
  - `var selectedPID: pid_t?` — computed. Get: the sole element when `selectedPIDs.count == 1`, else nil. Set: `selectedPIDs = newValue.map { [$0] } ?? []`. Existing callers and tests keep using it.
  - `var selectedRows: [ProcessInfoRow]` — rows whose pid is in `selectedPIDs`, in `rows` order.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func selectedPIDIsTheSoleSelectionAndNilForSeveral() {
    let model = ProcessListModel(sampler: FakeSampler())
    model.selectedPIDs = [5]
    #expect(model.selectedPID == 5)
    model.selectedPIDs = [5, 6]
    #expect(model.selectedPID == nil)
    model.selectedPID = 7
    #expect(model.selectedPIDs == [7])
    model.selectedPID = nil
    #expect(model.selectedPIDs.isEmpty)
}

@Test func growingTheSelectionResetsInspectorState() {
    let model = ProcessListModel(sampler: FakeSampler())
    model.selectedPIDs = [5]
    model.isEnvironmentRevealed = true
    model.niceDraft = 4
    model.selectedPIDs = [5, 6]
    #expect(model.isEnvironmentRevealed == false)
    #expect(model.niceDraft == nil)
}

@Test func selectedRowsFollowRowOrder() async {
    let fake = FakeSampler()
    fake.next = [ProcessInfoRow(pid: 3, name: "c", cpuPercent: nil, memoryBytes: 1),
                 ProcessInfoRow(pid: 1, name: "a", cpuPercent: nil, memoryBytes: 1),
                 ProcessInfoRow(pid: 2, name: "b", cpuPercent: nil, memoryBytes: 1)]
    let model = ProcessListModel(sampler: fake)
    await model.refreshOnce()
    model.selectedPIDs = [2, 3, 99]
    #expect(model.selectedRows.map(\.pid) == [3, 2])
}
```

- [ ] **Step 2: Build tests; expect compile failure** (`selectedPIDs` / `selectedRows` don't exist).
- [ ] **Step 3: Implement** the three properties above. Existing tests in this file must pass unchanged.
- [ ] **Step 4: Run** `ProcessListModelTests` (after Peter quits the app). Expected: all pass. Mutation-check: make `selectedPID`'s getter return `selectedPIDs.first` → the first test fails.

### Task 2: ProcessBatch, PendingTermination and confirmation copy

**Files:**
- Create: `macOSmonitor/ProcessBatch.swift`
- Modify: `macOSmonitor/ProcessesView.swift:150-162` (`PendingTermination` moves to `ProcessBatch.swift` and is rewritten)
- Modify: `macOSmonitor/ProcessTerminator.swift` (batch confirmation copy on `ProcessSignal`)
- Test: `macOSmonitorTests/ProcessBatchTests.swift`

**Interfaces:**
- Produces:
  - `struct SignalTarget: Equatable, Hashable, Sendable { let pid: pid_t; let name: String }`
  - `struct ProcessBatch: Equatable, Sendable { let targets: [SignalTarget]; let skippedCount: Int }`
    - `static func make(pids: Set<pid_t>, visibleRows: [ProcessInfoRow], ownPID: pid_t = getpid()) -> ProcessBatch` — targets in `visibleRows` order.
    - `var groupedNames: String` — names with counts, most common first, ties by case-insensitive name: `"node ×5, npm"`; a name appearing once has no count.
  - `struct PendingTermination: Identifiable { let id = UUID(); let targets: [SignalTarget]; let skippedCount: Int; let signal: ProcessSignal }`
    - `static func request(for batch: ProcessBatch, signal: ProcessSignal) -> PendingTermination?` — nil when `batch.targets` is empty.
    - `var title: String`, `var message: String` — the dialog text.
  - On `ProcessSignal`: `func confirmTitle(count: Int) -> String` (`"Quit 6 processes?"`), `func confirmMessage(groupedNames: String, count: Int) -> String`, `static func skippedNote(_ count: Int) -> String`.

Rules for `make` (spec "Targets"):
- A pid not in `visibleRows` is ignored entirely (hidden or exited).
- Visible with `canTerminate == false` → skipped.
- `ownPID` → a target only if it is the **only** visible pid in `pids`; otherwise skipped.

Dialog text:
- One target: `title` = `signal.confirmTitle(name:)`, `message` = `signal.confirmMessage(name:pid:)` — today's strings — plus `"\n\n" + skippedNote` when `skippedCount > 0`.
- Several: `title` = `confirmTitle(count:)`; `message` = `confirmMessage(groupedNames:count:)` plus the skipped note likewise.
- Copy (exact): `confirmTitle(count:)` → `"\(actionTitle) \(count) processes?"`. `skippedNote(1)` → `"1 selected process can’t be signalled and will be left alone."`; `skippedNote(n)` → `"\(n) selected processes can’t be signalled and will be left alone."`. `confirmMessage(groupedNames:count:)` per signal:
  - terminate: `"These processes will be asked to quit: \(names)."`
  - kill: `"Force-quitting ends these processes immediately; unsaved work is lost: \(names)."`
  - stop: `"These processes will be paused (SIGSTOP) until you resume them: \(names)."`
  - resume: `"These processes will be resumed (SIGCONT): \(names)."`
  - hangUp: `"These processes will be sent SIGHUP: \(names). Many background services reload their settings; most other programs quit."`

- [ ] **Step 1: Write the failing tests** in `ProcessBatchTests.swift` (a helper `row(_ pid:, _ name:, signallable: Bool = true)` builds `ProcessInfoRow` with `memoryBytes: signallable ? 1 : nil`):

```swift
@Test func hiddenAndExitedPIDsAreIgnoredNotSkipped() {
    let batch = ProcessBatch.make(pids: [1, 2, 3], visibleRows: [row(2, "node")], ownPID: 999)
    #expect(batch.targets == [SignalTarget(pid: 2, name: "node")])
    #expect(batch.skippedCount == 0)
}
@Test func unsignallableVisibleRowsAreSkipped() {
    let batch = ProcessBatch.make(pids: [1, 2], visibleRows: [row(1, "node"), row(2, "launchd", signallable: false)], ownPID: 999)
    #expect(batch.targets.map(\.pid) == [1])
    #expect(batch.skippedCount == 1)
}
@Test func targetsFollowVisibleOrder() {
    let batch = ProcessBatch.make(pids: [1, 2, 3], visibleRows: [row(3, "c"), row(1, "a"), row(2, "b")], ownPID: 999)
    #expect(batch.targets.map(\.pid) == [3, 1, 2])
}
@Test func ownProcessIsATargetOnlyWhenAlone() {
    #expect(ProcessBatch.make(pids: [50], visibleRows: [row(50, "macOSmonitor")], ownPID: 50).targets.map(\.pid) == [50])
    // hidden companions don't count
    #expect(ProcessBatch.make(pids: [50, 7], visibleRows: [row(50, "macOSmonitor")], ownPID: 50).targets.map(\.pid) == [50])
    let withOther = ProcessBatch.make(pids: [50, 7], visibleRows: [row(50, "macOSmonitor"), row(7, "node")], ownPID: 50)
    #expect(withOther.targets.map(\.pid) == [7])
    #expect(withOther.skippedCount == 1)
    // an unsignallable companion still counts as "not alone"
    let withRoot = ProcessBatch.make(pids: [50, 1], visibleRows: [row(50, "macOSmonitor"), row(1, "launchd", signallable: false)], ownPID: 50)
    #expect(withRoot.targets.isEmpty)
    #expect(withRoot.skippedCount == 2)
}
@Test func groupedNamesCountsMostCommonFirst() {
    let batch = ProcessBatch(targets: [.init(pid: 1, name: "npm"), .init(pid: 2, name: "node"), .init(pid: 3, name: "node"),
                                      .init(pid: 4, name: "esbuild"), .init(pid: 5, name: "node")], skippedCount: 0)
    #expect(batch.groupedNames == "node ×3, esbuild, npm")
}
@Test func noTargetsMeansNoRequest() {
    #expect(PendingTermination.request(for: ProcessBatch(targets: [], skippedCount: 2), signal: .terminate) == nil)
}
@Test func singleTargetKeepsTodaysDialog() {
    let request = PendingTermination.request(for: ProcessBatch(targets: [.init(pid: 42, name: "node")], skippedCount: 0), signal: .terminate)!
    #expect(request.title == "Quit “node”?")
    #expect(request.message == "“node” (PID 42) will be asked to quit.")
}
@Test func singleTargetWithSkippedAddsTheNote() {
    let request = PendingTermination.request(for: ProcessBatch(targets: [.init(pid: 42, name: "node")], skippedCount: 1), signal: .terminate)!
    #expect(request.message == "“node” (PID 42) will be asked to quit.\n\n1 selected process can’t be signalled and will be left alone.")
}
@Test func severalTargetsUseTheBatchDialog() {
    let request = PendingTermination.request(for: ProcessBatch(targets: [.init(pid: 1, name: "node"), .init(pid: 2, name: "node")], skippedCount: 3), signal: .kill)!
    #expect(request.title == "Force Quit 2 processes?")
    #expect(request.message == "Force-quitting ends these processes immediately; unsaved work is lost: node ×2.\n\n3 selected processes can’t be signalled and will be left alone.")
}
```

- [ ] **Step 2: Build; expect compile failure.**
- [ ] **Step 3: Implement** the types above in `ProcessBatch.swift`; delete the old `PendingTermination` from `ProcessesView.swift`. (ProcessesView/ContentView call sites are fixed in Task 4; to keep the build green now, make the old call sites compile by building a one-pid batch: `PendingTermination.request(for: ProcessBatch.make(pids: Set([row.pid]), visibleRows: [row]), signal:)`.)
- [ ] **Step 4: Run** `ProcessBatchTests` and the full unit suite. Expected: all pass. Mutation-check: drop the "only visible pid" condition → `ownProcessIsATargetOnlyWhenAlone` fails; skip the tie-break → reorder fixture so it fails.

### Task 3: Sending a batch and summarising the outcome

**Files:**
- Modify: `macOSmonitor/ProcessListModel.swift` (new `send(_:to:)` overload)
- Modify: `macOSmonitor/ProcessBatch.swift` (outcome summary)
- Modify: `macOSmonitorTests/ProcessListModelTests.swift` (`FakeTerminator` gains `private(set) var sent: [(signal: ProcessSignal, pid: pid_t)]`, appended in `send`; `lastPID`/`lastSignal` stay)
- Test: `macOSmonitorTests/ProcessBatchTests.swift`, `macOSmonitorTests/ProcessListModelTests.swift`

**Interfaces:**
- Consumes: `SignalTarget` (Task 2).
- Produces:
  - `ProcessListModel.send(_ signal: ProcessSignal, to targets: [SignalTarget]) -> [SignalOutcome]` — for each target, in order: if `rows` has no row with that pid **and** that name, the outcome is `.noSuchProcess` and the terminator is not called; otherwise `terminator.send`.
  - `struct SignalOutcome: Equatable, Sendable { let target: SignalTarget; let result: TerminationResult }`
  - `static func SignalOutcome.failureMessage(_ outcomes: [SignalOutcome], signal: ProcessSignal) -> String?` — nil when every result is `.success`.

Message rules:
- Exactly one outcome: today's single-process strings, moved verbatim from `ProcessesView.perform` (`"Couldn’t quit “x”: permission denied."`, `"“x” is no longer running."`, the self-pause string, `"Couldn’t quit “x”: <reason>."`; verb is `actionTitle.lowercased()`).
- Several: `"\(actionTitle) \(succeeded) of \(total) processes. Couldn’t \(verb): " + failures.joined(separator: "; ") + "."`, each failure `"\(name) (\(reason))"` where reason is `permission denied` / `no longer running` / `can’t pause itself` / the failure string. Failures in outcome order.

- [ ] **Step 1: Write the failing tests**

```swift
// ProcessListModelTests
@Test func batchSendSkipsAPIDNowRunningSomethingElse() async {
    let sampler = FakeSampler()
    sampler.next = [ProcessInfoRow(pid: 1, name: "node", cpuPercent: nil, memoryBytes: 1),
                    ProcessInfoRow(pid: 2, name: "Safari", cpuPercent: nil, memoryBytes: 1)]
    let terminator = FakeTerminator()
    let model = ProcessListModel(sampler: sampler, terminator: terminator)
    await model.refreshOnce()
    let outcomes = model.send(.terminate, to: [.init(pid: 1, name: "node"), .init(pid: 2, name: "node"), .init(pid: 3, name: "node")])
    #expect(terminator.sent.map(\.pid) == [1])
    #expect(outcomes.map(\.result) == [.success, .noSuchProcess, .noSuchProcess])
}
@Test func batchResumeSignalsEveryTarget() async { /* rows 1,2,3 "node"; send(.resume, to: all three) → terminator.sent == 3 entries, all .resume */ }

// ProcessBatchTests
@Test func allSucceededHasNoMessage() { /* two .success outcomes → nil */ }
@Test func singleFailureKeepsTodaysWording() {
    #expect(SignalOutcome.failureMessage([.init(target: .init(pid: 1, name: "x"), result: .denied)], signal: .terminate)
            == "Couldn’t quit “x”: permission denied.")
}
@Test func batchFailuresAreListedOnce() {
    let outcomes: [SignalOutcome] = [
        .init(target: .init(pid: 1, name: "node"), result: .success),
        .init(target: .init(pid: 2, name: "helper"), result: .denied),
        .init(target: .init(pid: 3, name: "node"), result: .success),
        .init(target: .init(pid: 4, name: "node"), result: .noSuchProcess)]
    #expect(SignalOutcome.failureMessage(outcomes, signal: .kill)
            == "Force Quit 2 of 4 processes. Couldn’t force quit: helper (permission denied); node (no longer running).")
}
```

Fill the two commented tests with the assertions stated in their comments.

- [ ] **Step 2: Build; expect compile failure.**
- [ ] **Step 3: Implement** `send(_:to:)` and `failureMessage`.
- [ ] **Step 4: Run** the unit suite. Expected: all pass. Mutation-check: drop the name comparison in the re-check → the first test fails.

### Task 4: Wire the UI

**Files:**
- Modify: `macOSmonitor/ContentView.swift` (compute `sections` once; toolbar requests; pass sections down)
- Modify: `macOSmonitor/ProcessesView.swift` (table `Set<pid_t>` selection, context menu, focused value, dialog, perform)
- Modify: `macOSmonitor/ProcessDetailView.swift` (multi-selection summary)

**Interfaces:**
- Consumes: Task 1 `selectedPIDs`, `selectedRows`; Task 2 `ProcessBatch.make`, `PendingTermination.request(for:signal:)`, `.title`, `.message`; Task 3 `send(_:to:)`, `SignalOutcome.failureMessage`.

Steps:
- [ ] **Step 1: ContentView** — add `private var sections: [ProcessTableSection]` (today's `ProcessTableSection.make(...)` call, moved from ProcessesView) and `private var visibleRows: [ProcessInfoRow] { sections.flatMap(\.rows) }`. `ProcessesView` takes `sections: [ProcessTableSection]` instead of building them. `canTerminateSelection` = on `.processes` and `!ProcessBatch.make(pids: model.selectedPIDs, visibleRows: visibleRows).targets.isEmpty`; `processRequest(_:)` uses the same batch.
- [ ] **Step 2: ProcessesView** —
  - Table selection binds `$model.selectedPIDs`; `ProcessTableView.selection: Set<pid_t>`; `themedCell(selected: selection.contains(row.pid))`.
  - `.onChange(of: model.selectedPIDs) { model.refreshSelection() }`.
  - Context menu builds `ProcessBatch.make(pids: ids, visibleRows: sections.flatMap(\.rows))` from **its `ids`**, not the model selection (spec: right-click outside the selection acts on that row alone). Items enabled when the batch has targets.
  - Focused `ProcessTerminationActions` uses the selection batch.
  - `requestSignal(_ signal:, batch:)` → `PendingTermination.request(for:signal:)`; confirm unless `signal.needsConfirmation == false` (Resume), as today.
  - Dialog title/message from `item.title` / `item.message`.
  - `perform` → `model.send(item.signal, to: item.targets)`, then `errorMessage = SignalOutcome.failureMessage(outcomes, signal: item.signal)`. Alert title becomes `"Couldn’t signal process"` for one outcome and `"Couldn’t signal some processes"` for several (keep the title in `errorMessage`'s owner: simplest is to keep one title "Couldn’t signal process" — builder's call).
- [ ] **Step 3: ProcessDetailView** — before `if let row = model.selectedRow`, when `model.selectedPIDs.count > 1`: `ContentUnavailableView("\(model.selectedRows.count) Processes Selected", systemImage: "cpu", description: Text(ProcessBatch(targets: model.selectedRows.map { SignalTarget(pid: $0.pid, name: $0.name) }, skippedCount: 0).groupedNames))`. Read the model inside `body` (no local snapshot `let`).
- [ ] **Step 4: Clean build + full unit suite.** Expected: build succeeds with zero warnings (clean build), all unit tests pass.
- [ ] **Step 5: Hand check with Peter** — run several `sleep 600` children under a name to search for, e.g. `for i in 1 2 3; do /bin/sleep 600 & done`; in the app search `sleep`, ⌘A, Quit → one dialog "Quit 3 processes?" naming `sleep ×3`; confirm; rows vanish. Also: right-click an unselected row with others selected → acts on that row only. Then Peter re-runs the **Bug A repro** (commit `cd69ee7`).
- [ ] **Step 6:** Tick the TODO item; commit when Peter asks.
