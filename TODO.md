# TODO

_Single source of truth for unfinished work in this project. Tick an item when it is done; the review harness records it and removes the line._

## Next
- [x] Decide how to distribute the app: signing, sandboxing and notarization (from: docs/superpowers/specs/2026-07-02-process-dashboard-design.md)

## Later
- [ ] Design round: discuss with Peter, then do a pass of design tweaks over the UI once the functionality has settled (he doesn't yet consider the UI up to standard; scope to be agreed) (from: Peter, 2026-11-13)
- [ ] Design round: decide whether the Summary grid needs a reflow rule at the 900×500 minimum window (from: docs/superpowers/specs/2026-08-28-summary-dashboard-design.md)
- [ ] Design round: decide whether eight rows is the right height for the top-processes card (from: docs/superpowers/specs/2026-08-28-summary-dashboard-design.md)
- [ ] App Store edition: add a sandboxed build of the app (Peter sets up the target/configuration in Xcode) with an APP_STORE compile flag that compiles out every private-API reader (SMC, IOReport, HID thermal, NetworkStatistics) and the helper, and hides Quit/Force Quit, Ports and Energy; see CLAUDE.md "Distribution" (from: Peter, 2026-11-13)
- [ ] App Store edition: list processes with sysctl(KERN_PROC_ALL), since proc_listpids returns nothing in the App Sandbox (from: sandbox probe, 2026-11-13)
- [ ] App Store edition: after the design round, prepare App Store Connect (bundle ID, icon, screenshots, description, privacy details, price) and submit (from: Peter, 2026-11-13)

## Undecided
- [ ] Decide whether to pursue the shelved ESF activity/event feed and control-panel anchors (from: docs/superpowers/specs/2026-07-02-process-dashboard-design.md)
