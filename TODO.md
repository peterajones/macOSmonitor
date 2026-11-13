# TODO

_Single source of truth for unfinished work in this project. Tick an item when it is done; the review harness records it and removes the line._

## Next
- [x] Add per-socket byte counts and reverse-DNS of remote addresses (from: docs/superpowers/specs/2026-07-06-ports-inspector-design.md)
- [ ] Add tests for PortsSampler (the new actor), for example that it collects sockets per process and copes with processes whose descriptors macOS withholds, and tests for the ports view's search and Show picker filtering. (from: review harness)

## Later
- [ ] Show per-process network I/O; needs the private NetworkStatistics framework (from: docs/superpowers/specs/2026-07-02-process-detail-inspector-design.md)
- [ ] Add on-behalf-of CPU time (work other processes do for this one) to the inspector (from: docs/superpowers/specs/2026-07-05-cpu-time-column-design.md)
- [ ] Add an Energy panel with power/wattage draw and per-app energy impact; probed 2026-11-12: without root, IOReport gives GPU energy only (CPU, ANE, DRAM read 0), so system power needs the privileged helper (from: docs/superpowers/specs/2026-08-26-performance-view-design.md)
- [ ] Add NPU utilisation; probed 2026-11-12: IOReport's ANE energy reads 0 without root, so it needs the privileged helper (from: docs/superpowers/specs/2026-08-28-summary-dashboard-design.md)
- [ ] Build a privileged XPC helper (SMAppService) for full detail on, and termination of, all processes (from: docs/superpowers/specs/2026-07-02-process-dashboard-design.md)

## Undecided
- [ ] Decide whether the Summary grid needs a reflow rule at the 900×500 minimum window (from: docs/superpowers/specs/2026-08-28-summary-dashboard-design.md)
- [ ] Decide whether eight rows is the right height for the top-processes card (from: docs/superpowers/specs/2026-08-28-summary-dashboard-design.md)
- [ ] Decide how to distribute the app: signing, sandboxing and notarization (from: docs/superpowers/specs/2026-07-02-process-dashboard-design.md)
- [ ] Decide whether to pursue the shelved ESF activity/event feed and control-panel anchors (from: docs/superpowers/specs/2026-07-02-process-dashboard-design.md)
