# macOSmonitor — System Vitals Header Design (Milestone 7)

**Date:** 2026-07-06
**Status:** Approved for implementation planning
**Author:** Peter Jones (with Claude)

## Context

Milestones 1–6 shipped a process-focused dashboard (table, termination, inspector with details,
CPU Time, and ports; search). This milestone adds a system-wide vitals header — the first slice
of the long-shelved "system vitals gauges" anchor — bringing in the third originally-named
technology, the **`ProcessInfo` class**, plus Mach host-stats for live CPU and memory.

## Goal & Success Criteria

A full-width header bar above the table showing CPU%, memory used/total, core count, thermal
state, Low Power Mode, uptime, and OS version — CPU% and memory updating live each ~1 Hz tick.

**Success = the header shows values that roughly match Activity Monitor / `top` (CPU% and used
memory in the right ballpark); CPU% and memory move live (a CPU burner pushes CPU% up); and
thermal/uptime/OS are correct.**

## Scope

**In scope (Milestone 7):**
- A full-width header bar above the process table.
- **CPU usage %** (aggregate, live) via `host_processor_info` tick deltas.
- **Memory used / total** (live) via `host_statistics64` + `ProcessInfo.physicalMemory`.
- **Cores** (active/total), **Thermal state**, **Low Power Mode**, **Uptime**, **OS version** via `ProcessInfo`.
- Live refresh of the dynamic values each ~1 Hz tick (folded into the existing loop).

**Out of scope (documented future work — each its own later milestone):**
- **GPU** utilization/memory.
- **Disk I/O** (read/write throughput).
- **Network** throughput (aggregate up/down).
- **Battery** (charge, time remaining, wattage).
- Memory *pressure* gauge, swap usage, per-core CPU breakdown, historical sparklines.

## Key Decisions

- **Go big** — `ProcessInfo` facts *and* live Mach host-stats (CPU% + memory), one cohesive header.
- **Host CPU% is self-normalizing** — host CPU ticks are cumulative; `CPU% = 100 × Δbusy / Δtotal`
  (`total = busy + idle`). The tick deltas encode elapsed time, so **no wall clock is needed**
  (unlike per-process CPU%). First tick (no baseline) → 0%.
- **"Memory used" = (active + wired + compressed) × page size** — approximates Activity Monitor's
  "Memory Used" (excludes free/purgeable/cached). Total = `ProcessInfo.physicalMemory`.
- **Mach syscalls isolated** behind `HostStatsProviding` (implemented by `HostStats`), same pattern
  as `ProcInfo`/`ProcessPortProviding`. `ProcessInfo` facts (trivial, no delta) are read directly
  in the sampler.
- **Stateful sampler as an actor** (`SystemVitalsSampler`) holding the previous CPU ticks and
  running off-main, mirroring `ProcessSampler`.
- **Layout: full-width header bar above the table** (chosen over toolbar-embedding or a panel).

## Architecture

New file `SystemVitals.swift` (value type + host shim + sampler); a new `SystemVitalsView`; small
additions to `ProcessListModel` and `ContentView`.

### `SystemVitals` value type

```swift
struct SystemVitals: Equatable, Sendable {
    let cpuUsagePercent: Double
    let usedMemoryBytes: UInt64
    let totalMemoryBytes: UInt64
    let coreCount: Int
    let activeCoreCount: Int
    let thermalState: String     // "Nominal"/"Fair"/"Serious"/"Critical"
    let lowPowerMode: Bool
    let uptime: TimeInterval
    let osVersion: String        // e.g. "macOS 26.5"

    // Display computeds:
    var cpuText: String          // "CPU 34%"
    var memoryText: String       // "12.3 / 32 GB"
    var coresText: String        // "10 cores"
    var uptimeText: String       // "up 3d 4h"
    // thermalState / osVersion shown directly; Low Power shown only when true.
}
```

### Host stats shim

```swift
protocol HostStatsProviding: Sendable {
    func cpuTicks() -> (busy: UInt64, total: UInt64)?   // aggregate across cores
    func memory() -> (used: UInt64, total: UInt64)?
}

struct HostStats: HostStatsProviding { … }  // host_processor_info + host_statistics64
```

`cpuTicks()`: `host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, …)` → per-core
`cpu_load_info` (USER/SYSTEM/IDLE/NICE ticks); sum `busy = user+system+nice`, `total = busy+idle`;
`vm_deallocate` the returned array. `memory()`: `host_statistics64(mach_host_self(), HOST_VM_INFO64,
&vm_statistics64, …)` → `used = (active + wired + compressed) × pageSize`, `total =
ProcessInfo.processInfo.physicalMemory`. Returns `nil` on host-call failure.

### Sampler

```swift
protocol SystemVitalsSampling: Sendable { func sample() async -> SystemVitals }

actor SystemVitalsSampler: SystemVitalsSampling {
    init(host: any HostStatsProviding = HostStats())
    // holds previous (busy,total) ticks; sample() diffs for CPU%, reads memory + ProcessInfo facts.
}
```

CPU%: if a previous tick snapshot exists and `Δtotal > 0`, `cpu = 100 × Δbusy / Δtotal`, else 0.
ProcessInfo facts read directly: `physicalMemory`, `processorCount`/`activeProcessorCount`,
`thermalState`, `isLowPowerModeEnabled`, `systemUptime`, `operatingSystemVersion`.

### Model (`ProcessListModel`)

- Add `private(set) var vitals: SystemVitals?`.
- Inject `vitalsSampler: any SystemVitalsSampling = SystemVitalsSampler()`.
- In `refreshOnce()`, after `rows = await sampler.sample()` and `refreshSelection()`:
  `vitals = await vitalsSampler.sample()`.

### UI

- **`SystemVitalsView`** — takes `vitals: SystemVitals?`; an `HStack` of labeled stat items
  (CPU / Mem / Cores / Thermal / Low Power (only when on) / Uptime / OS), monospaced numbers;
  `nil` → dash placeholders (brief, first tick only). Fixed-height bar with padding + background.
- **`ContentView`** — wrap the table in `VStack(spacing: 0) { SystemVitalsView(vitals: model.vitals); Divider(); <table> }`.
  `.contextMenu(forSelectionType:)` stays on the table; window-level modifiers (`.toolbar`,
  `.searchable`, `.focusedSceneValue`, `.inspector`, `.confirmationDialog`, `.alert`, `.task`,
  `.onChange`, `.navigationTitle`, `.frame`) move onto the `VStack`.

## Data Flow

1. Each ~1 Hz tick, `refreshOnce()` also calls `await vitalsSampler.sample()`.
2. The sampler reads host CPU ticks (diffs vs previous for CPU%), memory, and `ProcessInfo` facts,
   returning a `SystemVitals`; the model publishes `vitals`.
3. `SystemVitalsView` (observing the model) re-renders the header live.

## Error Handling

- Host call failure → that field 0 / "—"; never crashes.
- First tick: no CPU baseline → 0% (self-corrects next tick).
- `vitals == nil` before the first sample → header shows dash placeholders.

## Testing Strategy

- **`HostStats`** (integration): `cpuTicks()?.total > 0`; `memory()?.total == ProcessInfo.processInfo.physicalMemory`
  and `0 < used < total`.
- **`SystemVitalsSampler`** (unit): inject a fake `HostStatsProviding` with scripted two-tick ticks —
  first tick → `cpuUsagePercent == 0`; second tick (busy +50, total +100) → `cpuUsagePercent == 50`.
  Memory passes through from the fake.
- **`SystemVitals` formatting** (unit): `cpuText`/`memoryText`/`coresText`/`uptimeText` produce their
  exact strings for representative inputs.
- **`ProcessListModel`** (unit): inject a fake vitals sampler → `vitals` published after `refreshOnce()`.
- **Manual verification:** header values roughly match Activity Monitor / `top`; CPU% and memory move
  live; a `yes` burner raises CPU%; thermal/uptime/OS/cores correct.

## Open Questions

None blocking. (Mach struct/const specifics — `cpu_load_info` layout, `vm_statistics64` fields,
`HOST_VM_INFO64_COUNT`, page size, `vm_deallocate` — are a planning-time empirical check.)
