# macOSmonitor — Battery Vital Design (Milestone 9)

**Date:** 2026-07-08
**Status:** Approved for implementation planning
**Author:** Peter Jones (with Claude)

## Context

Milestone 7 added a live system-vitals header; Milestone 8 added Network throughput — the first of
the four deferred vitals (GPU, disk, network, battery). This is the **second — battery** — chosen
for being self-contained and tractable. The dev machine is a laptop with a battery (84%,
discharging, ~3:17 remaining), so live data is testable; the design must also handle battery-less
Macs (desktops) gracefully.

## Goal & Success Criteria

A **Battery** item in the vitals header (shown only when a battery is present) with **charge % +
charging state + time remaining**, live each ~1 Hz tick.

**Success = on a laptop the header shows a Battery item whose % matches the menu-bar battery and
whose state flips between discharging and charging when the charger is unplugged/plugged; on a
battery-less Mac the item is simply absent.**

## Scope

**In scope (Milestone 9):**
- A **Battery** header item, **conditional** on a battery being present (omitted otherwise).
- Charge %, charging state (charging / discharging / charged / on-AC), and time remaining.
- Live each ~1 Hz tick (snapshot read — no rate/clock).

**Out of scope (documented — later):**
- Battery **health** (cycle count, condition, max-capacity %) — static reference; belongs in a
  future battery-detail view (inspector / About), not the live header.
- Per-app energy impact; power/wattage draw; charging history graphs.
- The remaining deferred vitals: **disk I/O, GPU** (each its own later milestone).

## Key Decisions

- **% + state + time** in the header (health deferred to a detail view).
- **Omit the item when no battery** (conditional, like the Low Power item) — clean, per-machine.
- **Snapshot read, no clock** — battery is a level, not a rate; simpler than Network.
- **IOKit `IOPowerSources`** (`IOPSCopyPowerSourcesInfo` / `IOPSCopyPowerSourcesList`) — no root.
- **Syscall/API isolated** behind `BatteryStatsProviding` (implemented by `BatteryStats`), same
  pattern as `HostStats`/`NetworkStats`.
- **`⚡`/`·` glyphs** in the value text (charging vs discharging), confirmed with the user.

## Architecture

New file `BatteryInfo.swift` (value type + shim); additions to `SystemVitals`, `SystemVitalsSampler`,
`SystemVitalsView`.

### `BatteryInfo.swift`

```swift
struct BatteryInfo: Equatable, Sendable {
    enum State: Equatable, Sendable { case charging, discharging, charged, ac }
    let chargePercent: Int
    let state: State
    let timeRemainingMinutes: Int?   // nil when the estimate is still calculating (-1)

    var displayText: String { … }    // "84% · 3:17", "84% ⚡ 1:20", "100% ⚡", "84%"
}

protocol BatteryStatsProviding: Sendable {
    func read() -> BatteryInfo?      // nil when no battery is present
}

struct BatteryStats: BatteryStatsProviding { … }  // IOKit IOPowerSources
```

`BatteryStats.read()`: `IOPSCopyPowerSourcesInfo()` → `IOPSCopyPowerSourcesList()`; if the list is
empty → `nil`. Otherwise take the first source's description dict (`IOPSGetPowerSourceDescription`)
and read: `kIOPSCurrentCapacityKey` (%), `kIOPSMaxCapacityKey` (usually 100), `kIOPSIsChargingKey`
(Bool), `kIOPSPowerSourceStateKey` (`"AC Power"`/`"Battery Power"`), `kIOPSTimeToEmptyKey` /
`kIOPSTimeToFullKey` (minutes, `-1` when calculating). Manage the CF `Unmanaged` returns correctly.

### State derivation

- `isCharging` → `.charging`, `timeRemainingMinutes` from `TimeToFull` (nil if `-1`).
- else on `"AC Power"`: `.charged` if ~100%, else `.ac`; `timeRemainingMinutes = nil`.
- else (`"Battery Power"`) → `.discharging`, `timeRemainingMinutes` from `TimeToEmpty` (nil if `-1`).

### `displayText`

- `.charging`: `"\(pct)% ⚡ \(H:MM)"`, or `"\(pct)% ⚡"` when time is nil.
- `.discharging`: `"\(pct)% · \(H:MM)"`, or `"\(pct)%"` when time is nil.
- `.charged` / `.ac`: `"\(pct)% ⚡"`.

Time: `String(format: "%d:%02d", m / 60, m % 60)` (197 → `"3:17"`).

### `SystemVitals` / `SystemVitalsSampler` / `SystemVitalsView`

- `SystemVitals` gains `var battery: BatteryInfo? = nil`.
- `SystemVitalsSampler` injects `battery: any BatteryStatsProviding = BatteryStats()`; each
  `sample()` sets the returned `SystemVitals`'s `battery = battery.read()`.
- `SystemVitalsView` adds a conditional item at the end: `if let battery = vitals?.battery {
  item("Battery", battery.displayText) }`.

## Data Flow

1. Each ~1 Hz tick, `SystemVitalsSampler.sample()` calls `battery.read()` → sets `SystemVitals.battery`.
2. The model publishes `vitals`; `SystemVitalsView` shows the Battery item when `battery != nil`.

## Error Handling

- No battery / API failure → `read()` nil → item omitted; no crash.
- `TimeTo… == -1` (calculating) → `timeRemainingMinutes` nil → shown without a time.

## Testing Strategy

- **`BatteryInfo.displayText`** (unit): charging-with-time → `"84% ⚡ 1:20"`; discharging-with-time →
  `"84% · 3:17"`; charged → `"100% ⚡"`; discharging with nil time → `"84%"`.
- **`BatteryStats`** (integration, this laptop): `read()` is non-nil; `chargePercent` in `0...100`.
- **`SystemVitalsSampler`** (unit): inject a fake `BatteryStatsProviding` returning a `BatteryInfo`
  → `vitals.battery` published; a fake returning nil → `vitals.battery == nil`.
- **Manual verification:** the header shows a Battery item matching the menu-bar %; unplug the
  charger → `·` + time-to-empty; plug it in → `⚡` (+ time-to-full); on a battery-less Mac the item
  is absent.

## Open Questions

None blocking. (The IOKit `IOPowerSources` CF-bridging specifics are a planning-time empirical probe
against the real battery.)
