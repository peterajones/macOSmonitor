# Ports (Open Sockets) Inspector (Milestone 6) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the selected process's open TCP/UDP sockets (protocol, local/remote addr:port, TCP state) in a live-updating Ports section of the inspector.

**Architecture:** A new `ProcessPort` value type + `ProcessPortProviding` protocol implemented by `ProcInfo` (isolating `PROC_PIDLISTFDS`/`PROC_PIDFDSOCKETINFO`); `ProcessListModel` gains `selectedPorts` and a `refreshSelection()` that fetches details+ports each tick; `ProcessDetailView` renders a Ports section.

**Tech Stack:** Swift, SwiftUI, `libproc` socket syscalls + `inet_ntop` via Darwin, Swift Testing, Xcode 26.

## Global Constraints

- **Platform / project:** existing `macOSmonitor` macOS app, non-sandboxed, `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated`. Test import: `@testable import macOSmonitor`.
- **Build:** `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' build`
- **Test:** `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test` (MUST scope to `macOSmonitorTests`; the UI-test target times out under CLI).
- **Verified syscall facts (do not re-derive):** `PROX_FDTYPE_SOCKET=2`, `SOCKINFO_TCP=2`, `SOCKINFO_IN=1`, `INI_IPV6=2`. Field access: `socket_fdinfo.psi` (`socket_info`) → `.soi_kind` (Int32), `.soi_proto.pri_tcp` (`tcp_sockinfo`: `.tcpsi_ini`, `.tcpsi_state` Int32), `.soi_proto.pri_in` (`in_sockinfo` for UDP). `in_sockinfo`: `.insi_lport`/`.insi_fport` (Int32, network byte order → `UInt16(bigEndian: UInt16(truncatingIfNeeded:))`), `.insi_vflag` (UInt8), `.insi_laddr`/`.insi_faddr` unions → IPv4 `.ina_46.i46a_addr4` (`in_addr`), IPv6 `.ina_6` (`in6_addr`). TCP state 1 = LISTEN.
- **SourceKit** "No such module 'Testing'" / "Cannot find type" diagnostics are known indexer lag — trust `xcodebuild` only.

---

### Task 1: `ProcessPort` value type + `displayText` + provider protocol

**Files:**
- Create: `macOSmonitor/ProcessPort.swift`
- Test: `macOSmonitorTests/ProcessPortTests.swift`

**Interfaces:**
- Produces:
  - `struct ProcessPort: Equatable, Sendable { let protocolName, localAddress: String; let localPort: UInt16; let remoteAddress: String?; let remotePort: UInt16?; let state: String? }` with `var displayText: String`.
  - `protocol ProcessPortProviding: Sendable { func ports(pid: pid_t) -> [ProcessPort] }`.

- [ ] **Step 1: Write the failing tests**

Create `macOSmonitorTests/ProcessPortTests.swift`:

```swift
import Testing
@testable import macOSmonitor

struct ProcessPortTests {
    @Test func displayTextListeningTCP() {
        let p = ProcessPort(protocolName: "TCP", localAddress: "*", localPort: 443,
                            remoteAddress: nil, remotePort: nil, state: "LISTEN")
        #expect(p.displayText == "TCP  *:443 (LISTEN)")
    }

    @Test func displayTextConnectedTCP() {
        let p = ProcessPort(protocolName: "TCP", localAddress: "127.0.0.1", localPort: 8080,
                            remoteAddress: "93.184.216.34", remotePort: 443, state: "ESTABLISHED")
        #expect(p.displayText == "TCP  127.0.0.1:8080 → 93.184.216.34:443 (ESTABLISHED)")
    }

    @Test func displayTextUDPNoState() {
        let p = ProcessPort(protocolName: "UDP", localAddress: "*", localPort: 5353,
                            remoteAddress: nil, remotePort: nil, state: nil)
        #expect(p.displayText == "UDP  *:5353")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests build-for-testing 2>&1 | grep -iE 'error:|cannot find'`
Expected: FAIL — `cannot find 'ProcessPort' in scope`.

- [ ] **Step 3: Implement the value type + protocol**

Create `macOSmonitor/ProcessPort.swift`:

```swift
import Darwin

/// One open network socket held by a process.
struct ProcessPort: Equatable, Sendable {
    let protocolName: String    // "TCP" / "UDP"
    let localAddress: String    // "127.0.0.1", "::1", or "*" for a wildcard bind
    let localPort: UInt16
    let remoteAddress: String?  // nil when listening / unconnected
    let remotePort: UInt16?
    let state: String?          // TCP state name; nil for UDP

    /// e.g. "TCP  *:443 (LISTEN)" or "TCP  127.0.0.1:8080 → 1.2.3.4:443 (ESTABLISHED)".
    var displayText: String {
        var text = "\(protocolName)  \(localAddress):\(localPort)"
        if let remoteAddress, let remotePort { text += " → \(remoteAddress):\(remotePort)" }
        if let state { text += " (\(state))" }
        return text
    }
}

/// Enumerates a process's open network sockets. Implemented by `ProcInfo`; behind a protocol
/// so the model can be tested with a fake.
protocol ProcessPortProviding: Sendable {
    func ports(pid: pid_t) -> [ProcessPort]
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test 2>&1 | grep -iE 'ProcessPortTests.*(passed|failed)|TEST (SUCCEEDED|FAILED)'`
Expected: `** TEST SUCCEEDED **`, all three display tests pass.

- [ ] **Step 5: Commit**

```bash
git add macOSmonitor/ProcessPort.swift macOSmonitorTests/ProcessPortTests.swift
git commit -m "feat: add ProcessPort value type and ProcessPortProviding protocol"
```

---

### Task 2: `ProcInfo.ports(pid:)` — the socket enumeration

**Files:**
- Modify: `macOSmonitor/ProcessPort.swift` (append the `ProcInfo` extension)
- Test: `macOSmonitorTests/ProcInfoPortsTests.swift`

**Interfaces:**
- Consumes: `ProcessPort`, `ProcessPortProviding` (Task 1); `ProcInfo` (existing).
- Produces: `extension ProcInfo: ProcessPortProviding` — enumerates socket fds and parses TCP/UDP socket info; `[]` on EPERM/none.

- [ ] **Step 1: Write the failing integration test**

Create `macOSmonitorTests/ProcInfoPortsTests.swift`:

```swift
import Testing
import Darwin
@testable import macOSmonitor

struct ProcInfoPortsTests {
    @Test func portsIncludesOurTCPListener() throws {
        // Open a real TCP listener on 127.0.0.1:<ephemeral>.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bindRc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(bindRc == 0)
        #expect(listen(fd, 1) == 0)

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        let port = UInt16(bigEndian: bound.sin_port)

        let ports = ProcInfo().ports(pid: getpid())
        let match = ports.first { $0.protocolName == "TCP" && $0.localPort == port }
        #expect(match != nil)
        #expect(match?.state == "LISTEN")
        #expect(match?.localAddress == "127.0.0.1")
        #expect(match?.remoteAddress == nil)   // listening: no peer
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests build-for-testing 2>&1 | grep -iE 'error:|has no member'`
Expected: FAIL — `value of type 'ProcInfo' has no member 'ports'`.

- [ ] **Step 3: Implement the extension**

Append to `macOSmonitor/ProcessPort.swift`:

```swift
import Foundation

extension ProcInfo: ProcessPortProviding {
    func ports(pid: pid_t) -> [ProcessPort] {
        // Enumerate the process's file descriptors.
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        let capacity = Int(needed) / MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let written = fds.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard written > 0 else { return [] }
        let count = Int(written) / MemoryLayout<proc_fdinfo>.stride

        var result: [ProcessPort] = []
        for i in 0..<count where fds[i].proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size
            else { continue }
            if let port = Self.makePort(info.psi) { result.append(port) }
        }
        return result.sorted {
            ($0.protocolName, $0.localPort) < ($1.protocolName, $1.localPort)
        }
    }

    private static func makePort(_ psi: socket_info) -> ProcessPort? {
        switch psi.soi_kind {
        case SOCKINFO_TCP:
            let tcp = psi.soi_proto.pri_tcp
            return makeINPort(tcp.tcpsi_ini, protocolName: "TCP",
                              state: tcpStateName(tcp.tcpsi_state))
        case SOCKINFO_IN:
            return makeINPort(psi.soi_proto.pri_in, protocolName: "UDP", state: nil)
        default:
            return nil
        }
    }

    private static func makeINPort(_ ini: in_sockinfo, protocolName: String,
                                   state: String?) -> ProcessPort? {
        let isV6 = (Int32(ini.insi_vflag) & INI_IPV6) != 0
        // Extract the concrete in_addr / in6_addr inline — never name the anonymous
        // address union type (its Swift-synthesized name is unstable).
        let localText = isV6 ? ipv6(ini.insi_laddr.ina_6)
                             : ipv4(ini.insi_laddr.ina_46.i46a_addr4)
        guard let local = localText.map(wildcarded) else { return nil }

        let localPort = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport))
        let foreignPort = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_fport))

        var remoteAddress: String? = nil
        var remotePort: UInt16? = nil
        if foreignPort != 0 {
            let remoteText = isV6 ? ipv6(ini.insi_faddr.ina_6)
                                  : ipv4(ini.insi_faddr.ina_46.i46a_addr4)
            remoteAddress = remoteText.map(wildcarded)
            remotePort = foreignPort
        }
        return ProcessPort(protocolName: protocolName, localAddress: local, localPort: localPort,
                           remoteAddress: remoteAddress, remotePort: remotePort, state: state)
    }

    private static func ipv4(_ addr: in_addr) -> String? {
        var a = addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &a, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(cString: buffer)
    }

    private static func ipv6(_ addr: in6_addr) -> String? {
        var a = addr
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &a, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(cString: buffer)
    }

    /// Wildcard (0.0.0.0 / ::) renders as "*".
    private static func wildcarded(_ text: String) -> String {
        (text == "0.0.0.0" || text == "::") ? "*" : text
    }

    private static func tcpStateName(_ state: Int32) -> String {
        switch state {
        case 0: return "CLOSED"
        case 1: return "LISTEN"
        case 2: return "SYN_SENT"
        case 3: return "SYN_RECEIVED"
        case 4: return "ESTABLISHED"
        case 5: return "CLOSE_WAIT"
        case 6: return "FIN_WAIT_1"
        case 7: return "CLOSING"
        case 8: return "LAST_ACK"
        case 9: return "FIN_WAIT_2"
        case 10: return "TIME_WAIT"
        default: return "UNKNOWN"
        }
    }
}
```

Note: the `ipv4(_:)`/`ipv6(_:)` helpers take concrete `in_addr`/`in6_addr` and the address union is only ever accessed inline via `.ina_6` / `.ina_46.i46a_addr4` — this whole approach (helpers + inline union member access) is verified to compile and run.

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test 2>&1 | grep -iE 'portsIncludesOurTCPListener.*(passed|failed)|TEST (SUCCEEDED|FAILED)'`
Expected: `** TEST SUCCEEDED **` — the listener is found with its port, `state == "LISTEN"`, `localAddress == "127.0.0.1"`.

- [ ] **Step 5: Commit**

```bash
git add macOSmonitor/ProcessPort.swift macOSmonitorTests/ProcInfoPortsTests.swift
git commit -m "feat: enumerate process TCP/UDP sockets via libproc in ProcInfo.ports"
```

---

### Task 3: `ProcessListModel` — `selectedPorts` + `refreshSelection()`

**Files:**
- Modify: `macOSmonitor/ProcessListModel.swift`
- Test: `macOSmonitorTests/ProcessListModelTests.swift` (add a fake + case)

**Interfaces:**
- Consumes: `ProcessPort`, `ProcessPortProviding` (Task 1).
- Produces: `private(set) var selectedPorts: [ProcessPort]`; injected `portProvider: any ProcessPortProviding = ProcInfo()`; `func refreshSelection()` (details + ports); `refreshOnce()` calls `refreshSelection()`.

- [ ] **Step 1: Add the failing test**

In `macOSmonitorTests/ProcessListModelTests.swift`, add this fake at file scope (after `FakeDetailProvider`):

```swift
final class FakePortProvider: ProcessPortProviding, @unchecked Sendable {
    var result: [ProcessPort] = []
    private(set) var lastPID: pid_t?
    func ports(pid: pid_t) -> [ProcessPort] { lastPID = pid; return result }
}
```

And add this test inside `struct ProcessListModelTests`:

```swift
    @Test func refreshSelectionPublishesPortsAndClearsWhenNoSelection() {
        let fake = FakePortProvider()
        fake.result = [ProcessPort(protocolName: "TCP", localAddress: "*", localPort: 80,
                                   remoteAddress: nil, remotePort: nil, state: "LISTEN")]
        let model = ProcessListModel(sampler: FakeSampler(), portProvider: fake)

        model.selectedPID = 7
        model.refreshSelection()
        #expect(fake.lastPID == 7)
        #expect(model.selectedPorts.count == 1)

        model.selectedPID = nil
        model.refreshSelection()
        #expect(model.selectedPorts.isEmpty)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests build-for-testing 2>&1 | grep -iE 'error:'`
Expected: FAIL — extra argument `portProvider` / no member `refreshSelection`/`selectedPorts`.

- [ ] **Step 3: Update the model**

In `macOSmonitor/ProcessListModel.swift`:

(a) Add the stored property after `selectedDetails`:

```swift
    /// Open network sockets for the selected process; empty when none selected or denied.
    private(set) var selectedPorts: [ProcessPort] = []
```

(b) Add the dependency + init parameter. Change the stored deps and init to include `portProvider` (place it after `detailProvider`):

```swift
    private let detailProvider: any ProcessDetailProviding
    private let portProvider: any ProcessPortProviding
    private let interval: Duration

    init(sampler: any ProcessSampling = ProcessSampler(),
         terminator: any ProcessTerminating = ProcessTerminator(),
         detailProvider: any ProcessDetailProviding = ProcInfo(),
         portProvider: any ProcessPortProviding = ProcInfo(),
         interval: Duration = .seconds(1)) {
        self.sampler = sampler
        self.terminator = terminator
        self.detailProvider = detailProvider
        self.portProvider = portProvider
        self.interval = interval
    }
```

(c) Change `refreshOnce()` to call `refreshSelection()` instead of `refreshDetails()`:

```swift
    func refreshOnce() async {
        rows = await sampler.sample()
        refreshSelection()
    }
```

(d) Add `refreshSelection()` (keep `refreshDetails()` as-is — it's now called by `refreshSelection()`):

```swift
    /// Refresh all selection-scoped inspector data (details + ports) for `selectedPID`.
    func refreshSelection() {
        refreshDetails()
        selectedPorts = selectedPID.map { portProvider.ports(pid: $0) } ?? []
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test 2>&1 | grep -iE 'refreshSelection.*(passed|failed)|TEST (SUCCEEDED|FAILED)'`
Expected: `** TEST SUCCEEDED **`, including the new test; existing model tests still pass.

- [ ] **Step 5: Commit**

```bash
git add macOSmonitor/ProcessListModel.swift macOSmonitorTests/ProcessListModelTests.swift
git commit -m "feat: add selectedPorts and refreshSelection (details+ports) to ProcessListModel"
```

---

### Task 4: `ProcessDetailView` Ports section + `ContentView` rewire

**Files:**
- Modify: `macOSmonitor/ProcessDetailView.swift`
- Modify: `macOSmonitor/ContentView.swift`

**Interfaces:**
- Consumes: `ProcessListModel.selectedPorts`, `refreshSelection()` (Task 3); `ProcessPort.displayText` (Task 1).
- Produces: the Ports UI. No unit test (SwiftUI views); validated by build + manual verification.

- [ ] **Step 1: Add the Ports section to the inspector**

In `macOSmonitor/ProcessDetailView.swift`, the Details block currently ends like this (inside the `if let row` Form):

```swift
                } else {
                    Section {
                        Text("Details unavailable (permission denied).")
                            .foregroundStyle(.secondary)
                    }
                }
```

Immediately after that closing `}` (still inside the `Form`), add the Ports section:

```swift
                Section("Ports") {
                    if model.selectedPorts.isEmpty {
                        Text("No open ports.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(model.selectedPorts.enumerated()), id: \.offset) { _, port in
                            Text(port.displayText)
                                .monospaced()
                        }
                    }
                }
```

- [ ] **Step 2: Rewire `ContentView`'s selection change to `refreshSelection()`**

In `macOSmonitor/ContentView.swift`, change:

```swift
        .onChange(of: model.selectedPID) { model.refreshDetails() }
```

to:

```swift
        .onChange(of: model.selectedPID) { model.refreshSelection() }
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' build 2>&1 | grep -iE 'error:|BUILD (SUCCEEDED|FAILED)'`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run the full unit suite (nothing regressed)**

Run: `xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test 2>&1 | grep -E 'TEST (SUCCEEDED|FAILED)'`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Manual verification**

Launch the app. In Terminal, start a listener: `nc -l 8080` (leave it running). Then:
- Select the **`nc`** process → the inspector's **Ports** section shows `TCP  *:8080 (LISTEN)` (or `127.0.0.1:8080`).
- Cross-check against `lsof -i -a -p <pid>` for that process — protocols/addresses/ports/state match.
- Select a process with active connections (e.g. a browser) → multiple TCP entries with `→ remote (ESTABLISHED)`; watch entries **appear/disappear live** as connections open/close.
- Select a process with **no sockets** (or a denied "—" row) → the Ports section shows **"No open ports."**
- Deselect → inspector returns to "No Selection"; the Ports section is only shown while a process is selected.

- [ ] **Step 6: Commit**

```bash
git add macOSmonitor/ProcessDetailView.swift macOSmonitor/ContentView.swift
git commit -m "feat: show open ports for the selected process in the inspector"
```

---

## Definition of Done (Milestone 6)

- The inspector shows the selected process's TCP/UDP sockets (protocol, local/remote addr:port, TCP state), updating live.
- Listening, connected, and UDP sockets format correctly; wildcard binds show `*`.
- No sockets / denied → "No open ports." Nothing crashes on unknown socket kinds.
- All unit + integration tests pass via `xcodebuild ... -only-testing:macOSmonitorTests test`.
- Each task committed separately.
