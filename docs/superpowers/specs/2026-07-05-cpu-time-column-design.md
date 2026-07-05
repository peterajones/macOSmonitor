# macOSmonitor — CPU Time Column Design (Milestone 5)

**Date:** 2026-07-05
**Status:** Approved for implementation planning
**Author:** Peter Jones (with Claude)

## Context

Milestones 1–4 shipped a live process table (with termination, a detail inspector, and
search/filter). This milestone adds a **CPU Time** column showing each process's cumulative
CPU consumption. It is the first half of a two-part request; **Ports** (enumerating a process's
open sockets) is deferred to its own later milestone because it is a substantially larger
subsystem (new syscalls, variable-length per process, permission-limited).

## Goal & Success Criteria

Add a sortable **CPU Time** column (cumulative user+system CPU time since launch) immediately
after the CPU % column, echoed in the inspector, formatted like Activity Monitor.

**Success = each process shows a CPU Time that climbs over its lifetime, matching Activity
Monitor's CPU Time column in the same ballpark; the column sorts; denied processes show `—`;
and CPU Time also appears in the inspector.**

## Scope

**In scope (Milestone 5):**
- A **CPU Time** table column immediately after **CPU %**, sortable (descending like the others).
- Cumulative user+system CPU time, from data already fetched (no new syscalls).
- Adaptive format: `M:SS.ss` under an hour, `H:MM:SS` at/beyond an hour.
- CPU Time echoed in the inspector's Process section.
- `—` for processes we can't read (denied/exited), sorting to the bottom.

**Out of scope (documented for the future):**
- **Ports** (open sockets per process) — its own milestone.
- Per-thread CPU time, on-behalf-of / GPU time, or energy impact.
- Configurable time format or a live "CPU time rate" display.

## Key Decisions

- **Reuse existing data** — `ProcInfo.sample` already returns `ProcTaskSample.cpuTimeNanos`
  (cumulative user+system, already converted from Mach ticks to nanoseconds). The sampler uses
  it for the CPU% delta and currently discards the absolute; we carry the absolute onto the row.
  No new syscalls.
- **Adaptive format** (`M:SS.ss` / `H:MM:SS`), matching Activity Monitor.
- **New row property defaulted** — `cpuTimeNanos: UInt64? = nil` so existing constructors/tests
  keep compiling; only the sampler populates it.
- **Sortable via a non-optional sort key** — `cpuTimeSortKey = cpuTimeNanos ?? 0`, same pattern
  as `cpuSortKey`/`memSortKey`.
- **Shown in both** the table and the inspector.

## Architecture

Small deltas to existing units; no new files.

### `ProcessInfoRow` additions
```swift
var cpuTimeNanos: UInt64? = nil     // cumulative user+system CPU time; nil when unreadable

var cpuTimeText: String { /* adaptive format, or "—" when nil */ }
var cpuTimeSortKey: UInt64 { cpuTimeNanos ?? 0 }
```

### Format logic (`cpuTimeText`)
```
guard let nanos = cpuTimeNanos else { return "—" }
let seconds = Double(nanos) / 1_000_000_000
if seconds < 3600 {
    let minutes = Int(seconds) / 60
    let secs = seconds - Double(minutes * 60)
    return String(format: "%d:%05.2f", minutes, secs)   // e.g. "2:05.37", "0:03.03"
} else {
    let total = Int(seconds)
    return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60) // "1:23:45"
}
```

### `ProcessSampler`
In the owned-process branch (where `s` is the non-nil `ProcTaskSample`), pass
`cpuTimeNanos: s.cpuTimeNanos` when constructing the `ProcessInfoRow`. The denied branch leaves
it defaulted (`nil`). One-line change.

### `ProcessTableView` (in `ContentView`)
Add, immediately after the CPU % column:
```swift
TableColumn("CPU Time", value: \.cpuTimeSortKey) { row in
    Text(row.cpuTimeText).monospacedDigit()
}
```

### `ProcessDetailView`
Add to the Process section:
```swift
LabeledContent("CPU Time", value: row.cpuTimeText)
```

## Data Flow

1. Each ~1 Hz tick, `ProcInfo.sample(pid:)` returns `cpuTimeNanos` (cumulative).
2. `ProcessSampler` stores that absolute value on the owned row (in addition to computing the
   CPU% delta as before).
3. Table and inspector render `cpuTimeText`; the column sorts by `cpuTimeSortKey`.

## Error Handling

- Denied/exited process → `cpuTimeNanos` nil → `cpuTimeText` `"—"`, `cpuTimeSortKey` 0 (bottom on sort).
- Format never divides by zero and handles 0 ns (`"0:00.00"`).

## Testing Strategy

- **`ProcessInfoRow.cpuTimeText`** (unit): `nil → "—"`; `3.03s → "0:03.03"`; `125.37s → "2:05.37"`;
  `5025s → "1:23:45"` (hour boundary); `0 → "0:00.00"`.
- **`ProcessInfoRow.cpuTimeSortKey`** (unit): real value passes through; `nil → 0`.
- **`ProcessSampler`** (unit, extend existing tests): the owned row's `cpuTimeNanos` equals the
  injected fake sample's value; the denied row's `cpuTimeNanos` is nil.
- **Manual verification:** CPU Time column sits right after CPU %, values climb for busy processes
  and roughly match Activity Monitor's CPU Time, the column sorts, denied rows show `—`, and CPU
  Time appears in the inspector.

## Open Questions

None blocking.
