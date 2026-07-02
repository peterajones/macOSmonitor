# macOSmonitor — Process Detail Inspector Design (Milestone 3)

**Date:** 2026-07-02
**Status:** Approved for implementation planning
**Author:** Peter Jones (with Claude)

## Context

Milestones 1 and 2 shipped a live, sortable process table (`ProcInfo` → `ProcessSampler` →
`ProcessListModel` → SwiftUI `Table`) with Quit/Force-Quit termination. Milestone 3 adds a
read-only **detail inspector** for the selected process. It teaches more of `libproc`
(`PROC_PIDTASKALLINFO`, `proc_pidpath`, `getpwuid`) and SwiftUI's `.inspector`.

## Goal & Success Criteria

A right-side inspector showing the selected process's full path, parent PID, start time, thread
count, user, and status — echoing Name/PID/CPU%/Memory for context — **updating live** on the
existing ~1 Hz tick, and toggleable from the toolbar.

**Success = selecting a process fills the inspector with correct details that match
`ps`/Activity Monitor; thread count and status update while selected; denied ("—") and
no-selection states are handled gracefully.**

## Scope

**In scope (Milestone 3):**
- A right-side inspector (`.inspector`), shown by default on launch, toggleable via a toolbar button.
- Fields: full executable path, parent PID (PPID), start time, thread count, user, status.
- An echo of Name / PID / CPU% / Memory at the top for context.
- Live updates on the same ~1 Hz cadence as the table while a row is selected.
- Selection state lives in `ProcessListModel` as the single source of truth (small refactor of
  the M2 termination wiring, which currently reads a view-local selection).

**Out of scope (documented for the future):**
- Command-line arguments (argv) — needs `sysctl KERN_PROCARGS2`, often permission-limited; later.
- Open files / ports, environment variables, per-process network or disk I/O.
- Editing anything from the inspector (renice, etc.).
- A separate detached info window (we chose the inspector idiom).

## Key Decisions

- **Layout: right-side inspector** (`.inspector`) — the modern macOS-native idiom, built-in
  show/hide, single window, low SwiftUI effort. (Chosen over a bottom pane or separate window.)
- **Field set** (as listed) — the "what/where/who/when" of a process without gold-plating.
- **Live-updating** — details refresh each ~1 Hz tick while selected, so thread count/status stay
  current; cost is one extra `proc_pidinfo` per second (negligible). (Chosen over a static
  snapshot on selection.)
- **Inspector shown by default on launch.**
- **Selection in the model** — `selectedPID` on `ProcessListModel` is the single source of truth,
  bound to the `Table` and used by termination too.
- **Synchronous detail fetch** — one selected process, a couple of cheap syscalls; runs on the
  main actor like `terminate`, no actor needed.

## Architecture

Extends the existing units; the new syscalls stay isolated in `ProcInfo`.

```
Table(selection: $model.selectedPID) ──▶ ProcessListModel (@MainActor)
      │                                      │  selectedPID, selectedDetails
      │ .inspector { ProcessDetailView(...) }  │  refreshDetails() each tick
      ▼                                      ▼
ProcessDetailView (Form of labels)     ProcessDetailProviding
                                              │
                                              ▼
                                        ProcInfo.details(pid:) ── proc_pidinfo/
                                                                  proc_pidpath/getpwuid
```

### New data + fetch (in `ProcInfo`)

```swift
struct ProcessDetails: Equatable, Sendable {
    let path: String?        // proc_pidpath; nil if unavailable
    let parentPID: pid_t
    let startDate: Date
    let threadCount: Int
    let user: String         // uid → name via getpwuid, else "uid N"
    let status: String       // Idle / Running / Sleeping / Stopped / Zombie / Unknown
}

protocol ProcessDetailProviding: Sendable {
    func details(pid: pid_t) -> ProcessDetails?
}
```

`ProcInfo` conforms to `ProcessDetailProviding`. `details(pid:)`:
- `proc_pidinfo(pid, PROC_PIDTASKALLINFO, …, &proc_taskallinfo)` — one call gives BSD info
  (`pbi_ppid`, `pbi_start_tvsec`, `pbi_uid`, `pbi_status`) and task info (`pti_threadnum`).
  Returns `nil` (denied/exited) if the call doesn't fill the struct.
- `proc_pidpath` → `path` (nil on failure).
- `getpwuid(uid)` → username; fall back to `"uid <n>"`.
- `pbi_status` mapped by raw value: 1→Idle, 2→Running, 3→Sleeping, 4→Stopped, 5→Zombie,
  else Unknown (raw constants avoided for Swift-visibility safety).

### Model changes (`ProcessListModel`)

- `var selectedPID: pid_t?` (bound to the table).
- `private(set) var selectedDetails: ProcessDetails?`.
- Inject `detailProvider: any ProcessDetailProviding = ProcInfo()`.
- `func refreshDetails()` → `selectedDetails = selectedPID.flatMap { detailProvider.details(pid: $0) }`.
- `refreshOnce()` calls `refreshDetails()` after assigning rows (live cadence).
- Termination and `selectedRow` now read `selectedPID`.

### UI (`ContentView` + `ProcessDetailView`)

- `@Bindable` model; `Table(..., selection: $model.selectedPID, ...)`.
- `.onChange(of: model.selectedPID) { model.refreshDetails() }` for instant population.
- `@State private var showInspector = true`; a toolbar button toggles it.
- `.inspector(isPresented: $showInspector) { ProcessDetailView(row: selectedRow, details: model.selectedDetails) }`.
- **`ProcessDetailView`** renders three states:
  - no selection → "Select a process";
  - selected, `details == nil` → "Details unavailable (permission denied)";
  - otherwise → a `Form` of labeled fields (echo header + the six detail fields).

## Data Flow (selected process, one tick)

1. Loop calls `refreshOnce()` → assigns `rows`, then `refreshDetails()`.
2. `refreshDetails()` fetches `details(selectedPID)` → publishes `selectedDetails`.
3. Inspector re-renders with current thread count / status.
4. On a new selection, `.onChange` calls `refreshDetails()` immediately (no ~1 s wait).

## Error Handling

- **Denied/exited process** → `details` returns `nil` → inspector shows the "unavailable" state.
- **Process exits while selected** → next `refreshDetails()` yields `nil`; the row also leaves the
  table on the next sample.
- **`getpwuid` returns null** → user shows `"uid <n>"`.
- **`proc_pidpath` fails but task info succeeded** → `path` is `nil`, other fields still shown.

## Testing Strategy

- **`ProcInfo.details`** (integration, live system):
  - `details(getpid())` is non-nil; `threadCount >= 1`; `parentPID > 0`; `path` non-empty and
    contains the test runner executable; `user` equals the current username
    (`getpwuid(getuid())`); `startDate` is in the past.
  - A denied PID (e.g. a root-owned process, guarded to non-root runs) → `nil`.
- **`ProcessListModel`** (unit): inject a fake `ProcessDetailProviding`; setting `selectedPID`
  then `refreshDetails()` publishes the fake's `ProcessDetails`; `selectedPID = nil` then
  `refreshDetails()` clears `selectedDetails`.
- **`ProcessDetailView` / inspector** (manual verification): select a process → fields populate
  and match `ps`; watch thread count/status update live; select a "—" row → "unavailable";
  deselect → placeholder; toggle the inspector from the toolbar.

## Open Questions

None blocking.
