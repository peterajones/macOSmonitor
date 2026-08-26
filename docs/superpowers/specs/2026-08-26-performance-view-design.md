# Milestone 10 — Performance View: history graphs, per-core CPU, themes, disk

**Date:** 2026-08-26
**Status:** Approved, ready for planning

## Motivation

The app currently presents every vital as an instantaneous number in a header bar.
A number without a trend answers "what is it now" but never "what just happened" —
which is the question a system monitor exists to answer.

The reference point is TMOG (<https://tmog.org>), a cross-platform system monitor by
Dave Plummer, who wrote the original Windows Task Manager. TMOG is macOS 13+
(Swift/AppKit), Windows (Win32) and Linux (Qt6) over a shared C++ core. Its macOS
build is free and closed-source.

We are not cloning TMOG. We are taking the part of it this project lacks — a
Performance surface with history graphs, per-core CPU detail, and themed display —
and building it in the idiom this codebase already uses.

**Explicitly not adopted:** TMOG's shared C++ core. That architecture exists to ship
three platforms at once. This is one Mac app; Swift value types behind protocol-isolated
providers stay the right call.

## Scope

In scope for this milestone:

- A Performance surface with four panels: CPU, Memory, Network, Disk
- 60 seconds of history per metric, sampled at 1 Hz
- Per-core CPU utilisation, as a right-click toggle on the CPU panel
- Five themes (System, VFD Green, VFD Amber, VFD Blue, Monochrome) with a picker
- A new disk I/O provider (IOKit), the milestone's only new data source

Out of scope, deferred to later milestones:

- P/E core labelling and per-core frequency (needs new `sysctl` work)
- Per-core history traces (the grid ships as instantaneous bars)
- Thermal sensor detail and Energy/watts panels
- GPU
- Theming the process table

## Architecture

### Data flow

```text
DiskStats ─┐
NetworkStats ─┤
HostStats (per-core) ─┼─→ SystemVitalsSampler (actor) ─→ SystemVitals (snapshot)
BatteryStats ─┘                                                │
                                                               ▼
                                          VitalsModel (@MainActor @Observable)
                                             │ current: SystemVitals
                                             │ history: VitalsHistory
                                             ▼
                              PerformanceView ─→ panels ─→ MetricGraph (Canvas)
```

`ProcessListModel` keeps its own independent ~1 Hz loop for processes. The two models
are siblings, owned by `ContentView`.

### Units

| Unit | Kind | Responsibility |
| --- | --- | --- |
| `MetricHistory` | new value type | One fixed-capacity ring buffer of `Double` |
| `VitalsHistory` | new value type | Six `MetricHistory` series; `append(_ vitals:)` fans a snapshot into all six |
| `MetricScale` | new pure function | Decides a graph's y-range (fixed vs autoscaled) |
| `Theme` | new value type | Colours + id; five instances |
| `DiskStats` / `DiskStatsProviding` | new provider | Cumulative disk byte counters via IOKit |
| `VitalsModel` | new observable model | Owns vitals sampler, current snapshot, history, 1 Hz loop |
| `MetricGraph` | new view | `Canvas` line/fill graph over a value window |
| `CoreGrid` | new view | Per-core utilisation bars |
| `PerformanceView` + 4 panels | new views | The Performance surface |
| `ProcessesView` | extracted view | Today's `ContentView` body, moved verbatim |
| `ContentView` | modified | Becomes a `NavigationSplitView` router |
| `HostStatsProviding` | modified | `cpuTicks()` returns per-core, not aggregate |
| `SystemVitals` | modified | Gains per-core and disk fields |
| `SystemVitalsSampler` | modified | Per-core deltas, disk rates |
| `ProcessListModel` | modified | Loses vitals sampling entirely |

## Detailed design

### `MetricHistory`

A ring buffer with a fixed capacity (60), holding `Double`.

Surface: `init(capacity:)`, `mutating func append(_:)`, `var values: [Double]`
(oldest → newest), `var capacity: Int`.

Appending beyond capacity evicts the oldest sample. `values` on an empty buffer is `[]`.

### `VitalsHistory`

Six series: `cpu`, `memoryUsed`, `networkIn`, `networkOut`, `diskRead`, `diskWrite`.

`mutating func append(_ vitals: SystemVitals)` appends the corresponding field to each
series, so all six stay index-aligned by construction. No clock, no syscalls, no SwiftUI.

Per-core values are deliberately **not** stored — six series is the storage budget at 1 Hz,
and the core grid reads fine as instantaneous bars.

All six series exist from phase 1. The two disk series simply carry zeros until phase 3
lands the provider, because `SystemVitals`'s disk fields default to 0. This is intended:
it keeps `VitalsHistory` from needing a shape change mid-milestone.

### `MetricScale`

A pure function returning the `ClosedRange<Double>` a graph should draw against:

- **CPU** — fixed `0...100`
- **Memory** — fixed `0...totalMemoryBytes`
- **Network / Disk rates** — autoscaled to the peak in the current window

Autoscaling imposes a **minimum ceiling of 100 KB/s**. Without a floor, an idle network
amplifies byte-level noise into a dramatic and meaningless mountain range. Each rate panel
labels its current scale so a peak is readable rather than merely tall.

Extracted from the view specifically so it can be unit-tested.

### Per-core CPU

`HostStats.cpuTicks()` already iterates every core via `host_processor_info`, then sums
and discards the detail. The protocol method is **replaced** (not supplemented) by a
per-core version returning `[(busy: UInt64, total: UInt64)]`; the sampler sums for the
aggregate.

Replacement rather than addition matters: keeping both would mean two `host_processor_info`
calls per tick — a wasted syscall, and two inconsistent snapshots of the same quantity.

The existing 32-bit tick-wraparound guard becomes genuinely per-core. Today it guards only
the summed counters, which can mask one core wrapping while the total still rises.

`SystemVitals` gains `perCoreUsagePercent: [Double]`.

### `MetricGraph`

A `Canvas` taking `values: [Double]`, a `ClosedRange<Double>`, and the theme. Draws grid
lines, a stroked path, and a soft fill beneath it.

**Newest sample pins to the right edge.** Sample *i* of *n* maps to
`x = width - (n - 1 - i) * step`, where `step` derives from **capacity** (60), not from `n`.
A half-full buffer therefore draws in the right half and grows leftward — Task Manager's
behaviour — rather than stretching 12 samples across the full width and lurching as it fills.

No `TimelineView`. At 1 Hz an ordinary `@Observable` change drives the redraw, and
immediate-mode `Canvas` is cheap enough to keep the monitor out of its own top-five.

### Navigation

`ContentView` becomes a single `NavigationSplitView`.

- **Sidebar:** `Processes`, then a Performance section listing CPU / Memory / Network / Disk,
  each row showing its live value and a small bar.
- **Detail:** switches on `enum Surface: Hashable { case processes, cpu, memory, network, disk }`.

Today's entire `ContentView` body — table, inspector, search, toolbar quit buttons,
confirmation dialogs — extracts **unchanged** into `ProcessesView`. This is a move, not a
rewrite. It takes a 163-line file owning five concerns down to a router.

**The vitals header stays on the Processes surface only.** Thermal / Uptime / Battery /
Low Power remain exactly where they are; Performance panels carry their own numbers. CPU
consequently appears in two places, the same way Task Manager's Processes tab keeps a
summary row. Thermal and Energy panels are a later milestone and should not have a home
invented for them now.

Because vitals now live in `VitalsModel`, `ProcessesView` takes **both** models: the
`ProcessListModel` it already needed, plus `VitalsModel` for the header it hosts.
`ContentView` owns both and passes them down.

### CPU panel core view

Per-core detail is a **right-click context-menu toggle** on the CPU panel — overall
utilisation vs. the per-core grid — mirroring Task Manager's "Logical processors" toggle.
Not both at once.

### Theme system

`Theme` carries `id`, `name`, graph line, graph fill, grid line, panel background,
primary text, secondary text, meter-on and meter-off colours.

Five instances: **System**, **VFD Green**, **VFD Amber**, **VFD Blue**, **Monochrome**.

System uses semantic colours (`.primary`, `.secondary`, `.accentColor`) and therefore tracks
light/dark natively. The four VFD themes are fixed dark palettes that deliberately ignore
system appearance — that is the point of them.

Distributed as a SwiftUI `Environment` key, `\.theme`. Panels and graphs read it; nothing
hardcodes a colour. Selection persists via `@AppStorage("themeID")`, chosen from a toolbar
`Menu`.

Scope is the Performance surface only. The process table keeps native styling; a themed
`Table` is a much larger fight than this milestone justifies.

### Disk provider

`DiskStatsProviding` is shaped identically to `NetworkStatsProviding`:

```swift
protocol DiskStatsProviding: Sendable {
    func counters() -> (read: UInt64, written: UInt64)?
}
```

Implementation matches `IOServiceMatching("IOBlockStorageDriver")`, reads the statistics
dictionary from each match, and sums bytes-read and bytes-written across drivers.

`SystemVitals` gains `diskReadBytesPerSec` / `diskWriteBytesPerSec` (defaulted to 0 so
existing construction sites keep compiling). The sampler computes rates from counter deltas
using the **existing injected `now` clock** — the same pattern as M8's network rates,
including the negative-delta guard.

**Verify the registry key names and dictionary structure empirically before writing code
against them**, as M6 and M9 did. IOKit CFDictionary access needs disciplined
`IOObjectRelease` on every matched service.

## Testing

Swift Testing, matching the existing fake-based style.

| Unit | Assertions |
| --- | --- |
| `MetricHistory` | eviction at capacity; `values` ordering; empty-buffer behaviour |
| `VitalsHistory` | one `append` populates all six series from a snapshot |
| `MetricScale` | fixed ranges pass through; autoscale tracks window peak; noise floor holds when idle |
| `SystemVitalsSampler` | per-core percentages from fake tick arrays; aggregate equals the sum; one core wrapping does not corrupt the others |
| `DiskStats` sampler | rate from fake counters + fake clock; negative-delta guard — mirrors the M8 network tests |
| `DiskStats` (real hardware) | smoke test: counters non-nil and monotonic across two reads |
| `Theme` | five distinct ids; text-on-background contrast ratio computed and asserted ≥ 4.5:1 for each |

Existing `SystemVitalsSamplerTests` assertions on `ProcessListModel.vitals` move to
`VitalsModel` tests.

Run with:

```sh
xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor \
  -destination 'platform=macOS' -only-testing:macOSmonitorTests test
```

## Phasing

Each phase is independently shippable.

1. **Shell + history + three panels.** `MetricHistory`, `VitalsHistory`, `MetricScale`,
   `MetricGraph`, per-core `HostStats`, `CoreGrid`, `VitalsModel`, the split-view refactor,
   `ProcessesView` extraction, CPU / Memory / Network panels. No new syscalls.
2. **Themes.** `Theme`, five looks, environment key, `@AppStorage` persistence, toolbar picker,
   panels adopt the theme.
3. **Disk.** `DiskStats` provider, `SystemVitals` disk fields, sampler wiring, Disk panel,
   sidebar item.

## Risks

- **IOKit disk statistics** is the only genuine unknown. Nested CFDictionary access and
  release discipline; verify structure empirically first.
- **The split-view refactor is a behaviour risk, not a design risk.** Two things must be
  verified by running rather than by reasoning: `.searchable` placement inside a
  `NavigationSplitView`, and whether the M4 ⌘F `focusedSceneValue` wiring survives
  re-parenting.
- **Bug A may resurface.** The non-reproducible selection-highlight-identity glitch is
  exactly the class of problem that re-parenting a `Table` can wake up. Watch for it during
  phase 1; if it reproduces, that is valuable — it has never been reproducible before.

## Decisions recorded

- Approach B (dedicated history value types + `VitalsModel`) over history inside
  `ProcessListModel`, and over per-metric history streams.
- `Canvas` over Swift Charts: a 60-point sliding window redrawn each second is what
  immediate-mode drawing is for, and the theme *is* the stroke colour.
- One `NavigationSplitView` over tabs-plus-sidebar: same information, one less nesting level,
  more Mac-native.
- 1 Hz sampling, 60-sample window, reusing the existing tick cadence. Sample rate and render
  rate are independent; raising the former later does not touch the graph code.
- Theme plumbing and all five looks ship together in phase 2 rather than being retrofitted.
