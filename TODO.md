# TODO

_Single source of truth for unfinished work in this project. Tick an item when it is done; the review harness records it and removes the line._

## Next
- [x] Add a menu-bar surface (from: docs/superpowers/specs/2026-07-02-process-dashboard-design.md)
- [x] Add P/E core labelling to the CPU panel (from: docs/superpowers/specs/2026-08-26-performance-view-design.md)
- [ ] Add tests for BatteryHistory's 24-hour recording and pruning, including the on-power bar spans, and for BatteryModel's fallback from AppleSmartBattery to the AppleSmartBatteryPack child. (from: review harness)
- [ ] Add tests for MatchHighlight covering the new field-qualified terms, so that pid:, user:, path: and name: highlight the matched field and quoted multi-word terms highlight correctly. (from: review harness)

## Later
- [ ] Add per-core clock speed to the CPU panel; Apple Silicon exposes it only through private IOReport or root-only powermetrics (from: docs/superpowers/specs/2026-08-26-performance-view-design.md)
- [ ] Add per-process GPU columns to the process table (from: docs/superpowers/specs/2026-08-28-summary-dashboard-design.md)
- [ ] Add temperature readings and a Thermal sensor-detail panel (from: docs/superpowers/specs/2026-08-26-performance-view-design.md)
- [ ] Add an Energy panel with power/wattage draw and per-app energy impact (from: docs/superpowers/specs/2026-08-26-performance-view-design.md)
- [ ] Add NPU utilisation (from: docs/superpowers/specs/2026-08-28-summary-dashboard-design.md)
- [ ] Build a privileged XPC helper (SMAppService) for full detail on, and termination of, all processes (from: docs/superpowers/specs/2026-07-02-process-dashboard-design.md)
- [ ] Show per-process network and disk I/O (from: docs/superpowers/specs/2026-07-02-process-detail-inspector-design.md)
- [ ] Support multi-select termination (from: docs/superpowers/specs/2026-07-02-process-termination-design.md)
- [ ] Add per-thread CPU time and on-behalf-of/GPU time (from: docs/superpowers/specs/2026-07-05-cpu-time-column-design.md)
- [ ] Add per-socket byte counts and reverse-DNS of remote addresses (from: docs/superpowers/specs/2026-07-06-ports-inspector-design.md)
- [ ] Add a ports column or dedicated Network tab for open sockets (from: docs/superpowers/specs/2026-07-06-ports-inspector-design.md)

## Undecided
- [ ] Decide whether the Summary grid needs a reflow rule at the 900×500 minimum window (from: docs/superpowers/specs/2026-08-28-summary-dashboard-design.md)
- [ ] Decide whether eight rows is the right height for the top-processes card (from: docs/superpowers/specs/2026-08-28-summary-dashboard-design.md)
- [ ] Decide how to distribute the app: signing, sandboxing and notarization (from: docs/superpowers/specs/2026-07-02-process-dashboard-design.md)
- [ ] Decide whether to pursue the shelved ESF activity/event feed and control-panel anchors (from: docs/superpowers/specs/2026-07-02-process-dashboard-design.md)
