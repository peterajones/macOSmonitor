# Table Search/Filter (Milestone 4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `.searchable` toolbar field that live-filters the process table by name or PID, and fold in the deferred CPU%/Memory formatting cleanup.

**Architecture:** A pure `matches(_:)` method plus `cpuText`/`memoryText` computed properties on `ProcessInfoRow` (unit-tested); `ContentView` holds `@State searchText`, adds `.searchable(text:)`, and filters `model.rows` before sorting; both `ContentView` and `ProcessDetailView` use the shared text properties. No new files, no model changes.

**Tech Stack:** Swift, SwiftUI (`.searchable`, `Table`), Swift Testing, Xcode 26 (`xcodebuild`).

## Global Constraints

- **Platform / project:** existing `macOSmonitor` macOS app, non-sandboxed, `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated`. Test import: `@testable import macOSmonitor`.
- **Build:** `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' build`
- **Test:** `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test` (MUST scope to `macOSmonitorTests`; the UI-test target times out under CLI).
- **Matching:** case-insensitive substring of `name` OR substring of `String(pid)`; empty/whitespace-only query → matches all.
- **SourceKit** "No such module 'Testing'" / "Cannot find type" diagnostics in-editor are known indexer lag, not real — trust `xcodebuild` only.

---

### Task 1: `ProcessInfoRow` — `matches` + shared text formatting

**Files:**
- Modify: `macOSmonitor/ProcessInfoRow.swift`
- Test: `macOSmonitorTests/ProcessInfoRowTests.swift` (add cases)

**Interfaces:**
- Produces on `ProcessInfoRow`:
  - `func matches(_ query: String) -> Bool` — empty/whitespace query → true; else case-insensitive substring of `name` OR substring of `String(pid)`.
  - `var cpuText: String` — `cpuPercent` formatted to one decimal, or `"—"`.
  - `var memoryText: String` — `memoryBytes` via `ByteCountFormatter` (`.memory`), or `"—"`.

- [ ] **Step 1: Add the failing tests**

Append to `macOSmonitorTests/ProcessInfoRowTests.swift`, inside `struct ProcessInfoRowTests` (before its closing brace):

```swift
    @Test func matchesEmptyOrWhitespaceQueryReturnsTrue() {
        let row = ProcessInfoRow(pid: 42, name: "Safari", cpuPercent: nil, memoryBytes: nil)
        #expect(row.matches("") == true)
        #expect(row.matches("   ") == true)
    }

    @Test func matchesNameCaseInsensitiveSubstring() {
        let row = ProcessInfoRow(pid: 42, name: "Safari", cpuPercent: nil, memoryBytes: nil)
        #expect(row.matches("saf") == true)
        #expect(row.matches("ARI") == true)
        #expect(row.matches("chrome") == false)
    }

    @Test func matchesPIDSubstring() {
        let row = ProcessInfoRow(pid: 7712, name: "Safari", cpuPercent: nil, memoryBytes: nil)
        #expect(row.matches("771") == true)
        #expect(row.matches("7712") == true)
        #expect(row.matches("99") == false)
    }

    @Test func textPropertiesFallBackToDashWhenMissing() {
        let denied = ProcessInfoRow(pid: 1, name: "x", cpuPercent: nil, memoryBytes: nil)
        #expect(denied.cpuText == "—")
        #expect(denied.memoryText == "—")
    }

    @Test func cpuTextFormatsOneDecimalAndMemoryTextNonEmpty() {
        let row = ProcessInfoRow(pid: 1, name: "x", cpuPercent: 12.34, memoryBytes: 1024)
        #expect(row.cpuText == "12.3")
        #expect(row.memoryText.isEmpty == false)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests build-for-testing 2>&1 | grep -iE 'error:|has no member'`
Expected: FAIL — `value of type 'ProcessInfoRow' has no member 'matches'` (and `cpuText`/`memoryText`).

- [ ] **Step 3: Implement the additions**

In `macOSmonitor/ProcessInfoRow.swift`, change the import line from `import Darwin` to:

```swift
import Darwin
import Foundation
```

Then add these members inside `struct ProcessInfoRow`, immediately after the `canTerminate` property:

```swift
    /// Case-insensitive substring match against name or PID. Empty/whitespace → matches all.
    func matches(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return name.range(of: trimmed, options: .caseInsensitive) != nil
            || String(pid).contains(trimmed)
    }

    /// CPU% formatted for display, or an em dash when detail is unavailable.
    var cpuText: String { cpuPercent.map { String(format: "%.1f", $0) } ?? "—" }

    /// Resident memory formatted for display, or an em dash when detail is unavailable.
    var memoryText: String {
        memoryBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) } ?? "—"
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test 2>&1 | grep -iE 'ProcessInfoRow.*(passed|failed)|TEST (SUCCEEDED|FAILED)'`
Expected: `** TEST SUCCEEDED **`, all new `ProcessInfoRowTests` pass alongside the existing ones.

- [ ] **Step 5: Commit**

```bash
git add macOSmonitor/ProcessInfoRow.swift macOSmonitorTests/ProcessInfoRowTests.swift
git commit -m "feat: add matches(_:) search and shared cpuText/memoryText to ProcessInfoRow"
```

---

### Task 2: Wire search into `ContentView`; use shared text in both views

**Files:**
- Modify: `macOSmonitor/ContentView.swift`
- Modify: `macOSmonitor/ProcessDetailView.swift`

**Interfaces:**
- Consumes: `ProcessInfoRow.matches(_:)`, `.cpuText`, `.memoryText` (Task 1).
- Produces: the search UI. No unit test (SwiftUI views); validated by build + manual verification.

- [ ] **Step 1: Add `searchText` state to `ContentView`**

In `macOSmonitor/ContentView.swift`, after the line `@State private var showInspector = true`, add:

```swift
    @State private var searchText = ""
```

- [ ] **Step 2: Filter the table data**

In `ContentView.swift`, replace the `Table(...)` opening line:

```swift
        Table(model.rows.sorted(using: sortOrder), selection: $model.selectedPID, sortOrder: $sortOrder) {
```

with:

```swift
        Table(model.rows.filter { $0.matches(searchText) }.sorted(using: sortOrder),
              selection: $model.selectedPID, sortOrder: $sortOrder) {
```

- [ ] **Step 3: Use the shared text properties in the table cells**

In `ContentView.swift`, replace the CPU% column cell:

```swift
            TableColumn("CPU %", value: \.cpuSortKey) { row in
                Text(row.cpuPercent.map { String(format: "%.1f", $0) } ?? "—")
                    .monospacedDigit()
            }
```

with:

```swift
            TableColumn("CPU %", value: \.cpuSortKey) { row in
                Text(row.cpuText)
                    .monospacedDigit()
            }
```

And replace the Memory column cell:

```swift
            TableColumn("Memory", value: \.memSortKey) { row in
                Text(row.memoryBytes.map {
                    ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory)
                } ?? "—")
                .monospacedDigit()
            }
```

with:

```swift
            TableColumn("Memory", value: \.memSortKey) { row in
                Text(row.memoryText)
                    .monospacedDigit()
            }
```

- [ ] **Step 4: Add the `.searchable` modifier**

In `ContentView.swift`, find the line `.navigationTitle("macOSmonitor")` and add the searchable modifier immediately after it:

```swift
        .navigationTitle("macOSmonitor")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Filter by name or PID")
```

- [ ] **Step 5: Use the shared text properties in `ProcessDetailView`**

In `macOSmonitor/ProcessDetailView.swift`, replace the CPU% and Memory rows:

```swift
                    LabeledContent("CPU %", value: row.cpuPercent.map { String(format: "%.1f", $0) } ?? "—")
                    LabeledContent("Memory", value: row.memoryBytes.map {
                        ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory)
                    } ?? "—")
```

with:

```swift
                    LabeledContent("CPU %", value: row.cpuText)
                    LabeledContent("Memory", value: row.memoryText)
```

- [ ] **Step 6: Build**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' build 2>&1 | grep -iE 'error:|BUILD (SUCCEEDED|FAILED)'`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Run the full unit suite (nothing regressed)**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test 2>&1 | grep -E 'TEST (SUCCEEDED|FAILED)'`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 8: Manual verification**

Launch the app. Verify:
- A **search field appears in the toolbar** (magnifying glass, placeholder "Filter by name or PID").
  - If the field does NOT appear: `.searchable` needs a navigation container in this layout — wrap the `Table(...)`-through-final-modifier body in a `NavigationStack { … }` and rebuild. (This is the only expected contingency.)
- Typing part of a process **name** narrows the table to matches, live as you type; clearing restores the full list.
- Typing a **PID** (e.g. the PID of a `sleep 600 &` you spawn) surfaces that process.
- **⌘F** focuses the search field.
- **Sorting** still works on the filtered set (click a column header while a filter is active).
- Select a process, then type a filter that **excludes** it: the row leaves the table but the **inspector keeps showing that process's details** (intended).
- CPU%/Memory still render correctly in both the table and the inspector (shared formatting).

- [ ] **Step 9: Commit**

```bash
git add macOSmonitor/ContentView.swift macOSmonitor/ProcessDetailView.swift
git commit -m "feat: searchable name/PID filter for the process table"
```

---

## Definition of Done (Milestone 4)

- A toolbar search field filters the table by name or PID, live, case-insensitive; empty field shows all.
- Filtering composes with sorting and the ~1 Hz refresh; selection/inspector persist through filtering.
- CPU%/Memory formatting is shared via `ProcessInfoRow.cpuText`/`memoryText` (no duplication).
- All unit tests pass via `xcodebuild ... -only-testing:macOSmonitorTests test`.
- Each task committed separately.
