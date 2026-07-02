# macOSmonitor — Process Dashboard Design (Milestone 1)

**Date:** 2026-07-02
**Status:** Approved for implementation planning
**Author:** Peter Jones (with Claude)

## Context

First macOS project for the author (experienced iOS/SwiftUI developer). The app is a
daily-driver dashboard that monitors and controls macOS. This spec covers **Milestone 1**
only: a read-only live process table. It is the foundation the later milestones build on.

Named technologies of interest for the overall project: Endpoint Security Framework (ESF),
`proc_info`/`libproc`, and the `ProcessInfo` class. Milestone 1 uses **`proc_info`/`libproc`**
as its engine. `ProcessInfo` (the class) is reserved for a future system-vitals header. ESF
is reserved for a future activity/event feed and is out of scope here.

## Goal & Success Criteria

A **main-window SwiftUI macOS app** showing a live, sortable table of running processes,
auto-refreshing ~once per second. Milestone 1 is **read-only** (observation only — no
killing, no detail pane).

**Success = the displayed CPU% and memory figures visibly track Activity Monitor** when run
side-by-side.

## Scope

**In scope (Milestone 1):**

- Live process table with columns: **Name, PID, CPU%, Memory**.
- Auto-refresh at ~1 Hz.
- Click-to-sort on every column (ascending/descending).
- The current user's own processes get full CPU/memory detail.
- Processes owned by other users/root appear with **name + PID only** (CPU/memory blank) — see Decision A.
- Non-sandboxed; run locally from Xcode. No App Store distribution concerns yet.

**Out of scope (documented for the future):**

- Milestone 2: kill/quit a selected process (with confirmation) — teaches `kill()`/signals.
- Milestone 3: detail pane (path, parent PID, start time, thread count, …).
- Later: system-vitals header via the `ProcessInfo` class.
- Later: menu-bar surface.
- Later: **privileged XPC helper** (root, installed via `SMAppService`) for full detail on
  *all* processes, Activity-Monitor-style.
- Shelved product anchors from brainstorming: **(#2) system vitals gauges** (CPU/GPU/RAM/
  disk/network/thermals/battery), **(#3) ESF activity/event feed** (process/file/network
  events), **(#4) control panel** (toggle settings, manage login items, flush caches).

## Key Decisions

- **UI framework: SwiftUI** — carries over from the author's iOS experience; native `Table`
  with sortable columns is sufficient for a few hundred rows at ~1 Hz.
- **Form factor: main window app** — the table is the product.
- **Data engine: `proc_info`/`libproc`** — enumerate PIDs, pull per-process CPU time and
  resident memory.
- **Sampling architecture: actor-based off the main thread** (Approach A). Syscall-heavy
  enumeration runs on a background executor; the UI never blocks. CPU% requires diffing each
  process's CPU time against the previous tick, so the sampler holds state between ticks.
- **Privilege scope: current user, no elevation** — no privileged helper in M1.
- **Decision A — other users'/root processes on EPERM:** show the row with **name + PID**,
  leave CPU/memory blank. (Chosen over filtering them out entirely — more honest, closer to
  Activity Monitor, teaches partial-data handling.)

## Architecture

Four units, each independently understandable and testable, with the unsafe C surface
isolated to a single file.

```text
┌─────────────────────────────────────────────────────────┐
│  SwiftUI View layer                                      │
│   • ContentView  → Table(processes) with SortDescriptors │
└───────────────▲─────────────────────────────────────────┘
                │ observes  @Observable ProcessListModel
┌───────────────┴─────────────────────────────────────────┐
│  ProcessListModel  (@MainActor, @Observable)             │
│   • holds [ProcessInfoRow] for the UI                    │
│   • owns the refresh loop; asks the sampler each tick    │
└───────────────▲─────────────────────────────────────────┘
                │ await sampler.sample()
┌───────────────┴─────────────────────────────────────────┐
│  ProcessSampler  (actor)                                 │
│   • enumerates PIDs + pulls per-proc info via libproc    │
│   • stores previous CPU-time snapshot, computes CPU%     │
│   • returns [ProcessInfoRow]                             │
└───────────────▲─────────────────────────────────────────┘
                │ thin Swift wrappers over C APIs
┌───────────────┴─────────────────────────────────────────┐
│  ProcInfo (libproc/sysctl shim)                          │
│   • listPIDs(), taskInfo(pid), path(pid), name(pid)      │
│   • the ONLY file that touches raw C syscalls            │
└──────────────────────────────────────────────────────────┘
```

### Units

- **`ProcInfo`** — a thin, pure wrapper isolating every raw C syscall (`proc_listpids`,
  `proc_pidinfo` with `PROC_PIDTASKINFO`, `proc_pidpath`/`proc_name`). All unsafe code lives
  here. Handles buffer sizing; returns plain Swift structs / optionals. Behind a protocol so
  the sampler can be tested with a fake.
- **`ProcessSampler` (actor)** — the engine. Holds the previous CPU-time-per-PID map, calls
  `ProcInfo`, diffs, computes CPU% and resident memory, returns a finished `[ProcessInfoRow]`.
  No SwiftUI knowledge.
- **`ProcessListModel` (`@MainActor @Observable`)** — drives the ~1 s loop with a cancellable
  `Task`, awaits the sampler, publishes rows to the UI. Owns refresh interval and pause state.
- **View layer** — `Table` with clickable sortable columns bound to sort descriptors. Renders
  model state only.

## Data Model

```swift
struct ProcessInfoRow: Identifiable, Hashable {
    let id: pid_t           // PID (stable within a run)
    let pid: pid_t
    let name: String
    var cpuPercent: Double? // nil when detail is denied (EPERM) or not yet baselined
    var memoryBytes: UInt64? // resident size; nil when denied
    // Milestone 3 will add: path, ppid, startTime, threadCount…
}
```

`cpuPercent`/`memoryBytes` are optional so denied (EPERM) and not-yet-baselined states are
representable without sentinel values.

## Data Flow (one tick)

1. `ProcessListModel`'s loop fires (`Task.sleep(~1 s)` cadence).
2. `await sampler.sample()` runs the actor on a background executor.
3. Sampler: `listPIDs()` → for each PID, `taskInfo(pid)` (catch EPERM) → look up previous CPU
   time → `cpuPercent = (Δuser + Δsystem cpu-time) / Δwall-time × 100`.
4. Sampler stores this tick's snapshot as "previous"; returns rows.
5. Model assigns rows on the main actor → `Table` re-renders and re-applies the current sort.

## Error Handling

- **EPERM on other users' processes** → not an error. Emit the row with `name` + `pid` and
  `nil` CPU/memory (Decision A). Never crash.
- **Process exits mid-sample** → syscall returns 0/error for that PID; skip it silently.
  Expected churn.
- **First tick has no baseline** → CPU% is `nil`/0 for one tick until a delta exists.
- **Truncated/oversized libproc buffer** → `ProcInfo` sizes buffers correctly and returns
  `nil` rather than reading garbage.

## Testing Strategy

- **`ProcInfo`** (integration, against the live system): `listPIDs()` includes our own PID;
  `taskInfo(getpid())` returns non-zero memory. Syscalls aren't mockable, so test the real
  thing conservatively.
- **`ProcessSampler`** (unit, the core logic): inject a fake `ProcInfo` with scripted two-tick
  CPU-time values; assert the computed CPU% is correct. Also assert EPERM produces a
  name+PID-only row.
- **`ProcessListModel`** (unit): inject a fake sampler; assert the loop publishes rows and
  respects pause/cancel.
- **Manual verification:** run side-by-side with Activity Monitor; top CPU consumers and
  memory figures should track theirs.

## Open Questions

None blocking. Distribution/signing (sandbox, notarization) is deferred until we move beyond
running from Xcode.
