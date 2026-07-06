# macOSmonitor — Ports (Open Sockets) Inspector Design (Milestone 6)

**Date:** 2026-07-06
**Status:** Approved for implementation planning
**Author:** Peter Jones (with Claude)

## Context

Milestones 1–5 shipped a live process table (termination, detail inspector, search, CPU Time).
This milestone adds the second half of the original "Ports & CPU Time" request: a **Ports**
section in the inspector listing the selected process's open network sockets. It is the largest
milestone so far — new `libproc` socket syscalls, union parsing, and IPv4/IPv6 address formatting.

## Goal & Success Criteria

For the selected process, show every TCP/UDP socket (IPv4 + IPv6) — protocol, local `addr:port`,
remote `addr:port` when connected, and TCP state — updating live each ~1 Hz tick.

**Success = selecting a process with network activity (e.g. a browser or `nc -l 8080`) shows its
sockets with correct addresses/ports/state matching `lsof -i -a -p <pid>`; connections appearing
and closing show up live; and processes with no sockets (or denied) show "No open ports."**

## Scope

**In scope (Milestone 6):**
- A **Ports** section in the inspector for the selected process.
- Every TCP and UDP socket the process holds, IPv4 and IPv6.
- Per socket: protocol (TCP/UDP), local `addr:port`, remote `addr:port` (when connected), TCP state.
- Live-updating each ~1 Hz tick (folded into the selection refresh).
- Own processes only; denied/exited/no-sockets → "No open ports."

**Out of scope (documented for the future):**
- Non-socket file descriptors (files, pipes, kqueues).
- Unix-domain sockets (focus is network ports); raw/other socket kinds are skipped.
- Per-socket byte counts / throughput, or reverse-DNS of remote addresses.
- A dedicated Network tab or a table column for ports (inspector-only for now).

## Key Decisions

- **Full connection picture** — TCP + UDP, IPv4 + IPv6, listening + connected, with TCP state
  (the `lsof -i` / `nettop` view). Chosen over TCP-only or listening-only.
- **Live-updating** — re-enumerate the selected process's sockets each ~1 Hz tick, consistent with
  the (post-M5) live inspector. Cost is a handful of syscalls for one process — trivial.
- **Syscalls isolated in `ProcInfo`** — a new `ProcessPortProviding` protocol implemented by
  `ProcInfo`, same pattern as `ProcessDetailProviding`. The only file touching socket syscalls.
- **`refreshSelection()`** — the model bundles the details fetch and the ports fetch into one
  selection-scoped refresh, replacing the direct `refreshDetails()` calls (in `refreshOnce()` and
  the view's `.onChange(of: selectedPID)`), keeping the two in lockstep.
- **Own processes only** — denied → empty list (no privileged helper; that's a far-future item).

## Architecture

New syscalls isolated in `ProcInfo`; a new value type; small additions to the model and the
inspector view. No new files strictly required, but the port value type + provider live in a new
`ProcessPort.swift` to keep `ProcInfo.swift` focused.

### New value type + provider (`ProcessPort.swift`)

```swift
struct ProcessPort: Equatable, Sendable {
    let protocolName: String    // "TCP" / "UDP"
    let localAddress: String    // "127.0.0.1", "::1", or "*" for a wildcard bind
    let localPort: UInt16
    let remoteAddress: String?  // nil when listening / unconnected
    let remotePort: UInt16?
    let state: String?          // TCP state name ("LISTEN"/"ESTABLISHED"/…); nil for UDP

    var displayText: String { /* see Format below */ }
}

protocol ProcessPortProviding: Sendable {
    func ports(pid: pid_t) -> [ProcessPort]
}

extension ProcInfo: ProcessPortProviding { func ports(pid: pid_t) -> [ProcessPort] { … } }
```

### `ProcInfo.ports(pid:)` (the syscall work)

1. `proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer, size)` → array of `proc_fdinfo`; buffer sized by
   a first nil-buffer call. Keep entries whose `proc_fdtype == PROX_FDTYPE_SOCKET`.
2. For each socket fd: `proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size)` → `socket_fdinfo`.
   Inspect `info.psi.soi_kind`:
   - `SOCKINFO_TCP` → `pri_tcp`: local/remote addrs+ports from `tcpsi_ini` (`insi_lport`/`insi_fport`
     are network byte order → `ntohs`; `insi_laddr`/`insi_faddr` per `insi_vflag` IPv4 vs IPv6 →
     `inet_ntop`); TCP state from `tcpsi_state` → name.
   - `SOCKINFO_IN` → `pri_in`: UDP/raw datagram socket; local (and remote if present) addr+port; no state.
   - Other kinds → skipped.
3. Wildcard/unspecified local address (`0.0.0.0` / `::`) → rendered as `"*"`.
4. Returns `[]` on EPERM/exit/no sockets. Never crashes on an unknown/short struct.

Exact struct field names, the `soi_proto` union access, `insi_vflag` IPv4/IPv6 discrimination, and
TCP-state constants will be **verified empirically during planning** before writing code/tests.

### Model (`ProcessListModel`)

- Add `private(set) var selectedPorts: [ProcessPort] = []`.
- Inject `portProvider: any ProcessPortProviding = ProcInfo()`.
- Add `func refreshSelection()` that refreshes both `selectedDetails` and `selectedPorts` for the
  current `selectedPID` (empty/nil when nothing selected). Replace the current `refreshDetails()`
  call in `refreshOnce()` with `refreshSelection()`. (Keep `refreshDetails()` as the details-only
  helper that `refreshSelection()` calls, so existing detail tests are unaffected.)

### UI (`ProcessDetailView`)

- The view already takes the model (post-M5). Add a **Ports** `Section` after the Details section,
  listing `model.selectedPorts` sorted by protocol then local port. Each row: `Text(port.displayText)`
  (monospaced). Empty list → a single secondary-styled row "No open ports."

### `displayText` format

- Listening (no remote): `"TCP  *:443 (LISTEN)"`
- Connected: `"TCP  127.0.0.1:8080 → 93.184.216.34:443 (ESTABLISHED)"`
- UDP (no state): `"UDP  *:5353"`

Rule: `protocol` + two spaces + `local`; if `remoteAddress`/`remotePort` present, ` → remote`; if
`state` present, ` (STATE)`.

## Data Flow

1. Each ~1 Hz tick, `refreshOnce()` → `refreshSelection()` → `portProvider.ports(selectedPID)` →
   publishes `selectedPorts` (and details).
2. On a new selection, `.onChange(of: selectedPID)` calls `refreshSelection()` for instant population.
3. `ProcessDetailView` observes `model.selectedPorts` and re-renders the Ports section live.

## Error Handling

- Denied/exited/no sockets → `ports` returns `[]` → "No open ports." No crash.
- Unknown/short socket structs or unrecognized `soi_kind` → that fd skipped.
- Address that fails `inet_ntop` → that socket skipped (never a partial/garbage row).

## Testing Strategy

- **`ProcInfo.ports`** (integration, deterministic): the test creates a real TCP listening socket
  (`socket`/`bind` to `127.0.0.1:0`/`listen`), reads back the assigned port via `getsockname`, then
  asserts `ports(getpid())` contains a TCP entry with that `localPort` and `state == "LISTEN"`;
  closes the socket.
- **`ProcessPort.displayText`** (unit): the three formats above produce their exact strings; a UDP
  entry omits the state; a listening entry omits the remote.
- **`ProcessListModel`** (unit): inject a fake `ProcessPortProviding`; `refreshSelection()` publishes
  `selectedPorts`; selecting nothing clears it to `[]`. (A fake detail provider covers the details half.)
- **Manual verification:** select a process with sockets (browser, or `nc -l 8080`), confirm its
  ports match `lsof -i -a -p <pid>`; open/close a connection and watch the list update live; a
  no-socket or denied process shows "No open ports."

## Open Questions

None blocking. (Struct/union specifics are a planning-time empirical check, not an open design question.)
