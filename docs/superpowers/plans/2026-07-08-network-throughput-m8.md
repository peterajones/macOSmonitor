# Network Throughput (Milestone 8) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a live Network item to the vitals header showing aggregate ↓ received / ↑ sent throughput.

**Architecture:** A `NetworkStats` shim (`getifaddrs` + `if_data`, loopback excluded) behind `NetworkStatsProviding`; two defaulted rate fields + a `networkText` computed on `SystemVitals`; `SystemVitalsSampler` gains an injected network provider + `now` clock and computes rates from byte-count deltas; `SystemVitalsView` shows a Network column.

**Tech Stack:** Swift, SwiftUI, `getifaddrs`/`if_data` via Darwin, Swift Testing, Xcode 26.

## Global Constraints

- **Platform / project:** existing `macOSmonitor` macOS app, non-sandboxed, `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated`. Test import: `@testable import macOSmonitor`.
- **Build:** `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' build`
- **Test:** `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test` (MUST scope to `macOSmonitorTests`; the UI-test target times out under CLI).
- **Verified facts (do not re-derive):** `getifaddrs(&ifap)` returns 0 on success; iterate `current.pointee.ifa_next`; an interface is `AF_LINK` when `current.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK)`; loopback when `current.pointee.ifa_flags & UInt32(IFF_LOOPBACK) != 0`; `if_data` via `current.pointee.ifa_data!.assumingMemoryBound(to: if_data.self).pointee` with `.ifi_ibytes`/`.ifi_obytes` (UInt32); `freeifaddrs(ifap)` to clean up. Counters are cumulative/monotonic; a real machine has GBs of traffic.
- **Rate needs a clock:** `rate = Δbytes / (Δnanos / 1e9)`; first tick / non-positive Δ / negative Δbytes → 0.
- **SourceKit** "No such module 'Testing'" / "Cannot find type" diagnostics are indexer lag — trust `xcodebuild` only.

---

### Task 1: `SystemVitals` — network rate fields + `networkText`

**Files:**
- Modify: `macOSmonitor/SystemVitals.swift`
- Test: `macOSmonitorTests/SystemVitalsTests.swift`

**Interfaces:**
- Produces on `SystemVitals`: `var networkInBytesPerSec: Double = 0`, `var networkOutBytesPerSec: Double = 0` (defaulted so existing construction sites still compile), and `var networkText: String`.

- [ ] **Step 1: Update the test helper and add the failing tests**

In `macOSmonitorTests/SystemVitalsTests.swift`, change the `make(...)` helper to accept and pass network rates:

```swift
    private func make(cpu: Double = 0, used: UInt64 = 0, total: UInt64 = 0,
                      cores: Int = 8, uptime: TimeInterval = 0,
                      netIn: Double = 0, netOut: Double = 0) -> SystemVitals {
        SystemVitals(cpuUsagePercent: cpu, usedMemoryBytes: used, totalMemoryBytes: total,
                     coreCount: cores, activeCoreCount: cores, thermalState: "Nominal",
                     lowPowerMode: false, uptime: uptime, osVersion: "macOS 26.5",
                     networkInBytesPerSec: netIn, networkOutBytesPerSec: netOut)
    }
```

And add these tests inside `struct SystemVitalsTests`:

```swift
    @Test func networkTextFormatsAdaptiveUnits() {
        #expect(make(netIn: 1_200_000, netOut: 340_000).networkText == "↓ 1.2 MB/s  ↑ 340 KB/s")
    }

    @Test func networkTextZero() {
        #expect(make(netIn: 0, netOut: 0).networkText == "↓ 0 B/s  ↑ 0 B/s")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests build-for-testing 2>&1 | grep -iE 'error:|has no member|extra argument'`
Expected: FAIL — `extra argument 'networkInBytesPerSec' in call` and `has no member 'networkText'`.

- [ ] **Step 3: Implement**

In `macOSmonitor/SystemVitals.swift`, add the two stored properties immediately after `osVersion`:

```swift
    var networkInBytesPerSec: Double = 0
    var networkOutBytesPerSec: Double = 0
```

And add the computed property + helper (after the existing `uptimeText`):

```swift
    /// e.g. "↓ 1.2 MB/s  ↑ 340 KB/s" (adaptive, decimal units).
    var networkText: String {
        "↓ \(SystemVitals.rate(networkInBytesPerSec))  ↑ \(SystemVitals.rate(networkOutBytesPerSec))"
    }

    private static func rate(_ bytesPerSec: Double) -> String {
        let b = max(0, bytesPerSec)
        if b < 1_000 { return String(format: "%.0f B/s", b) }
        if b < 1_000_000 { return String(format: "%.0f KB/s", b / 1_000) }
        if b < 1_000_000_000 { return String(format: "%.1f MB/s", b / 1_000_000) }
        return String(format: "%.1f GB/s", b / 1_000_000_000)
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test 2>&1 | grep -iE 'networkText.*(passed|failed)|TEST (SUCCEEDED|FAILED)'`
Expected: `** TEST SUCCEEDED **`, both network format tests pass; existing `SystemVitalsTests` still pass (network defaults to 0).

- [ ] **Step 5: Commit**

```bash
git add macOSmonitor/SystemVitals.swift macOSmonitorTests/SystemVitalsTests.swift
git commit -m "feat: add network rate fields and networkText to SystemVitals"
```

---

### Task 2: `NetworkStats` — interface byte-counter shim

**Files:**
- Create: `macOSmonitor/NetworkStats.swift`
- Test: `macOSmonitorTests/NetworkStatsTests.swift`

**Interfaces:**
- Produces:
  - `protocol NetworkStatsProviding: Sendable { func counters() -> (received: UInt64, sent: UInt64)? }`
  - `struct NetworkStats: NetworkStatsProviding` — sums non-loopback `if_data` byte counters; `nil` on `getifaddrs` failure.

- [ ] **Step 1: Write the failing integration test**

Create `macOSmonitorTests/NetworkStatsTests.swift`:

```swift
import Testing
@testable import macOSmonitor

struct NetworkStatsTests {
    @Test func countersArePresentAndPositive() {
        let counters = NetworkStats().counters()
        #expect(counters != nil)
        // A real machine has cumulative traffic on at least one non-loopback interface.
        #expect((counters.map { $0.received + $0.sent } ?? 0) > 0)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests build-for-testing 2>&1 | grep -iE 'error:|cannot find'`
Expected: FAIL — `cannot find 'NetworkStats' in scope`.

- [ ] **Step 3: Implement**

Create `macOSmonitor/NetworkStats.swift`:

```swift
import Darwin

/// Cumulative network byte counters, isolated behind a protocol so the sampler can use a fake.
protocol NetworkStatsProviding: Sendable {
    func counters() -> (received: UInt64, sent: UInt64)?
}

struct NetworkStats: NetworkStatsProviding {
    func counters() -> (received: UInt64, sent: UInt64)? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return nil }
        defer { freeifaddrs(ifap) }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        var pointer = ifap
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_LINK),
                  current.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let data = current.pointee.ifa_data
            else { continue }
            let info = data.assumingMemoryBound(to: if_data.self).pointee
            received += UInt64(info.ifi_ibytes)   // 32-bit counters summed into UInt64
            sent += UInt64(info.ifi_obytes)
        }
        return (received, sent)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test 2>&1 | grep -iE 'NetworkStatsTests.*(passed|failed)|TEST (SUCCEEDED|FAILED)'`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add macOSmonitor/NetworkStats.swift macOSmonitorTests/NetworkStatsTests.swift
git commit -m "feat: add NetworkStats shim summing non-loopback interface byte counters"
```

---

### Task 3: `SystemVitalsSampler` — compute network rates

**Files:**
- Modify: `macOSmonitor/SystemVitalsSampler.swift`
- Test: `macOSmonitorTests/SystemVitalsSamplerTests.swift` (add a fake + cases)

**Interfaces:**
- Consumes: `NetworkStatsProviding` (Task 2); `SystemVitals` network fields (Task 1).
- Produces: `SystemVitalsSampler.init(host:network:now:)` — adds `network: any NetworkStatsProviding = NetworkStats()` and `now: @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }`; `sample()` sets the two network rate fields from byte-count deltas over the clock.

- [ ] **Step 1: Add the failing tests**

In `macOSmonitorTests/SystemVitalsSamplerTests.swift`, add this fake at file scope (after `FakeHostStats`):

```swift
final class FakeNetworkStats: NetworkStatsProviding, @unchecked Sendable {
    var next: (received: UInt64, sent: UInt64)?
    func counters() -> (received: UInt64, sent: UInt64)? { next }
}
```

And add these tests inside `struct SystemVitalsSamplerTests`:

```swift
    @Test func networkRateFromDeltasOverClock() async {
        let net = FakeNetworkStats()
        var clock: UInt64 = 0
        let sampler = SystemVitalsSampler(host: FakeHostStats(), network: net, now: { clock })

        net.next = (received: 1_000, sent: 500)
        let first = await sampler.sample()
        #expect(first.networkInBytesPerSec == 0)          // no baseline

        clock = 1_000_000_000                             // +1.0 s
        net.next = (received: 1_001_000, sent: 340_500)   // +1_000_000 in / +340_000 out
        let second = await sampler.sample()
        #expect(second.networkInBytesPerSec == 1_000_000)
        #expect(second.networkOutBytesPerSec == 340_000)
    }

    @Test func networkRateZeroOnCounterDrop() async {
        let net = FakeNetworkStats()
        var clock: UInt64 = 0
        let sampler = SystemVitalsSampler(host: FakeHostStats(), network: net, now: { clock })

        net.next = (received: 5_000, sent: 5_000)
        _ = await sampler.sample()
        clock = 1_000_000_000
        net.next = (received: 1_000, sent: 1_000)          // counters dropped (wrap / iface reset)
        let s = await sampler.sample()
        #expect(s.networkInBytesPerSec == 0)
        #expect(s.networkOutBytesPerSec == 0)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests build-for-testing 2>&1 | grep -iE 'error:'`
Expected: FAIL — extra argument `network`/`now` in call.

- [ ] **Step 3: Update the sampler**

In `macOSmonitor/SystemVitalsSampler.swift`:

(a) Add the new stored properties (after `previousTicks`):

```swift
    private let network: any NetworkStatsProviding
    private let now: @Sendable () -> UInt64
    private var previousCounters: (received: UInt64, sent: UInt64)?
    private var previousTime: UInt64?
```

(b) Replace the initializer:

```swift
    init(host: any HostStatsProviding = HostStats(),
         network: any NetworkStatsProviding = NetworkStats(),
         now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.host = host
        self.network = network
        self.now = now
    }
```

(c) In `sample()`, compute the rates before building the `SystemVitals` (place after the CPU% block, before `let info = ProcessInfo.processInfo`):

```swift
        var networkIn = 0.0
        var networkOut = 0.0
        if let counters = network.counters() {
            let time = now()
            if let previous = previousCounters, let previousT = previousTime, time > previousT {
                let seconds = Double(time - previousT) / 1_000_000_000
                if seconds > 0 {
                    if counters.received >= previous.received {
                        networkIn = Double(counters.received - previous.received) / seconds
                    }
                    if counters.sent >= previous.sent {
                        networkOut = Double(counters.sent - previous.sent) / seconds
                    }
                }
            }
            previousCounters = counters
            previousTime = time
        }
```

(d) Add the two fields to the `SystemVitals(...)` initializer call (after `osVersion:`):

```swift
            osVersion: "macOS \(version.majorVersion).\(version.minorVersion)",
            networkInBytesPerSec: networkIn,
            networkOutBytesPerSec: networkOut
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test 2>&1 | grep -iE 'networkRate.*(passed|failed)|TEST (SUCCEEDED|FAILED)'`
Expected: `** TEST SUCCEEDED **` — first tick 0, second 1_000_000/340_000, counter-drop 0; existing sampler tests still pass.

- [ ] **Step 5: Commit**

```bash
git add macOSmonitor/SystemVitalsSampler.swift macOSmonitorTests/SystemVitalsSamplerTests.swift
git commit -m "feat: compute network throughput rates in SystemVitalsSampler"
```

---

### Task 4: `SystemVitalsView` — add the Network item

**Files:**
- Modify: `macOSmonitor/SystemVitalsView.swift`

**Interfaces:**
- Consumes: `SystemVitals.networkText` (Task 1) via `model.vitals`.
- Produces: the Network header column. No unit test (SwiftUI view); validated by build + manual verification.

- [ ] **Step 1: Add the Network item after Memory**

In `macOSmonitor/SystemVitalsView.swift`, the item list currently reads:

```swift
            item("CPU", vitals?.cpuText)
            item("Memory", vitals?.memoryText)
            item("Thermal", vitals?.thermalState)
```

Insert a Network item between Memory and Thermal:

```swift
            item("CPU", vitals?.cpuText)
            item("Memory", vitals?.memoryText)
            item("Network", vitals?.networkText)
            item("Thermal", vitals?.thermalState)
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' build 2>&1 | grep -iE 'error:|BUILD (SUCCEEDED|FAILED)'`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Run the full unit suite (nothing regressed)**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test 2>&1 | grep -E 'TEST (SUCCEEDED|FAILED)'`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Manual verification**

Launch the app. Verify:
- The header shows a **Network** column (between Memory and Thermal): `↓ … ↑ …`.
- **Idle** → both near `0 B/s` / small.
- Start a **download** (e.g. a large file in a browser, or `curl -o /dev/null <big-url>` in Terminal) → **↓ spikes** and moves live; it settles back near 0 when the download ends.
- Roughly ballpark-matches **Activity Monitor → Network** (data received/sent rate) or `nettop`.
- The other vitals, table, search, inspector, and termination all still work.

- [ ] **Step 5: Commit**

```bash
git add macOSmonitor/SystemVitalsView.swift
git commit -m "feat: show network throughput in the vitals header"
```

---

## Definition of Done (Milestone 8)

- The vitals header shows a live Network item (↓ received / ↑ sent) that spikes on transfer and idles near zero.
- Loopback is excluded; the rate handles first-tick, zero-Δtime, and counter-drop safely (0).
- All unit + integration tests pass via `xcodebuild ... -only-testing:macOSmonitorTests test`.
- Each task committed separately.
