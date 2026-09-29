# macOSmonitor

A macOS Activity-Monitor-style app: a live process table with an inspector, plus a
Performance view (sidebar meters + CPU/Memory/Network/Disk history graphs, five themes).
Swift 6, SwiftUI, no third-party dependencies.

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
`DiskStatsProviding`, `ProcInfoProviding`) with a real struct and a test fake. This is what
makes the samplers testable — keep it when adding a data source.

**Samplers are `actor`s**, take an injected `now: () -> UInt64` clock so rate arithmetic is
testable, and guard every counter delta (counters wrap and devices reset; unsigned subtraction
traps in Swift).

**Models are `@MainActor @Observable`** and own a sampler plus a ~1 Hz `run()` loop.
`ProcessListModel` (process table) and `VitalsModel` (performance metrics) are independent
siblings owned by `ContentView`, each with its own loop.

**Views must read the model directly inside `body`** — never snapshot into a local `let` first.
Doing that has caused a "frozen panel" regression here more than once.

**View state for the Processes surface lives on `ContentView`, not `ProcessesView`.**
`ProcessesView` sits in one branch of a detail-pane `switch`, so navigating away changes
structural identity and SwiftUI destroys any `@State` declared locally. Sort order and search
text would silently reset on every return trip. Keep them upstairs and pass bindings.

## Tests

**Swift Testing only** — `import Testing`, `@Test`, `#expect`, `Issue.record`. Never XCTest.

Fakes are `final class Fake…: @unchecked Sendable`. Prefer fixtures that *discriminate*: pick
numbers where a plausible wrong implementation gives a visibly different answer (e.g. per-core
percentages whose sum differs from their average), not ones where several implementations agree.

## Gotchas that have cost real time

- `proc_taskinfo.pti_total_user/system` are **Mach ticks, not nanoseconds**. Convert via
  `mach_timebase_info`. Without it, CPU% is ~42× wrong on Apple Silicon.
- `vm_deallocate` after `host_processor_info` must be sized in **`integer_t` units**, not bytes.
- IOKit: release **every** matched service, not just the iterator — put
  `defer { IOObjectRelease(service) }` as the first statement inside the loop body so it also
  fires on the `continue` path. Consume `IORegistryEntryCreateCFProperties` with
  `takeRetainedValue()`.
- Disk byte counters exceed 32 bits on any real machine. `UInt64` throughout.
- **SourceKit in this project routinely emits phantom "cannot find type X in scope" /
  "no such module 'Testing'" errors** right after a file changes. `xcodebuild` is the source of
  truth; if it compiles, the code is fine.
- **Warning greps need a clean build.** `xcodebuild` only emits warnings for files it actually
  recompiled, so an incremental run silently under-reports. Don't claim "zero warnings" from one.
- **Count test results with an UNANCHORED grep.** Parallel test output interleaves and can split a
  result line, so `grep -cE '^Test case .* passed'` under-reports. Use `grep -c "' passed on '"`.
- **`defaults` does NOT reach this app's preferences.** It resolves the domain to a container path
  (`~/Library/Containers/ca.peter-jones.macOSmonitor/…`) while the app reads
  `~/Library/Preferences/ca.peter-jones.macOSmonitor.plist`. To change a stored `@AppStorage` value
  (e.g. `themeID`) from a script: quit the app, `killall cfprefsd`, THEN edit that plist with
  PlistBuddy. Killing cfprefsd *after* editing flushes its stale cache back over your change.

## Known open issues

- **Bug A — selection follows row POSITION, not process identity.** With the table sorted by
  CPU% *ascending* (which clusters churning 0%-CPU helpers), selecting a row and waiting ~30s
  leaves the highlight in place while the underlying process changes; the inspector follows the
  new PID. `ProcessListModel.selectedRow` is correct — the defect is downstream in how SwiftUI
  `Table(selection:)` reconciles a live-resorting dataset. **Safety: acting on a stale highlight
  can Force-Quit the wrong process.** Full repro in the body of commit `b3224b9`. Unfixed.

## Process

Specs and plans live in `docs/superpowers/{specs,plans}/`. They are dated records of what was
approved — read them for context, but don't rewrite them after the fact to match what shipped.
