# Battery Vital (Milestone 9) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Battery item (charge % + state + time remaining) to the vitals header, shown only when a battery is present.

**Architecture:** A `BatteryInfo` value type + `BatteryStats` shim (IOKit `IOPowerSources`, `nil` on no battery) behind `BatteryStatsProviding`; an optional `battery` field on `SystemVitals`; `SystemVitalsSampler` reads it each tick; `SystemVitalsView` shows a conditional Battery column.

**Tech Stack:** Swift, SwiftUI, IOKit `IOKit.ps`, Swift Testing, Xcode 26.

## Global Constraints

- **Platform / project:** existing `macOSmonitor` macOS app, non-sandboxed, `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated`. Test import: `@testable import macOSmonitor`.
- **Build:** `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' build`
- **Test:** `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test` (MUST scope to `macOSmonitorTests`; the UI-test target times out under CLI).
- **Verified IOKit facts (do not re-derive):** `import IOKit.ps`. `IOPSCopyPowerSourcesInfo().takeRetainedValue()` → snapshot; `IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [CFTypeRef]` (plain `as`, not `as?`); per source `IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any]`. Keys: `kIOPSCurrentCapacityKey` (Int), `kIOPSMaxCapacityKey` (Int, usually 100), `kIOPSIsChargingKey` (Bool), `kIOPSPowerSourceStateKey` (String; compare to `kIOPSACPowerValue` = "AC Power"), `kIOPSTimeToEmptyKey` (Int), `kIOPSTimeToFullChargeKey` (Int — NOT `kIOPSTimeToFullKey`). Time values ≤ 0 mean "not available" → `nil`.
- **SourceKit** "No such module 'Testing'" / "Cannot find type" diagnostics are indexer lag — trust `xcodebuild` only.

---

### Task 1: `BatteryInfo` value type + `displayText`

**Files:**
- Create: `macOSmonitor/BatteryInfo.swift`
- Test: `macOSmonitorTests/BatteryInfoTests.swift`

**Interfaces:**
- Produces:
  - `struct BatteryInfo: Equatable, Sendable { enum State { case charging, discharging, charged, ac }; let chargePercent: Int; let state: State; let timeRemainingMinutes: Int? }` + `var displayText: String`.
  - `protocol BatteryStatsProviding: Sendable { func read() -> BatteryInfo? }`.

- [ ] **Step 1: Write the failing tests**

Create `macOSmonitorTests/BatteryInfoTests.swift`:

```swift
import Testing
@testable import macOSmonitor

struct BatteryInfoTests {
    @Test func dischargingWithTime() {
        let b = BatteryInfo(chargePercent: 84, state: .discharging, timeRemainingMinutes: 197)
        #expect(b.displayText == "84% · 3:17")
    }

    @Test func chargingWithTime() {
        let b = BatteryInfo(chargePercent: 84, state: .charging, timeRemainingMinutes: 80)
        #expect(b.displayText == "84% ⚡ 1:20")
    }

    @Test func chargedShowsBolt() {
        let b = BatteryInfo(chargePercent: 100, state: .charged, timeRemainingMinutes: nil)
        #expect(b.displayText == "100% ⚡")
    }

    @Test func acHoldingShowsBolt() {
        let b = BatteryInfo(chargePercent: 80, state: .ac, timeRemainingMinutes: nil)
        #expect(b.displayText == "80% ⚡")
    }

    @Test func dischargingCalculatingHidesTime() {
        let b = BatteryInfo(chargePercent: 84, state: .discharging, timeRemainingMinutes: nil)
        #expect(b.displayText == "84%")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests build-for-testing 2>&1 | grep -iE 'error:|cannot find'`
Expected: FAIL — `cannot find 'BatteryInfo' in scope`.

- [ ] **Step 3: Implement**

Create `macOSmonitor/BatteryInfo.swift`:

```swift
import Foundation

/// A snapshot of battery state for the vitals header.
struct BatteryInfo: Equatable, Sendable {
    enum State: Equatable, Sendable { case charging, discharging, charged, ac }

    let chargePercent: Int
    let state: State
    let timeRemainingMinutes: Int?   // nil when the estimate is unavailable/calculating

    /// e.g. "84% · 3:17" (discharging), "84% ⚡ 1:20" (charging), "100% ⚡" (charged/AC), "84%" (calculating).
    var displayText: String {
        let pct = "\(chargePercent)%"
        switch state {
        case .charging:
            return timeRemainingMinutes.map { "\(pct) ⚡ \(Self.time($0))" } ?? "\(pct) ⚡"
        case .discharging:
            return timeRemainingMinutes.map { "\(pct) · \(Self.time($0))" } ?? pct
        case .charged, .ac:
            return "\(pct) ⚡"
        }
    }

    private static func time(_ minutes: Int) -> String {
        String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}

/// Reads battery state, isolated behind a protocol so the sampler can use a fake.
protocol BatteryStatsProviding: Sendable {
    func read() -> BatteryInfo?   // nil when no battery is present
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test 2>&1 | grep -iE 'BatteryInfoTests.*(passed|failed)|TEST (SUCCEEDED|FAILED)'`
Expected: `** TEST SUCCEEDED **`, all five format tests pass.

- [ ] **Step 5: Commit**

```bash
git add macOSmonitor/BatteryInfo.swift macOSmonitorTests/BatteryInfoTests.swift
git commit -m "feat: add BatteryInfo value type with displayText"
```

---

### Task 2: `BatteryStats` — IOKit power-source shim

**Files:**
- Modify: `macOSmonitor/BatteryInfo.swift` (append `BatteryStats`)
- Test: `macOSmonitorTests/BatteryStatsTests.swift`

**Interfaces:**
- Produces: `struct BatteryStats: BatteryStatsProviding` — reads the first power source via IOKit; `nil` when the source list is empty (no battery).

- [ ] **Step 1: Write the failing integration test**

Create `macOSmonitorTests/BatteryStatsTests.swift`:

```swift
import Testing
@testable import macOSmonitor

struct BatteryStatsTests {
    // This dev machine is a laptop with a battery.
    @Test func readsBatteryOnThisLaptop() {
        let info = BatteryStats().read()
        #expect(info != nil)
        let pct = info?.chargePercent ?? -1
        #expect(pct >= 0 && pct <= 100)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests build-for-testing 2>&1 | grep -iE 'error:|cannot find'`
Expected: FAIL — `cannot find 'BatteryStats' in scope`.

- [ ] **Step 3: Implement**

Append to `macOSmonitor/BatteryInfo.swift`:

```swift
import IOKit.ps

struct BatteryStats: BatteryStatsProviding {
    func read() -> BatteryInfo? {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [CFTypeRef]
        guard let first = sources.first,
              let desc = IOPSGetPowerSourceDescription(snapshot, first)?.takeUnretainedValue()
                as? [String: Any]
        else { return nil }

        let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
        let maxCapacity = desc[kIOPSMaxCapacityKey] as? Int ?? 100
        let percent = maxCapacity > 0
            ? Int((Double(current) / Double(maxCapacity) * 100).rounded())
            : current
        let isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
        let powerState = desc[kIOPSPowerSourceStateKey] as? String

        let state: BatteryInfo.State
        let minutes: Int?
        if isCharging {
            state = .charging
            let t = desc[kIOPSTimeToFullChargeKey] as? Int ?? -1
            minutes = t > 0 ? t : nil
        } else if powerState == kIOPSACPowerValue {
            state = percent >= 100 ? .charged : .ac
            minutes = nil
        } else {
            state = .discharging
            let t = desc[kIOPSTimeToEmptyKey] as? Int ?? -1
            minutes = t > 0 ? t : nil
        }
        return BatteryInfo(chargePercent: percent, state: state, timeRemainingMinutes: minutes)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test 2>&1 | grep -iE 'BatteryStatsTests.*(passed|failed)|TEST (SUCCEEDED|FAILED)'`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add macOSmonitor/BatteryInfo.swift macOSmonitorTests/BatteryStatsTests.swift
git commit -m "feat: add BatteryStats IOKit power-source shim"
```

---

### Task 3: `SystemVitals` + `SystemVitalsSampler` — publish battery

**Files:**
- Modify: `macOSmonitor/SystemVitals.swift`
- Modify: `macOSmonitor/SystemVitalsSampler.swift`
- Test: `macOSmonitorTests/SystemVitalsSamplerTests.swift` (add a fake + cases)

**Interfaces:**
- Consumes: `BatteryInfo`, `BatteryStatsProviding` (Tasks 1–2).
- Produces: `SystemVitals.battery: BatteryInfo?` (defaulted nil); `SystemVitalsSampler.init(host:network:battery:now:)` adds `battery: any BatteryStatsProviding = BatteryStats()`; `sample()` sets `battery = battery.read()`.

- [ ] **Step 1: Add the failing tests**

In `macOSmonitorTests/SystemVitalsSamplerTests.swift`, add this fake at file scope (after `FakeNetworkStats`):

```swift
final class FakeBatteryStats: BatteryStatsProviding, @unchecked Sendable {
    var info: BatteryInfo?
    func read() -> BatteryInfo? { info }
}
```

And add these tests inside `struct SystemVitalsSamplerTests`:

```swift
    @Test func vitalsPublishBatteryWhenPresent() async {
        let fake = FakeBatteryStats()
        fake.info = BatteryInfo(chargePercent: 84, state: .discharging, timeRemainingMinutes: 197)
        let sampler = SystemVitalsSampler(host: FakeHostStats(), network: FakeNetworkStats(),
                                          battery: fake)
        let v = await sampler.sample()
        #expect(v.battery == fake.info)
    }

    @Test func vitalsHaveNilBatteryWhenAbsent() async {
        let sampler = SystemVitalsSampler(host: FakeHostStats(), network: FakeNetworkStats(),
                                          battery: FakeBatteryStats())   // info stays nil
        let v = await sampler.sample()
        #expect(v.battery == nil)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests build-for-testing 2>&1 | grep -iE 'error:'`
Expected: FAIL — extra argument `battery` / no member `battery`.

- [ ] **Step 3: Implement**

(a) In `macOSmonitor/SystemVitals.swift`, add the stored property immediately after `networkOutBytesPerSec`:

```swift
    var battery: BatteryInfo? = nil
```

(b) In `macOSmonitor/SystemVitalsSampler.swift`, add the dependency after `network`:

```swift
    private let battery: any BatteryStatsProviding
```

and update the initializer to inject it (placed after `network`):

```swift
    init(host: any HostStatsProviding = HostStats(),
         network: any NetworkStatsProviding = NetworkStats(),
         battery: any BatteryStatsProviding = BatteryStats(),
         now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.host = host
        self.network = network
        self.battery = battery
        self.now = now
    }
```

(c) In `sample()`, read the battery just before building the `SystemVitals` (e.g. after the `let version = ...` line):

```swift
        let batteryInfo = battery.read()
```

and add the field to the `SystemVitals(...)` initializer call (after `networkOutBytesPerSec:`):

```swift
            networkOutBytesPerSec: networkOut,
            battery: batteryInfo
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test 2>&1 | grep -iE 'Battery.*(passed|failed)|TEST (SUCCEEDED|FAILED)'`
Expected: `** TEST SUCCEEDED **` — battery published when present, nil when absent; existing sampler tests still pass.

- [ ] **Step 5: Commit**

```bash
git add macOSmonitor/SystemVitals.swift macOSmonitor/SystemVitalsSampler.swift macOSmonitorTests/SystemVitalsSamplerTests.swift
git commit -m "feat: publish battery info from SystemVitalsSampler"
```

---

### Task 4: `SystemVitalsView` — conditional Battery item

**Files:**
- Modify: `macOSmonitor/SystemVitalsView.swift`

**Interfaces:**
- Consumes: `SystemVitals.battery` (Task 3), `BatteryInfo.displayText` (Task 1) via `model.vitals`.
- Produces: the Battery header column. No unit test (SwiftUI view); validated by build + manual verification.

- [ ] **Step 1: Add the conditional Battery item after Uptime**

In `macOSmonitor/SystemVitalsView.swift`, the item list currently ends:

```swift
            if vitals?.lowPowerMode == true { item("Power", "Low Power") }
            item("Uptime", vitals?.uptimeText)
```

Add the Battery item after Uptime (shown only when a battery is present):

```swift
            if vitals?.lowPowerMode == true { item("Power", "Low Power") }
            item("Uptime", vitals?.uptimeText)
            if let battery = vitals?.battery { item("Battery", battery.displayText) }
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' build 2>&1 | grep -iE 'error:|BUILD (SUCCEEDED|FAILED)'`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Run the full unit suite (nothing regressed)**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test 2>&1 | grep -E 'TEST (SUCCEEDED|FAILED)'`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Manual verification**

Launch the app (on this laptop). Verify:
- The header shows a **Battery** column (at the end) whose **%** matches the menu-bar battery.
- With the charger **plugged**: `⚡` (e.g. `80% ⚡` while holding, or `84% ⚡ 1:20` while charging to full).
- **Unplug** the charger → state flips to `·` with a **time-to-empty** (e.g. `84% · 3:17`); re-plug → back to `⚡`.
- The other vitals, table, search, inspector, and termination all still work.
- (Can't verify the no-battery case on a laptop; the item is guarded by `if let battery`, so a desktop simply omits it.)

- [ ] **Step 5: Commit**

```bash
git add macOSmonitor/SystemVitalsView.swift
git commit -m "feat: show battery in the vitals header"
```

---

## Definition of Done (Milestone 9)

- On a laptop, the vitals header shows a live Battery item (% + ⚡/· state + time) matching the menu bar; unplugging/plugging flips the state.
- On a battery-less Mac the item is omitted (guarded by `if let battery`).
- All unit + integration tests pass via `xcodebuild ... -only-testing:macOSmonitorTests test`.
- Each task committed separately.
