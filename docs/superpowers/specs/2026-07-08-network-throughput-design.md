# macOSmonitor — Network Throughput Design (Milestone 8)

**Date:** 2026-07-08
**Status:** Approved for implementation planning
**Author:** Peter Jones (with Claude)

## Context

Milestone 7 added a live system-vitals header (CPU / Memory / Thermal / Uptime), built to leave
room for the deferred vitals: GPU, disk I/O, network throughput, battery. Those are four
independent subsystems, each its own milestone. This is the **first of the four — network
throughput** — chosen for being dynamic, moderate complexity, and reusing our rate-delta pattern
without IOKit.

## Goal & Success Criteria

A **Network** item in the vitals header showing aggregate **↓ received / ↑ sent** throughput
(bytes/sec) across non-loopback interfaces, updating live each ~1 Hz tick.

**Success = the header shows a Network item that reads near zero when idle and visibly spikes on
↓ when downloading (and ↑ when uploading), in the right ballpark vs Activity Monitor's Network
tab or `nettop`.**

## Scope

**In scope (Milestone 8):**
- A **Network** header item: aggregate **↓ received** and **↑ sent** rates (bytes/sec).
- Summed across all real interfaces, **excluding loopback** (`lo0`).
- Live each ~1 Hz tick; rate = Δbytes / Δwall-seconds.
- Adaptive byte-rate formatting (B/s, KB/s, MB/s).

**Out of scope (documented — later milestones/panels):**
- Per-interface breakdown (Wi-Fi vs Ethernet), or a network panel.
- Per-process network usage.
- Packet counts, errors, connection lists (that's the Ports inspector, already shipped).
- The other deferred vitals: **battery, disk I/O, GPU** (each its own later milestone).

## Key Decisions

- **Aggregate ↓/↑, loopback excluded** — the at-a-glance "how much is my machine talking to the
  network" number; loopback (`lo0`) is internal traffic that would inflate it.
- **Rate needs a wall clock** — interface counters are cumulative totals, so rate = Δbytes / Δwall.
  Unlike host CPU% (self-normalizing), the sampler must divide by elapsed time. A `now` clock is
  injected into `SystemVitalsSampler` for testability. First tick → 0 (no baseline).
- **Syscall isolated** behind `NetworkStatsProviding` (implemented by `NetworkStats`), same pattern
  as `HostStats`/`ProcInfo`.
- **Folded into the existing vitals** — network rates become fields on `SystemVitals`, assembled by
  `SystemVitalsSampler`, shown as another `SystemVitalsView` column. One cohesive header.
- **Defensive delta** — if `getifaddrs` fails, or Δbytes goes negative (counter wrap / interface
  reset), that tick's rate is 0 (mirrors the CPU-tick wraparound guard).

## Architecture

New shim in a new file `NetworkStats.swift`; additions to `SystemVitals`, `SystemVitalsSampler`,
`SystemVitalsView`.

### `NetworkStats.swift`

```swift
protocol NetworkStatsProviding: Sendable {
    /// Cumulative bytes received/sent across all non-loopback interfaces; nil on failure.
    func counters() -> (received: UInt64, sent: UInt64)?
}

struct NetworkStats: NetworkStatsProviding { … }  // getifaddrs + if_data
```

`counters()`: `getifaddrs`; iterate the linked list; for `AF_LINK` entries whose flags lack
`IFF_LOOPBACK`, read `if_data` (`ifi_ibytes`/`ifi_obytes`) and sum; `freeifaddrs`. Returns `nil` on
`getifaddrs` failure.

### `SystemVitals` additions

```swift
let networkInBytesPerSec: Double
let networkOutBytesPerSec: Double

var networkText: String   // "↓ 1.2 MB/s  ↑ 340 KB/s" (adaptive units via ByteCountFormatter + "/s")
```

### `SystemVitalsSampler` changes

- Inject `network: any NetworkStatsProviding = NetworkStats()` and
  `now: @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }`.
- Hold `previousCounters: (received: UInt64, sent: UInt64)?` and `previousTime: UInt64?`.
- Each `sample()`: read `counters()`; if a previous snapshot exists and Δtime > 0 and Δbytes ≥ 0,
  `rate = Double(Δbytes) / (Δnanos / 1e9)`, else 0; store the new snapshot; add both rates to the
  returned `SystemVitals`. (CPU%/memory/`ProcessInfo` logic unchanged.)

### `SystemVitalsView`

- Add a **"Network"** item (equal-width column) showing `vitals?.networkText`.

## Data Flow

1. Each ~1 Hz tick, `SystemVitalsSampler.sample()` reads cumulative interface counters and the
   clock, computes ↓/↑ rates from the deltas, and includes them in the `SystemVitals`.
2. The model publishes `vitals`; `SystemVitalsView` renders the Network column live.

## Error Handling

- `getifaddrs` failure → `counters()` nil → rates 0 that tick.
- First tick / Δtime == 0 → 0.
- Δbytes < 0 (wrap / interface reset) → 0 that tick (defensive).

## Testing Strategy

- **`NetworkStats`** (integration): `counters()` is non-nil; a second call's `received`/`sent` are
  each **≥** the first call's (cumulative counters are monotonic within a run).
- **`SystemVitalsSampler`** (unit): inject a fake `NetworkStatsProviding` + a controllable `now`
  clock — first tick → `networkInBytesPerSec == 0`; second tick (received +1_000_000 over +1.0 s) →
  `networkInBytesPerSec == 1_000_000`; a Δbytes-negative tick → 0.
- **`SystemVitals.networkText`** (unit): representative rates format to their exact strings.
- **Manual verification:** the header shows a Network item; start a download → ↓ spikes and moves
  live, ↑ moves on upload; idle → near 0; ballpark-match Activity Monitor's Network tab.

## Open Questions

None blocking. (`getifaddrs`/`if_data` struct specifics and the loopback-flag check are a
planning-time empirical probe.)
