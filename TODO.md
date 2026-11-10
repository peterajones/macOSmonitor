# TODO

_Single source of truth for unfinished work in this project. Tick an item when it is done; the review harness records it and removes the line._

## Next
- [x] Update the stale ProcessArguments references after the rename to ProcessCommandLine: the commit lists both macOSmonitor/ProcessArguments.swift and macOSmonitorTests/ProcessArgumentsTests.swift as changed, alongside new ProcessCommandLine files. Confirm the old source and test files were removed rather than left as duplicates, and rename the tests to match. (from: review harness)
- [x] Add a test covering the Environment section's collapse-on-selection-change behaviour, and one for the platform-binary case where macOS withholds the environment (empty or unavailable state). (from: review harness)
- [ ] Support sending arbitrary signals (SIGSTOP/SIGCONT/SIGHUP) (from: docs/superpowers/specs/2026-07-02-process-termination-design.md)
- [ ] Apply the theme to the process table (from: docs/superpowers/specs/2026-08-26-performance-view-design.md)
- [ ] Add per-core history traces to the CPU core grid (from: docs/superpowers/specs/2026-08-26-performance-view-design.md)

## Later
- [ ] Add a GPU utilisation/memory provider and surface it in the vitals and Performance views (from: docs/superpowers/specs/2026-08-28-summary-dashboard-design.md)
- [ ] Add per-process GPU columns to the process table (from: docs/superpowers/specs/2026-08-28-summary-dashboard-design.md)
- [ ] Add temperature readings and a Thermal sensor-detail panel (from: docs/superpowers/specs/2026-08-26-performance-view-design.md)
- [ ] Add an Energy panel with power/wattage draw and per-app energy impact (from: docs/superpowers/specs/2026-08-26-performance-view-design.md)
- [ ] Add NPU utilisation (from: docs/superpowers/specs/2026-08-28-summary-dashboard-design.md)
- [ ] Add P/E core labelling and per-core clock speed to the CPU panel (from: docs/superpowers/specs/2026-08-26-performance-view-design.md)
- [ ] Add a battery-detail view with health, cycle count and charging history (from: docs/superpowers/specs/2026-07-08-battery-vital-design.md)
- [ ] Add a menu-bar surface (from: docs/superpowers/specs/2026-07-02-process-dashboard-design.md)
- [ ] Build a privileged XPC helper (SMAppService) for full detail on, and termination of, all processes (from: docs/superpowers/specs/2026-07-02-process-dashboard-design.md)
- [ ] Show per-process network and disk I/O (from: docs/superpowers/specs/2026-07-02-process-detail-inspector-design.md)
- [ ] Allow renicing a process from the inspector (from: docs/superpowers/specs/2026-07-02-process-detail-inspector-design.md)
- [ ] Support multi-select termination (from: docs/superpowers/specs/2026-07-02-process-termination-design.md)
- [ ] Add per-thread CPU time and on-behalf-of/GPU time (from: docs/superpowers/specs/2026-07-05-cpu-time-column-design.md)
- [ ] Add a configurable CPU-time format or a live CPU-time-rate display (from: docs/superpowers/specs/2026-07-05-cpu-time-column-design.md)
- [ ] Extend process search to path and user, with regex or field-qualified queries such as pid:771 (from: docs/superpowers/specs/2026-07-05-table-search-design.md)
- [ ] Add filter presets, saved searches and a hide-system-processes toggle (from: docs/superpowers/specs/2026-07-05-table-search-design.md)
- [ ] List non-socket file descriptors and Unix-domain sockets in the inspector (from: docs/superpowers/specs/2026-07-06-ports-inspector-design.md)
- [ ] Add per-socket byte counts and reverse-DNS of remote addresses (from: docs/superpowers/specs/2026-07-06-ports-inspector-design.md)
- [ ] Add a ports column or dedicated Network tab for open sockets (from: docs/superpowers/specs/2026-07-06-ports-inspector-design.md)

## Undecided
- [ ] Decide whether the Summary grid needs a reflow rule at the 900×500 minimum window (from: docs/superpowers/specs/2026-08-28-summary-dashboard-design.md)
- [ ] Decide whether eight rows is the right height for the top-processes card (from: docs/superpowers/specs/2026-08-28-summary-dashboard-design.md)
- [ ] Decide how to distribute the app: signing, sandboxing and notarization (from: docs/superpowers/specs/2026-07-02-process-dashboard-design.md)
- [ ] Decide whether to pursue the shelved ESF activity/event feed and control-panel anchors (from: docs/superpowers/specs/2026-07-02-process-dashboard-design.md)
