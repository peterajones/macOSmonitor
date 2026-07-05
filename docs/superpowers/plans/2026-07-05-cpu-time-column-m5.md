# CPU Time Column (Milestone 5) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a sortable CPU Time column (cumulative user+system CPU time) after CPU %, echoed in the inspector, using data already fetched.

**Architecture:** `ProcessInfoRow` gains a defaulted `cpuTimeNanos` plus `cpuTimeText`/`cpuTimeSortKey`; `ProcessSampler` carries the already-fetched `ProcTaskSample.cpuTimeNanos` onto owned rows; `ProcessTableView` and `ProcessDetailView` display it. No new files, no new syscalls.

**Tech Stack:** Swift, SwiftUI (`Table`, `LabeledContent`), Swift Testing, Xcode 26 (`xcodebuild`).

## Global Constraints

- **Platform / project:** existing `macOSmonitor` macOS app, non-sandboxed, `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated`. Test import: `@testable import macOSmonitor`.
- **Build:** `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' build`
- **Test:** `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test` (MUST scope to `macOSmonitorTests`; the UI-test target times out under CLI).
- **Data source:** `ProcTaskSample.cpuTimeNanos` (already returned by `ProcInfo.sample`, already Mach-tick→nanosecond converted). No new syscalls.
- **Format (verified):** `nil→"—"`, `0→"0:00.00"`, `3.03s→"0:03.03"`, `125.37s→"2:05.37"`, `just-under-1h→"59:59.99"`, `3600s→"1:00:00"`, `5025s→"1:23:45"`.
- **SourceKit** "No such module 'Testing'" / "Cannot find type" diagnostics are known indexer lag, not real — trust `xcodebuild` only.

---

### Task 1: `ProcessInfoRow` — cumulative CPU time + formatting

**Files:**
- Modify: `macOSmonitor/ProcessInfoRow.swift`
- Test: `macOSmonitorTests/ProcessInfoRowTests.swift` (add cases)

**Interfaces:**
- Produces on `ProcessInfoRow`:
  - `var cpuTimeNanos: UInt64? = nil` (defaulted stored property — existing constructors keep compiling).
  - `var cpuTimeText: String` — adaptive `M:SS.ss` / `H:MM:SS`, `"—"` when nil.
  - `var cpuTimeSortKey: UInt64` — `cpuTimeNanos ?? 0`.

- [ ] **Step 1: Add the failing tests**

Append inside `struct ProcessInfoRowTests` (before its closing brace) in `macOSmonitorTests/ProcessInfoRowTests.swift`:

```swift
    @Test func cpuTimeTextAndSortKeyFallBackWhenNil() {
        let row = ProcessInfoRow(pid: 1, name: "x", cpuPercent: nil, memoryBytes: nil)
        #expect(row.cpuTimeText == "—")
        #expect(row.cpuTimeSortKey == 0)
    }

    @Test func cpuTimeTextFormatsSubHour() {
        let sub = ProcessInfoRow(pid: 1, name: "x", cpuPercent: nil, memoryBytes: nil,
                                 cpuTimeNanos: 3_030_000_000)              // 3.03s
        #expect(sub.cpuTimeText == "0:03.03")
        let mins = ProcessInfoRow(pid: 2, name: "y", cpuPercent: nil, memoryBytes: nil,
                                  cpuTimeNanos: 125_370_000_000)           // 2:05.37
        #expect(mins.cpuTimeText == "2:05.37")
    }

    @Test func cpuTimeTextRollsOverToHours() {
        let hour = ProcessInfoRow(pid: 3, name: "z", cpuPercent: nil, memoryBytes: nil,
                                  cpuTimeNanos: 5_025_000_000_000)          // 1:23:45
        #expect(hour.cpuTimeText == "1:23:45")
        #expect(hour.cpuTimeSortKey == 5_025_000_000_000)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests build-for-testing 2>&1 | grep -iE 'error:|has no member|extra argument'`
Expected: FAIL — `extra argument 'cpuTimeNanos' in call` and `has no member 'cpuTimeText'`/`'cpuTimeSortKey'`.

- [ ] **Step 3: Implement**

In `macOSmonitor/ProcessInfoRow.swift`, add the stored property immediately after `var memoryBytes: UInt64?`:

```swift
    var cpuTimeNanos: UInt64? = nil
```

And add these computed members after `canTerminate` (alongside the other display/sort helpers):

```swift
    /// Cumulative user+system CPU time, or "—" when unreadable. Adaptive format:
    /// M:SS.ss under an hour, H:MM:SS at/beyond an hour (matches Activity Monitor).
    var cpuTimeText: String {
        guard let nanos = cpuTimeNanos else { return "—" }
        let seconds = Double(nanos) / 1_000_000_000
        if seconds < 3600 {
            let minutes = Int(seconds) / 60
            let secs = seconds - Double(minutes * 60)
            return String(format: "%d:%05.2f", minutes, secs)
        } else {
            let total = Int(seconds)
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
    }

    var cpuTimeSortKey: UInt64 { cpuTimeNanos ?? 0 }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test 2>&1 | grep -iE 'cpuTime.*(passed|failed)|TEST (SUCCEEDED|FAILED)'`
Expected: `** TEST SUCCEEDED **`, the three new cases pass; existing `ProcessInfoRowTests` still pass.

- [ ] **Step 5: Commit**

```bash
git add macOSmonitor/ProcessInfoRow.swift macOSmonitorTests/ProcessInfoRowTests.swift
git commit -m "feat: add cumulative cpuTimeNanos + adaptive cpuTimeText to ProcessInfoRow"
```

---

### Task 2: `ProcessSampler` — carry cumulative CPU time onto owned rows

**Files:**
- Modify: `macOSmonitor/ProcessSampler.swift`
- Test: `macOSmonitorTests/ProcessSamplerTests.swift` (add a case + extend one)

**Interfaces:**
- Consumes: `ProcessInfoRow.cpuTimeNanos` (Task 1), `ProcTaskSample.cpuTimeNanos` (existing).
- Produces: owned rows carry `cpuTimeNanos = s.cpuTimeNanos`; denied rows leave it nil.

- [ ] **Step 1: Add / extend the failing tests**

In `macOSmonitorTests/ProcessSamplerTests.swift`, add this test inside `struct ProcessSamplerTests`:

```swift
    @Test func ownedRowCarriesCumulativeCPUTime() async {
        let fake = FakeProcInfo()
        fake.pids = [42]; fake.names = [42: "worker"]
        fake.results = [42: ProcTaskSample(residentBytes: 2048, cpuTimeNanos: 7_000_000_000)]
        let sampler = ProcessSampler(source: fake, now: { 0 })

        let rows = await sampler.sample()
        #expect(rows.first?.cpuTimeNanos == 7_000_000_000)
    }
```

And in the existing `deniedProcessYieldsNamePidOnly` test, add one assertion after the existing expectations:

```swift
        #expect(rows.first?.cpuTimeNanos == nil)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test 2>&1 | grep -iE 'ownedRowCarries.*(passed|failed)|TEST (SUCCEEDED|FAILED)'`
Expected: FAIL — `ownedRowCarriesCumulativeCPUTime` fails (`cpuTimeNanos` is nil because the sampler doesn't set it yet).

- [ ] **Step 3: Implement**

In `macOSmonitor/ProcessSampler.swift`, find the owned-process row construction:

```swift
            rows.append(ProcessInfoRow(pid: pid, name: name,
                                       cpuPercent: cpuPercent, memoryBytes: s.residentBytes))
```

and replace it with:

```swift
            rows.append(ProcessInfoRow(pid: pid, name: name,
                                       cpuPercent: cpuPercent, memoryBytes: s.residentBytes,
                                       cpuTimeNanos: s.cpuTimeNanos))
```

(Leave the denied branch's `ProcessInfoRow(pid: pid, name: name, cpuPercent: nil, memoryBytes: nil)` unchanged — `cpuTimeNanos` defaults to nil.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test 2>&1 | grep -iE 'ProcessSampler.*(passed|failed)|TEST (SUCCEEDED|FAILED)'`
Expected: `** TEST SUCCEEDED **`, including `ownedRowCarriesCumulativeCPUTime` and the extended denied test.

- [ ] **Step 5: Commit**

```bash
git add macOSmonitor/ProcessSampler.swift macOSmonitorTests/ProcessSamplerTests.swift
git commit -m "feat: carry cumulative CPU time onto sampled process rows"
```

---

### Task 3: Display the CPU Time column and inspector field

**Files:**
- Modify: `macOSmonitor/ContentView.swift` (the `ProcessTableView` columns)
- Modify: `macOSmonitor/ProcessDetailView.swift` (Process section)

**Interfaces:**
- Consumes: `ProcessInfoRow.cpuTimeText`, `.cpuTimeSortKey` (Task 1).
- Produces: the CPU Time column (after CPU %) and the inspector field. No unit test (SwiftUI views); validated by build + manual verification.

- [ ] **Step 1: Add the CPU Time column after CPU %**

In `macOSmonitor/ContentView.swift` (inside `ProcessTableView`'s `Table` builder), the CPU % column currently reads:

```swift
            TableColumn("CPU %", value: \.cpuSortKey) { row in
                Text(row.cpuText)
                    .monospacedDigit()
            }
```

Add the CPU Time column immediately after it (before the Memory column):

```swift
            TableColumn("CPU Time", value: \.cpuTimeSortKey) { row in
                Text(row.cpuTimeText)
                    .monospacedDigit()
            }
```

- [ ] **Step 2: Add the CPU Time inspector field**

In `macOSmonitor/ProcessDetailView.swift`, the Process section's CPU % row currently reads:

```swift
                    LabeledContent("CPU %", value: row.cpuText)
```

Add the CPU Time row immediately after it (before the Memory row):

```swift
                    LabeledContent("CPU Time", value: row.cpuTimeText)
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' build 2>&1 | grep -iE 'error:|BUILD (SUCCEEDED|FAILED)'`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run the full unit suite (nothing regressed)**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test 2>&1 | grep -E 'TEST (SUCCEEDED|FAILED)'`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Manual verification**

Launch the app. Verify:
- A **CPU Time** column sits immediately **after CPU %** (before Memory).
- Values are non-zero for processes that have run, and **climb over time** for busy ones (spawn `yes > /dev/null &` and watch its CPU Time increase; kill it after).
- Ballpark-match a couple against **Activity Monitor's CPU Time** column.
- Clicking the **CPU Time** header sorts by it; denied ("—" CPU/Memory) rows show **`—`** for CPU Time too and sort to the bottom.
- The **inspector** shows a **CPU Time** field (after CPU %) for the selected process, updating live.

- [ ] **Step 6: Commit**

```bash
git add macOSmonitor/ContentView.swift macOSmonitor/ProcessDetailView.swift
git commit -m "feat: show CPU Time column and inspector field"
```

---

## Definition of Done (Milestone 5)

- A sortable CPU Time column appears after CPU %, formatted adaptively, `—` for unreadable processes.
- CPU Time also shows in the inspector.
- Values climb over time and roughly match Activity Monitor.
- All unit tests pass via `xcodebuild ... -only-testing:macOSmonitorTests test`.
- Each task committed separately.
