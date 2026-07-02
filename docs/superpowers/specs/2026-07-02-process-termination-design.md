# macOSmonitor — Process Termination Design (Milestone 2)

**Date:** 2026-07-02
**Status:** Approved for implementation planning
**Author:** Peter Jones (with Claude)

## Context

Milestone 1 shipped a read-only live process table (`ProcInfo` → `ProcessSampler` →
`ProcessListModel` → SwiftUI `Table`). Milestone 2 adds the first *control* capability:
terminating a selected process. This teaches Unix signals (`kill`, SIGTERM vs SIGKILL) and
SwiftUI selection / toolbar / confirmation-dialog / alert APIs.

## Goal & Success Criteria

Let the user **Quit (SIGTERM)** or **Force Quit (SIGKILL)** a selected process, from **both**
a right-click context menu and **toolbar buttons**, each guarded by a **confirmation dialog**.

**Success = selecting one of my own processes and choosing Quit or Force Quit terminates it
(it disappears from the table on the next refresh); actions are unavailable for processes I
can't kill; and any failure surfaces as a readable message instead of silently doing nothing.**

## Scope

**In scope (Milestone 2):**
- Single-row selection in the table.
- Two actions per selected process: **Quit** (SIGTERM) and **Force Quit** (SIGKILL).
- Both actions available via a **row context menu** and **toolbar buttons**.
- A **confirmation dialog** naming the process precedes both actions.
- Actions are **disabled** for processes the user can't signal (the "—"/denied rows).
- `kill()` failures (permission denied, process already gone, other errno) surface as an
  **alert**, covering the display-vs-click race.

**Out of scope (documented for the future):**
- Multi-select termination (kill several at once). Single-selection only in M2 (YAGNI).
- Sending arbitrary signals (SIGSTOP/SIGCONT/SIGHUP, etc.).
- Terminating other users'/root processes (needs the future privileged XPC helper).
- Undo / "are you sure" beyond the single confirmation.
- Toolbar customization, keyboard shortcuts (can be a later polish pass).

## Key Decisions

- **Both signals (Quit + Force Quit)**, matching Activity Monitor — same `kill()` call, differing
  only by signal constant; teaches the SIGTERM/SIGKILL distinction.
- **Both entry points** (context menu + toolbar) — context menu is the native idiom; toolbar is
  discoverable. Toolbar acts on the current selection; context menu on the right-clicked row.
- **Confirm both actions** — termination is irreversible; a confirmation dialog naming the
  process guards both, same code path.
- **Disable on un-killable rows + still handle errors** — `canTerminate` reflects capability up
  front; the error path is retained for the race where a process exits or perms change between
  render and click.
- **`canTerminate = memoryBytes != nil`** — if `proc_pidinfo` returned task info (memory), the
  process is readable, which under the same euid ownership check means it is also signalable.
- **Synchronous termination** — `kill()` is an instant, non-blocking syscall; no actor needed.
  It runs on the main actor directly from `ProcessListModel`.

## Architecture

One new unit, plus small additions to two existing ones. Follows the M1 pattern of isolating
every raw syscall behind a testable protocol.

```
ContentView (selection, toolbar, context menu, confirmationDialog, alert)
      │  calls model.terminate(pid:force:)
      ▼
ProcessListModel (@MainActor)  ── holds ──▶ ProcessTerminating
      │                                          │
      │ returns TerminationResult                ▼
      │                                   ProcessTerminator  ── kill() ──▶ kernel
      ▼
ProcessInfoRow.canTerminate  (drives enable/disable)
```

### New unit — `ProcessTerminator`

```swift
enum TerminationResult: Equatable, Sendable {
    case success
    case denied          // EPERM
    case noSuchProcess   // ESRCH
    case failure(String) // other errno, strerror text
}

protocol ProcessTerminating: Sendable {
    func terminate(pid: pid_t, force: Bool) -> TerminationResult
}

struct ProcessTerminator: ProcessTerminating {
    // kill(pid, force ? SIGKILL : SIGTERM)
    // returns 0 on success; -1 sets errno: EPERM→denied, ESRCH→noSuchProcess,
    // else→failure(String(cString: strerror(errno)))
}
```

The only file besides `ProcInfo` that touches raw C process syscalls.

### Additions to existing units

- **`ProcessInfoRow`**: `var canTerminate: Bool { memoryBytes != nil }`.
- **`ProcessListModel`**: stores `any ProcessTerminating` (default `ProcessTerminator()`),
  injected via `init` for testing; adds
  `func terminate(pid: pid_t, force: Bool) -> TerminationResult` delegating to it.

### UI (`ContentView`)

- `@State private var selection: pid_t?` bound to `Table(..., selection:)`.
- Local UI state:
  - `pendingTermination: PendingTermination?` (holds `pid`, `name`, `force`) drives the
    `.confirmationDialog`.
  - `errorMessage: String?` drives the `.alert`.
- **Toolbar**: `Quit` and `Force Quit` buttons; `.disabled` unless the selected row exists and
  `canTerminate`.
- **Context menu**: `.contextMenu(forSelectionType: pid_t.self)` providing the same two actions
  for the targeted row.
- Choosing an action sets `pendingTermination`; confirming calls `model.terminate(...)`; a
  non-`.success` result sets `errorMessage`.

## Data Flow (one termination)

1. User picks Quit/Force Quit (toolbar or context menu) for a row.
2. View sets `pendingTermination(pid, name, force)` → `.confirmationDialog` appears.
3. On confirm, view calls `model.terminate(pid:force:)`.
4. Model calls `terminator.terminate(pid:force:)` → `kill(pid, SIGTERM|SIGKILL)`.
5. `.success` → nothing else to do; the process drops off the next ~1 Hz refresh.
   Otherwise → view sets `errorMessage` → `.alert` explains why.

## Error Handling

- **`denied` (EPERM):** "Couldn't quit <name>: permission denied." (Should be rare due to the
  `canTerminate` gate; possible on a perms race.)
- **`noSuchProcess` (ESRCH):** "<name> is no longer running." (Process exited between render
  and click.)
- **`failure(errno text):** show the `strerror` message.
- The `canTerminate` gate disables actions for rows we know we can't signal, preventing most
  dead-end clicks up front.

## Testing Strategy

- **`ProcessTerminator`** (integration, real syscalls):
  - Spawn a child `/bin/sleep 60` via `Foundation.Process`; `terminate(pid:force:false)`;
    assert the child terminates (e.g. process is no longer running / wait returns).
  - `terminate(pid: 1, force: false)` (launchd, root) → `.denied`.
  - Terminate an already-reaped PID → `.noSuchProcess`.
- **`ProcessListModel`** (unit): inject a fake `ProcessTerminating`; assert `terminate(force:)`
  forwards the correct `force` flag and returns the terminator's result unchanged.
- **`ContentView`** (manual verification): spawn a throwaway process, Quit and Force-Quit it
  from the app; confirm the dialog appears, the process disappears, and the actions are disabled
  on a "—" (denied) row.

## Open Questions

None blocking.
