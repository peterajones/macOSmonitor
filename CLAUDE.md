# macOSmonitor

A macOS Activity-Monitor-style app: a Summary dashboard (the default surface), a live process
table with an inspector, a Ports table, and a Performance view (sidebar meters + CPU, GPU,
Memory, Network, Disk, Thermal, Energy and Battery panels). A menu-bar item, and an optional
root helper for other users' processes. Five themes; meters are segmented LED bars.
Swift 6, SwiftUI, no third-party dependencies.

## Design status: functionality first, a design round later

So far the work has been about **what the Mac can report**, not how it looks. Peter doesn't yet
consider the UI up to the standard he wants. A round of design tweaks is planned once the app
works well; its scope is **to be discussed with Peter** (TODO.md). Until then:
- Keep new UI consistent with the existing patterns (panel layout, `MeterBar`, themes) rather
  than restyling as you go.
- Don't start visual redesigns he hasn't asked for. Note ideas for the design round in TODO.md
  instead.

## Build and test

```bash
xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' build
xcodebuild -project macOSmonitor.xcodeproj -scheme macOSmonitor -destination 'platform=macOS' -only-testing:macOSmonitorTests test
```

**Always scope tests to `macOSmonitorTests`.** The `macOSmonitorUITests` target fails from
the CLI with "Timed out enabling automation mode", so an unscoped run reports failure even
when everything passes.

A full run takes about a minute. Prefer teeing one run to a log and grepping the log twice
over running it twice for two different greps.

## Never edit `project.pbxproj`

The project uses `PBXFileSystemSynchronizedRootGroup` (objectVersion 77): files under
`macOSmonitor/` and `macOSmonitorTests/` join their targets **by directory, automatically**.
There is no "add the file to the Xcode target" step — attempting one risks corrupting the
project. Never `git add` the pbxproj either.

Two build settings do matter and are already set in the app target (Debug + Release):
`ENABLE_APP_SANDBOX = NO` (required to read other processes) and
`SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated` (so samplers run off the main actor; Xcode 26
defaults this to MainActor, which breaks the design).

## Architecture

**Providers behind protocols.** Every raw syscall / IOKit / Mach read is isolated behind a
small `Sendable` protocol (`HostStatsProviding`, `NetworkStatsProviding`, `BatteryStatsProviding`,
`DiskStatsProviding`, `ProcInfoProviding`; for the inspector `ProcessDetailProviding`,
`ProcessPortProviding`, `ProcessCommandLineProviding`; and `ProcessTerminating`, which sends every
`ProcessSignal`) with a real struct and a test fake. This is what makes the samplers and models
testable — keep it when adding a data source.

**Private APIs are allowed (decided 2026-11-12), with fallbacks, in the Full edition only.**
The App Store edition compiles them out (see "Distribution" below). Temperature, clock speed
and power draw need IOReport / SMC / private HID sensors.
Each private read goes behind its own provider protocol and must return nil — hiding its
panel — when the interface is missing or changes shape, never crash. Re-run the
real-hardware tests after each macOS update.

**Distribution: one codebase, two editions (decided 2026-11-13).** Peter wants a Mac App Store
presence (cheap or free, to reinforce him as a developer; he already has an iOS app there).
- **App Store edition:** sandboxed, public APIs only. Private-API readers are **compiled out**, not
  just disabled, so App Review's scan finds nothing; panels hide because their providers return nil.
- **Full edition:** today's app (unsandboxed, private APIs, root helper), for Peter, and possibly
  Developer ID from his own site later.
- What the App Sandbox allows, probed 2026-11-13 with sandboxed test binaries on macOS 27.2:
  - **Works:** listing processes via `sysctl(KERN_PROC_ALL)` (`proc_listpids` and `proc_listallpids`
    return **0** in the sandbox); task info, names, paths, owners and arguments for the user's own
    processes; host CPU/per-core/memory; `getifaddrs`; IOPowerSources; IOAccelerator GPU %;
    IOBlockStorageDriver disk stats; device-tree reads.
  - **Blocked:** `kill()` on anything else (EPERM), and even `NSRunningApplication.terminate()` /
    `forceTerminate()` on other apps (both return false); `proc_pid_rusage` and fd lists of other
    processes (no Ports, open files, disk/energy per process); AppleSMC (`0xe00002e2`); IOReport.
  - **Loads but private (App Review rejects):** the HID thermal client, NetworkStatistics.
  - The root helper is out: App Store apps can't install daemons or escalate.
- So the App Store edition is a **monitor**, not a manager: no Quit/Force Quit, Ports, Energy,
  clock speeds or temperatures (thermal state only), no helper. Ship it after the design round.

**The privileged helper (`macOSmonitorHelper` target, added 2026-11-13)** is a root launchd daemon
registered with `SMAppService.daemon` (macOSmonitor ▸ Privileged Helper…; the user approves it under
System Settings ▸ General ▸ Login Items & Extensions ▸ App Background Activity). The app reaches it
over the XPC Mach service `ca.peter-jones.macOSmonitor.helper`.
- `macOSmonitor/HelperShared.swift` is compiled into **both** targets (membership exception in the
  project): the XPC protocol, names, `HelperRules` (what the helper refuses) and the wire format.
  Change the protocol → bump `HelperConstants.protocolVersion`.
- Each side checks the other's code signature (`HelperConstants.clientRequirement` /
  `helperRequirement`, team `8QQC2WMRHS`). **The helper's signing identifier is
  `macOSmonitorHelper`** (the product name), not its bundle ID: it has no embedded Info.plist.
  Test a requirement against the built binary with `codesign -v -R='…' <path>`.
- **Security rules (from the 2026-11-13 security review):** the helper accepts a connection only
  from an **admin** user (`HelperRules.isAdmin`, from the connection's audit-token uid), so a
  standard account can't borrow root's power to signal any process. A **Release** helper also
  refuses debuggable clients (`!entitlement["com.apple.security.get-task-allow"]`): a debuggable
  app can be injected into by any process of the same user. That only works because the app
  target's Release has **Code Signing Inject Base Entitlements = No**; with Apple Development
  signing, Xcode otherwise adds `get-task-allow` to Release too and the Release helper would
  refuse its own app. Debug keeps it (Xcode's debugger needs it), so a Debug helper accepts it.
- The bundle layout comes from two Copy Files phases on the app target: the helper into
  Executables, `LaunchDaemons/ca.peter-jones.macOSmonitor.helper.plist` into Wrapper
  `Contents/Library/LaunchDaemons`.
- The app uses it only when the kernel says EPERM (`HelperBackedTerminator`, `ProcessSampler`'s
  denied PIDs). `ProcessSampler(privileged:)` defaults to **nil** so tests on fake PIDs never reach
  an installed helper; only `ProcessListModel`'s default passes `PrivilegedHelperClient.shared`.
- **Inspector (protocol v2):** `inspect(pid:)` returns a `PrivilegedInspection` (details, ports,
  arguments, open files, threads, disk/energy), read with the app's own readers, so those reader
  files (`ProcInfo`, `CString`, `ProcessDetails`, `ProcessPort`, `ProcessCommandLine`, `OpenFile`,
  `ProcessThreads`, `ProcessResourceUsage`) also have helper target membership. `ProcessListModel`
  asks only when its own read of the selection is denied. **It never carries an environment**
  (stripped in both `PrivilegedInspection` initialisers): macOS shows a user only their own
  processes' environments, and the helper must not widen that.
- **Ports (protocol v3):** `allPorts` returns every process's sockets in one call (the app can't tell
  a denied socket read from a process with none). `PortsSampler(privileged:)` defaults to nil; the
  app's own read wins where it has anything, the helper's fills in the rest.
- **Task samples carry energy (protocol v4):** `ProcTaskSample.energyNanojoules` (`ri_energy_nj`) for
  the Power (W) column; the helper's `taskSamples` now runs `ProcInfo.sample`. The wire format is
  `[resident, cpu, energy?]`, and a 2-value payload from an older helper still decodes.
- Check it's running: `launchctl print system/ca.peter-jones.macOSmonitor.helper`.

**Samplers are `actor`s**, take an injected `now: () -> UInt64` clock so rate arithmetic is
testable, and guard every counter delta (counters wrap and devices reset; unsigned subtraction
traps in Swift).

**Models are `@MainActor @Observable`** and own a sampler plus a ~1 Hz `run()` loop.
`ProcessListModel` (process table) and `BatteryModel` are owned per window by `ContentView`.
`VitalsModel` (performance metrics) is owned by the **app** (`macOSmonitorApp`, loop started
once in `init`) and shared by every window and the menu-bar item: vitals have no per-window
state. Keep `ProcessListModel` per window — it holds the selection, and sharing it across
windows would let one window act on another's selected process. The menu-bar panel has its
own `ProcessListModel`, run only while the panel is open.

**Views must read the model directly inside `body`** — never snapshot into a local `let` first.
Doing that has caused a "frozen panel" regression here more than once.

**View state for the Processes surface lives on `ContentView`, not `ProcessesView`.**
`ProcessesView` sits in one branch of a detail-pane `switch`, so navigating away changes
structural identity and SwiftUI destroys any `@State` declared locally. Sort order and search
text would silently reset on every return trip. Keep them upstairs and pass bindings.

The same goes for the **toolbar**: it is one customizable `.toolbar(id: "main")` on `ContentView`.
A toolbar declared on `ProcessesView` is rebuilt on every surface change, which removes
"Customize Toolbar…" entirely and forgets the user's arrangement. Process buttons stay in the
window toolbar and are disabled off the Processes surface; don't move them back down.

**`MeterBar` is the one meter component** (Summary strip, `StatCard`, sidebar). It draws 20
fixed segments of 5% each, lit by rounding *up* so any non-zero reading shows. Layout maths is
pure and static (`litSegments`, `segmentRects`), like `GraphGeometry` — change the look there,
not at call sites. Colour comes from `Theme.color(for:)`; the VFD themes stay monochrome, so no
green/amber/red zones.

## Tests

**Swift Testing only** — `import Testing`, `@Test`, `#expect`, `Issue.record`. Never XCTest.

Fakes are `final class Fake…: @unchecked Sendable`. Prefer fixtures that *discriminate*: pick
numbers where a plausible wrong implementation gives a visibly different answer (e.g. per-core
percentages whose sum differs from their average), not ones where several implementations agree.

**Floating-point fixtures must be computed, not literal, when the bug is float noise.** A literal
`0.15 * 20` is exactly `3.0`, so a test built on it passes even with `MeterBar`'s rounding
tolerance deleted; `3 * 0.05 * 20` is `3.0000000000000004` and does fail. Real inputs are
computed (`percent / 100`, `used / total`), so fixtures should be too. Check a new test catches
anything by deleting the code it guards and watching it fail.

## Gotchas that have cost real time

- `proc_taskinfo.pti_total_user/system` are **Mach ticks, not nanoseconds**. Convert via
  `mach_timebase_info`. Without it, CPU% is ~42× wrong on Apple Silicon.
- `vm_deallocate` after `host_processor_info` must be sized in **`integer_t` units**, not bytes.
- IOKit: release **every** matched service, not just the iterator — put
  `defer { IOObjectRelease(service) }` as the first statement inside the loop body so it also
  fires on the `continue` path. Consume `IORegistryEntryCreateCFProperties` with
  `takeRetainedValue()`.
- Disk byte counters exceed 32 bits on any real machine. `UInt64` throughout.
- **IOReport's CPU, ANE and DRAM energy counters are frozen on macOS 27.2** (probed 2026-11-13, M3
  Pro: no change over a minute of full load, with or without root). Only `GPU Energy` moves. System
  power comes from the SMC (`PSTR`/`PDTR`/`PPBR`, no root; `AppleSMCPower`). Re-probe after updates.
  NPU utilisation was dropped (2026-11-13): no live busy measure exists. IOReport `ANE`/`IOP State`
  "Running" means powered on (100% even at one Vision request a second); the PMP ANE bandwidth
  histograms move but their units are undocumented.
- **SourceKit in this project routinely emits phantom "cannot find type X in scope" /
  "no such module 'Testing'" errors** right after a file changes. `xcodebuild` is the source of
  truth; if it compiles, the code is fine.
- **Warning greps need a clean build.** `xcodebuild` only emits warnings for files it actually
  recompiled, so an incremental run silently under-reports. Don't claim "zero warnings" from one.
- **A `static` on a SwiftUI `View` is main-actor-only in Swift 6, and calling it off the main
  actor can TRAP AT RUN TIME with no compile warning** (`dispatch_assert_queue` in a crash report).
  It crashed the test host mid-run, failing every test still queued in it at 0.000 s. Mark pure
  helpers on views `nonisolated` (see `SystemVitalsView.thermalText`, `MeterBar.segmentRects`).
  Many 0.000 s failures at once means a host crash: read `~/Library/Logs/DiagnosticReports/`.
- **Tests must not wait on child processes with Foundation's `Process.waitUntilExit()`.** It
  waits for a run-loop notification that, from Swift-concurrency contexts, sometimes never
  arrives — even after the child has exited. It hung the suite (reproduced in under a minute by
  repeating the process-spawning suites 40×). Use `ChildProcess` (tests target): `posix_spawn`
  + `waitpid`, with signal dispositions reset so the child doesn't inherit the test host's
  ignored SIGTERM/SIGHUP. Many tests stuck with no output = sample the host: `sample <pid> 1`.
- **Block parameters in a `@convention(c)` function type are NON-escaping by default.** A
  private C API that keeps the block (NetworkStatistics' source/counts/removed handlers) then
  traps at run time with "non-escaping closure has escaped", crashing the test host. Mark each
  such parameter `@escaping` in the typealias (see `NStatSocketTraffic`).
- **NetworkStatistics: descriptions lag, counts lack addresses.** A source's description
  dictionary names the process and addresses, but its byte counts are a snapshot a query behind
  (a fresh 50 KB transfer read 0). The counts dictionary is live but in practice has no
  addresses. Take identity from descriptions and bytes from counts, joined by source. Sources
  register asynchronously after `NStatManagerAddAll…`, so the first read returns none.
- **Count test results with an UNANCHORED grep.** Parallel test output interleaves and can split a
  result line, so `grep -cE '^Test case .* passed'` under-reports. Use `grep -c "' passed on '"`.
- **`defaults` does NOT reach this app's preferences.** It resolves the domain to a container path
  (`~/Library/Containers/ca.peter-jones.macOSmonitor/…`) while the app reads
  `~/Library/Preferences/ca.peter-jones.macOSmonitor.plist`. To change a stored `@AppStorage` value
  (e.g. `themeID`) from a script: quit the app, `killall cfprefsd`, THEN edit that plist with
  PlistBuddy. Killing cfprefsd *after* editing flushes its stale cache back over your change.

- **The test host IS the app, and shares Peter's preferences.** Unit tests run inside the real
  app process, reading `~/Library/Preferences/ca.peter-jones.macOSmonitor.plist`. Anything a test
  reads from live window or app state (toolbar items, window frames, `@AppStorage` values) reflects
  how Peter has customized his copy, not the app's defaults. `WindowToolbarTests` failed once
  because he had removed Force Quit from his toolbar. Test against declared defaults (e.g.
  `toolbarDefaultItemIdentifiers`), never the user's current arrangement, and never write to
  those preferences from a test.

## Known open issues

- **Bug A — selection followed row POSITION, not process identity: no longer reproduces.** With
  the table sorted by CPU% *ascending* (which clusters churning 0%-CPU helpers), selecting a row
  and waiting ~30s used to leave the highlight in place while the underlying process changed; the
  inspector followed the new PID. Hand-checked on 2026-11-09 (Xcode 27, macOS 27.2, sectioned
  table): the highlight and inspector PID stayed put. Re-checked by Peter on 2026-11-10 at
  `2f64766`, after that day's cell-content changes (bold search matches, themed cells): still
  passes. Re-checked by Peter on 2026-11-13 after multi-select (the table binds
  `Set<pid_t>`; exited PIDs are pruned from it each refresh): still passes. No commit targeted the cause, so it may have
  gone away with the toolchain. **Safety: if it returns, acting on a stale highlight can Force-Quit
  the wrong process.** Re-run this repro after changing how `Table` rows or selection work; full
  steps in the body of commit `cd69ee7`.

## Process

Keep `TODO.md` current: tick an item (`- [x]`) when it is finished — don't delete it; the review harness records it and removes the line — and add any unfinished work you discover.

Specs and plans live in `docs/superpowers/{specs,plans}/`. They are dated records of what was
approved — read them for context, but don't rewrite them after the fact to match what shipped.
