# macOSmonitor — Table Search/Filter Design (Milestone 4)

**Date:** 2026-07-05
**Status:** Approved for implementation planning
**Author:** Peter Jones (with Claude)

## Context

Milestones 1–3 shipped a live process table with termination and a detail inspector
(`ProcInfo` → `ProcessSampler` → `ProcessListModel` → SwiftUI `Table` + `.inspector`). The
table refreshes ~1 Hz and is very active, making it hard to locate a specific process — in
particular a PID handed over out-of-band. Milestone 4 adds a search/filter field.

## Goal & Success Criteria

A `.searchable` toolbar field that live-filters the table by **name or PID** (case-insensitive
substring), leaving sorting, live refresh, selection, termination, and the inspector intact.

**Success = typing part of a process name narrows the table to matches; typing a PID surfaces
that process; ⌘F focuses the field; clearing it restores the full list; and filtering plays
correctly with the live ~1 Hz refresh and column sorting.**

## Scope

**In scope (Milestone 4):**
- A `.searchable(text:)` search field in the toolbar; filters live as you type.
- Match against **name** (case-insensitive substring) OR the process's **PID** (substring of its
  decimal string). Empty query = no filter (all rows shown).
- Filtering composes with existing sorting (filter, then sort) and the ~1 Hz refresh.
- **Folded-in cleanup** (deferred from the M3 review): hoist the duplicated CPU%/Memory text
  formatting into computed `cpuText`/`memoryText` on `ProcessInfoRow`, used by both
  `ContentView` and `ProcessDetailView`.

**Out of scope (documented for the future):**
- Matching on executable path, user, or other detail fields (path/user live in the per-selection
  detail fetch, not on table rows).
- Regex / token / field-qualified search (e.g. `pid:771`).
- Filter presets, saved searches, or a "hide system processes" toggle.
- Highlighting the matched substring within rows.

## Key Decisions

- **`.searchable(text:)`** — the native macOS idiom; gives the toolbar search field, the clear
  button, and ⌘F focus for free. (Chosen over a hand-rolled `TextField`.)
- **Match name + PID** — both already live on `ProcessInfoRow`; directly solves locating a
  handed-over PID. (Path/user deferred — they aren't on the row.)
- **Match logic as a pure method on `ProcessInfoRow`** — `matches(_:)` is the real logic and is
  independently unit-testable; the view filters with it. The model is left untouched (adding
  `searchText`/`filteredRows` to the model buys nothing and would bloat it — YAGNI).
- **Case-insensitive substring**, empty query → all rows.
- **Selection/inspector independent of the filter** — a process selected and then filtered out of
  the visible list still shows its details in the inspector (it was selected deliberately; the
  filter narrows the list, not the selection).

## Architecture

No new files. One new method + two computed properties on `ProcessInfoRow`; the filter is applied
in `ContentView`'s table data expression.

```
ContentView
  @State searchText  ──.searchable(text:)──▶ toolbar field
  Table( model.rows.filter { $0.matches(searchText) }.sorted(using: sortOrder) )
                              │
                              ▼
              ProcessInfoRow.matches(_:)   (pure, tested)
              ProcessInfoRow.cpuText / .memoryText  (shared by ContentView + ProcessDetailView)
```

### `ProcessInfoRow` additions

- `func matches(_ query: String) -> Bool`
  - Trim the query; if empty → `true`.
  - Otherwise `true` if `name` contains the query case-insensitively, OR `String(pid)` contains
    the query.
- `var cpuText: String` → `cpuPercent.map { String(format: "%.1f", $0) } ?? "—"`.
- `var memoryText: String` → `memoryBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) } ?? "—"`.

### `ContentView` changes

- `@State private var searchText = ""`.
- `.searchable(text: $searchText)` on the table (or its container).
- Table data becomes `model.rows.filter { $0.matches(searchText) }.sorted(using: sortOrder)`.
- CPU%/Memory cells use `row.cpuText` / `row.memoryText`.

### `ProcessDetailView` changes

- Its CPU%/Memory rows use `row.cpuText` / `row.memoryText`.

## Data Flow

1. User types in the search field → `searchText` updates.
2. On the next render (and on every ~1 Hz model update), the table data expression filters the
   latest `model.rows` by `matches(searchText)`, then sorts by the current `sortOrder`.
3. Selection (`model.selectedPID`) and the inspector are unaffected by the filter; the inspector
   continues to show `selectedDetails` for whatever is selected.

## Error Handling

- Empty/whitespace-only query → treated as no filter (all rows).
- A filter that matches nothing → an empty table (expected); clearing restores the list.
- A selected row filtered out of view → selection and inspector persist (by design).

## Testing Strategy

- **`ProcessInfoRow.matches`** (unit): name substring match; case-insensitive match; PID substring
  match; empty/whitespace query → true (all); non-matching query → false.
- **`ProcessInfoRow.cpuText` / `memoryText`** (unit): a real value formats as expected; `nil`
  yields `"—"`.
- **`ContentView` / manual verification**: type a partial name → table narrows; type a PID → that
  process appears; ⌘F focuses the field; clearing restores the full list; sorting still applies to
  the filtered set; a selected-then-filtered-out process still shows in the inspector.

## Open Questions

None blocking.
