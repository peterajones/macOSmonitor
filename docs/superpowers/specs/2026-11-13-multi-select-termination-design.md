# Multi-select termination — design

Date: 2026-11-13. Status: draft for Peter's approval.

## Why

Peter's real case: leftover `node` dev servers (a server, a watcher, child workers). He types
"node" in the search field and wants to quit everything that shows up in one go. Losing the
server of the project he's working on is fine; it's cheap to restart. Today the table is
single-select, so this takes one Quit + confirmation per process.

The 2026-07-02 termination spec (`2026-07-02-process-termination-design.md`) left multi-select
out of scope; this design adds it.

## Goals

- The process table selects several rows: ⌘A selects all visible rows; ⇧-click and ⌘-click
  behave as in any macOS table.
- Quit (SIGTERM) and Force Quit (SIGKILL) from the toolbar, the Process menu (⌥⌘Q / ⇧⌥⌘Q) and
  the right-click menu act on the whole selection.
- **Right-click follows the standard macOS rule (Claude's call):** the menu acts on the `ids`
  SwiftUI hands it. Right-clicking inside the selection gives the whole selection; right-clicking
  a row outside it gives that row alone, and the existing selection is left untouched. The
  batch function therefore takes the PIDs as a parameter rather than reading the model.
- One confirmation for the batch, naming what will be signalled.
- After sending, one message summarises any that failed and why; the rest still go.

## Anti-goals (a failure even if it "works")

- **Signalling a process that isn't on screen.** Rows hidden by the current search, preset or
  Hide System checkbox are never acted on, even if they were selected before the filter
  changed. Targets are the selection intersected with the rows the table shows *now*.
- **Signalling a reused PID.** Between confirmation and sending, each target is re-checked
  against the latest sampled rows: the PID must still be present **with the same name**.
  Otherwise it is skipped and reported as "no longer running". (Same intent as Bug A's safety
  note in CLAUDE.md.)
- **Regressing single selection.** With one row selected, everything — inspector, renice,
  confirmation wording ("Quit “node”?" with PID), menus — behaves exactly as today.

## Non-goals

- The menu-bar panel stays single-select.
- Renice stays single-process (it lives in the inspector).
- No "select all matching" button: ⌘A in the table already does it.

## Decided with Peter

- Search, select all, quit all, one confirmation. (Peter, 2026-11-13.)
- Only visible rows are acted on; PID+name re-check before sending; partial failures don't stop
  the rest and are reported once; inspector collapses to a short summary when several are
  selected. (Proposed in chat, Peter: "looks good".)

## Behaviour

### Selection

- `ProcessListModel` holds `selectedPIDs: Set<pid_t>` as the table's selection binding.
- `selectedPID` stays, as the single selected PID when exactly one row is selected and nil
  otherwise. All existing single-selection behaviour (inspector refresh, the reset-on-change
  `didSet` rules for Environment/Open Files/Threads/nice draft/renice error, `renice`'s
  "selection moved" guard) keys off it unchanged.
- Selected-row styling (`themedCell(selected:)`) uses set membership.

### Inspector

- Exactly one selected: unchanged.
- Several selected: a short summary instead of the detail sections, e.g. "6 processes
  selected", with the names grouped and counted ("node ×5, npm"). Per-process data (ports,
  threads, files…) is not loaded for a multi-selection.
- None: unchanged ("no selection" state).

### Targets

A pure function computes the batch from: the selection, the rows currently shown (the output of
`ProcessTableSection.make` with the window's current search/preset/hide-system), and this app's
PID. Its result splits the selection into:

- **targets** — visible, `canTerminate`, not this app;
- **skipped** — visible but not signallable (`canTerminate == false`), or this app's own
  process when it isn't the only visible selected row.

**This app's own process (Claude's call):** it is a target only when it is the *only* visible
row in the PIDs given. Any other visible row alongside it, signallable or not, means it is
skipped (quitting itself part-way would abandon the rest). So macOSmonitor + one other process
→ the other process alone, with the skipped note; macOSmonitor + rows now hidden → macOSmonitor
alone, which behaves as today's single selection.

Hidden selected rows are simply not part of the batch and are not mentioned.

The Quit / Force Quit / Send Signal items are enabled when there is at least one target.

### Confirmation

- One target and nothing skipped: today's dialog, unchanged.
- One target with something skipped (Claude's call): today's single-process title and message
  (name and PID), followed by the skipped note below.
- Several: title "Quit 6 processes?" / "Force Quit 6 processes?" (the verb from
  `ProcessSignal.actionTitle`); the message lists names grouped with counts ("node ×5, npm"),
  plus "N selected processes can't be signalled and will be left alone." when anything was
  skipped. Force Quit keeps its "unsaved work is lost" warning.
- Resume still acts without confirming, as today.

### Sending and results

- The pending request snapshots each target's `(pid, name)` when the dialog opens.
- On confirm, each target is re-checked against the model's latest `rows` (same PID, same
  name); mismatches count as "no longer running". The rest are signalled one by one through the
  existing `ProcessTerminating.send`.
- Outcomes are collected. All succeeded: nothing is shown (rows drop off on the next ~1 Hz
  refresh, as today). Any failures: one alert, e.g. "Quit 4 of 6 processes. Couldn't quit:
  launchd-helper (permission denied); node (no longer running)."
- Pause / Resume / Hang Up under Send Signal use the same batch path (Claude's call:
  they share the signal code, and refusing them on a multi-selection would be odd).

## Constraints

- Follow CLAUDE.md: providers behind protocols, tests with fakes, view state on `ContentView`,
  toolbar stays on `ContentView`, views read the model directly in `body`.
- Batch logic (target split, PID+name re-check, result summary text, grouped-name text) is pure
  and unit-tested with discriminating fixtures; the terminator is the existing fake.
- **Re-run the Bug A repro by hand after this lands** (selection mechanics change). Steps in
  commit `cd69ee7`. Ask Peter to do it.

## Left to the builder

- Exact type and file names for the batch request and its result.
- Wording details beyond the examples above.
- How the inspector summary is laid out.
