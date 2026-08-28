# Summary Dashboard — Design (Milestone 11)

Date: 2026-08-28
Status: approved in brainstorming, pending spec review
Predecessor: `2026-08-26-performance-view-design.md` (M10, merged to main 2026-08-27)

## Purpose

Give macOSmonitor a front page: one dense at-a-glance surface showing every metric the
app already samples, modelled on TMOG's Summary tab. M10 built the neighbouring
*Performance* surface — a sidebar of meters plus one large panel per metric. This
milestone builds the surface you leave open.

Summary becomes the **default landing surface**. Cards are navigation targets: clicking
one selects its Performance panel.

## Defining constraint: no new data

Every value on this dashboard comes from data the app already samples. **No new
providers, no new syscalls, no new IOKit or SMC reads.** This is a composition
milestone, not a research one, and that is what makes it tractable in a single pass.

Available today: CPU (aggregate and per-core), memory used/total, network in/out,
disk read/write, thermal pressure, low-power state, uptime, battery, and the full
process list.

## Non-goals

Explicitly out of scope, each requiring its own provider milestone:

- Temperature readings (TMOG shows 45.6 °C; our `thermal` is ProcessInfo's *pressure*
  level — nominal/fair/serious/critical — not a degree value)
- GPU utilisation, NPU utilisation, energy/power draw, CPU clock speed
- The memory breakdown TMOG shows below its graph (Cached, Swap, Available)
- Per-process GPU columns
- Bug A (selection follows row position) — tracked separately; see `CLAUDE.md`
- **Segmented LED meters — deferred to M12.** TMOG's signature stacked-segment look is
  a milestone of its own. M11 ships a themed continuous `MeterBar`; M12 changes that one
  component's rendering, with no call sites to touch. Splitting it keeps M11 to a single
  new surface instead of a surface plus a visual overhaul.

## Decisions taken

| Question | Decision | Why |
| --- | --- | --- |
| Purpose | The app's front page; default surface; cards navigate | Matches TMOG, where Summary is first in the sidebar |
| Top processes | Include, sampled app-wide | It is the heart of TMOG's Summary; cost is measured, see below |
| Layout | TMOG-faithful asymmetric grid | Most faithful to the target; densest |
| Meters | One themed `MeterBar` (continuous fill) shared by Summary and sidebar | Fixes `SidebarMeter` ignoring the theme, and establishes the seam that M12 swaps for segmented LEDs |
| Colour | Per-metric hues in System; single accent in the four VFD themes | Real vacuum fluorescent displays use one phosphor, so monochrome VFD is authentic rather than a compromise |
| Card/panel relationship | Compact cards composed from M10's pieces; panels untouched | Avoids duplicating logic; accepts duplicated layout *shape*, which is cheap to keep in sync |

### Approach considered and rejected

Refactoring the four M10 panels into a shared header/graph/footer presentation layer,
then assembling both surfaces from it, is the cleaner end state. It was rejected **for
now**: it restructures four files that currently have zero known defects, and it means
guessing the right abstraction before a second consumer exists. Building the Summary is
how we learn what that abstraction should be. Revisit after this milestone ships.

## Layout

```text
┌─────┬────────────────────┬──────────────┐
│ ░ █ │ CPU Overview 18.7% │ Top Processes│
│ ░ █ │  ╱╲__╱╲_╱╲___      │ PID Name  CPU│
│ █ █ │                    │ 94249 Chrome │
│ CPU │ 12 logical procs   │ 48321 ghostty│
│ MEM │                    │              │
├─────┴────────────────────┴──────────────┤
│ Memory              14.1 GB / 18 GB     │
│  ╱‾╲__╱‾‾╲______╱‾╲___                  │
├───────────┬───────────┬─────────────────┤
│ Disk      │ Network   │ Battery │Thermal│
│ R750 W0   │ 18 KB/s   │ 84% ⚡  │Nominal│
└───────────┴───────────┴─────────────────┘
```

### What the left strip contains

**Two vertical `MeterBar`s: CPU and Memory.** These are the only two metrics with a
genuine 0–100% ceiling — CPU against 100%, memory against total installed. Disk and
Network are deliberately excluded from the strip: their rates have no natural maximum, so
a "percentage full" meter for them would be a fraction of a recent autoscaled peak, which
looks like a utilisation reading but is not one. They appear as rate cards instead.

This mirrors the shape of TMOG's four-meter strip while declining to invent a ceiling we
do not have. It intentionally repeats values that also appear in the CPU and Memory
cards, exactly as TMOG repeats its CPU reading.

The bottom row is four instances of one small card component. The Battery card is omitted
entirely when no battery exists (M9's rule), leaving three cards rather than a gap.

## Architecture

### New files

| File | Responsibility |
| --- | --- |
| `MeterBar.swift` | Themed utilisation meter, vertical or horizontal, continuous fill. Takes a fraction and on/off colours; clamping is a pure static function. **This is the component M12 re-renders as segmented LEDs** — its interface is chosen now so that milestone touches no call sites. |
| `SummaryView.swift` | The surface. Owns the grid and nothing else; every cell is a card. |
| `CPUOverviewCard.swift` | CPU trace, headline percent, logical-processor count. |
| `MemoryCard.swift` | Full-width memory trace against total installed. |
| `TopProcessesCard.swift` | Compact process list, top 8 by CPU (see Open questions). |
| `StatCard.swift` | One small card, instantiated four times (Disk, Network, Battery, Thermal). |
| `Metric.swift` | `enum Metric { cpu, memory, network, disk, battery, thermal }` — keys the colour lookup. |

`Metric` is deliberately separate from `Surface`: `Surface` includes `.processes` and
`.summary`, which are not metrics and would need meaningless colour cases.

### Modified files

| File | Change |
| --- | --- |
| `Surface.swift` | New `.summary` case, listed first |
| `ContentView.swift` | Route `.summary`; default to it; host `ProcessListModel`'s run loop |
| `ProcessesView.swift` | Remove `.task { await model.run() }` — the loop moves up |
| `SidebarMeter.swift` | Inline `Capsule` bar becomes a `MeterBar`; reads the theme instead of hardcoding `.secondary` / `.gray` / `.accentColor` |
| `Theme.swift` | Add `color(for: Metric) -> Color` |
| `ProcessListModel.swift` | Add `topByCPU(limit:) -> [ProcessInfoRow]` |

Reused unchanged from M10: `MetricGraph`, `MetricScale`, `GraphGeometry`,
`MetricHistory`, `VitalsHistory`, `VitalsModel`, `SystemVitals`.

`StatCard` and `MeterBar` are each used in more than one place from the first commit, so
both are abstractions with evidence behind them rather than speculative ones.

## Data flow

No new plumbing. `VitalsModel` already runs app-wide from `ContentView` and feeds every
vitals card. `ProcessListModel` feeds `TopProcessesCard`.

**Cards must read the models directly inside `body`** — never snapshot into a local
`let`. This codebase has produced a "frozen panel" regression from exactly that, twice.

## The sampling change, and its acceptance criterion

Today `ProcessListModel.run()` is started by `ProcessesView`'s `.task` and cancelled on
navigation away. It moves to `ContentView`, so roughly 600 processes are sampled once a
second permanently rather than only while the table is visible. This is the app's single
largest expense, and M10's spec states the goal of keeping the monitor out of its own
top five.

**Acceptance criterion, measured not assumed:** the app lists itself. Record
macOSmonitor's own CPU% and resident memory from its own process table — idle, same
machine, before and after the change — and put both numbers in the implementation plan.

**If macOSmonitor appears in its own top five CPU consumers, this milestone has failed
its own goal.** The remedy, pre-agreed rather than improvised: drop process sampling to
a 2–3 second cadence on surfaces other than Processes.

## Theming

`Theme.color(for: Metric)` returns:

- **System palette:** six distinct hues, TMOG-style.
- **The four VFD palettes:** their single accent, for every metric.

The six specific hues are chosen during implementation rather than fixed here, because
the real gate is a test, not a preference: they must not collide with one another, and
each must pass the contrast threshold against both the light and the dark system
background. A hue that fails is replaced. TMOG's own choices (green CPU, purple memory,
blue network) are the starting point.

The monochrome answer is authentic, not a fallback: a real VFD has one phosphor.

**Named risk.** The System palette's background is adaptive
(`Color(nsColor: .windowBackgroundColor)`), but the per-metric hues are fixed. A hue that
reads well against a dark background can wash out against a light one. This is the same
class of defect as M10's near-black-on-near-black finding, so the hues are contrast-tested
against **both** system backgrounds, not just whichever the machine happens to be in.

## Error handling

No new failure modes — there are no new providers. Three existing rules to honour:

- `topByCPU` on empty rows returns empty; the card renders a placeholder, not a blank box.
- The Battery card is omitted when `BatteryInfo` is nil (M9's rule).
- All scaling goes through `MetricScale`; no raw division inside a card.

## Testing

Targeted at the gaps M10's whole-branch review identified — thin coverage on formatters
and on lifecycle code — rather than at whatever is cheapest to test.

| # | Test | Covers |
| --- | --- | --- |
| 1 | `MeterBar.clampedFraction(_:)` | 0, 1.0, negative input, values above 1, NaN |
| 2 | `ProcessListModel.topByCPU(limit:)` | Ordering, limit exceeding row count, empty input, ties |
| 3 | `Theme.color(for:)` | Every fixed palette returns its accent for every metric; System's hues do not collide |
| 4 | Per-metric hue contrast | Legibility against light **and** dark system backgrounds |
| 5 | Cancellation of both `run()` loops | The lifecycle gap M10 left open, now doubly relevant |

Items 1–3 are pure functions specifically so they are testable without a view.
Item 5 closes a known hole rather than adding easy coverage.

Swift Testing only (`@Test`, `#expect`, `Issue.record`). Never XCTest.

### Hand checks

SwiftUI layout cannot be unit-tested. Verify by running:

1. Summary is the surface shown on launch.
2. Every card navigates to its corresponding Performance panel.
3. Sidebar meters are themed (they follow the palette, not the system accent) and still
   update live on every surface.
4. All five themes are legible in system Light Mode **and** Dark Mode.
5. The self-cost measurement above.

## Open questions

Deliberately unresolved; both are cheap to adjust once the surface is on screen:

- Whether the asymmetric grid holds together at the 900×500 minimum window, or needs a
  reflow rule for narrow widths.
- Whether eight rows is the right height for the top-processes card.

## Constraints inherited from the project

- Never edit `macOSmonitor.xcodeproj/project.pbxproj`. Files join their targets by
  directory (`PBXFileSystemSynchronizedRootGroup`, objectVersion 77).
- No `TimelineView`.
- Providers stay behind `Sendable` protocols; models are `@MainActor @Observable`;
  samplers are actors with an injected `now` clock.

See `CLAUDE.md` for build commands and the full gotcha list.
