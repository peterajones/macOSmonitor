import Darwin
import Foundation

/// Which processes the table shows, before the search text narrows it further.
/// Mirrors Activity Monitor's View menu presets, plus a "hide system" switch that
/// combines with any of them.
struct ProcessFilter: Equatable, Sendable {
    enum Preset: String, CaseIterable, Identifiable, Sendable {
        case all, mine, system, otherUsers, active

        var id: Self { self }

        var title: String {
            switch self {
            case .all:        "All Processes"
            case .mine:       "My Processes"
            case .system:     "System Processes"
            case .otherUsers: "Other User Processes"
            case .active:     "Active Processes"
            }
        }
    }

    var preset: Preset = .all
    var hidesSystem = false

    /// macOS gives people accounts uids from 501 up. Below 500 are root and the reserved
    /// `_`-prefixed service accounts (`_windowserver`, `_spotlight`, …); `nobody` is -2.
    static func isSystem(uid: uid_t) -> Bool {
        uid < 500 || uid == uid_t(bitPattern: -2)
    }

    /// The display rounds CPU% to one decimal, so "active" means it shows as at least 0.1.
    /// A plain `> 0` would keep rows reading "0.0", which looks like a broken filter.
    static let activeThreshold = 0.05

    /// Whether the app can read system processes' CPU. Without root it can't, so they show
    /// "—" and never count as active. Injectable so both cases are testable.
    var canReadSystemCPU = getuid() == 0

    /// Whether Hide System Processes can change what this preset shows. Where it can't, the
    /// switch is ignored and disabled in the UI, rather than looking broken (or, for the System
    /// preset, emptying the table). My/Other User Processes never include system processes;
    /// Active only can when their CPU is readable.
    var hidesSystemApplies: Bool {
        switch preset {
        case .all:                        true
        case .active:                     canReadSystemCPU
        case .mine, .otherUsers, .system: false
        }
    }

    /// Tooltip for the switch: says what it does, or why it is disabled.
    var hideSystemHelp: String {
        if hidesSystemApplies { return "Hides processes owned by root and macOS service accounts" }
        switch preset {
        case .system: return "Not available while showing only system processes"
        case .active: return "System processes never appear here: macOS doesn’t let this app read their CPU"
        default:      return "This view already leaves out system processes"
        }
    }

    /// Whether `row` passes this filter. A row whose owner is unknown (it exited mid-sample)
    /// is never treated as system, so it isn't hidden by the toggle, but it doesn't match an
    /// owner-based preset either.
    func includes(_ row: ProcessInfoRow, currentUID: uid_t) -> Bool {
        let isSystem = row.uid.map(Self.isSystem) ?? false
        if hidesSystem && hidesSystemApplies && isSystem { return false }

        switch preset {
        case .all:        return true
        case .mine:       return row.uid == currentUID
        case .system:     return isSystem
        case .otherUsers: return row.uid.map { $0 != currentUID && !Self.isSystem(uid: $0) } ?? false
        case .active:     return (row.cpuPercent ?? 0) >= Self.activeThreshold
        }
    }
}

/// Search queries the user has saved, most recent first. Stored in `@AppStorage` as JSON.
struct SavedSearches: RawRepresentable, Equatable, Sendable {
    private(set) var queries: [String]

    /// Enough for a menu to stay scannable; the oldest drops off past this.
    static let limit = 12

    init(_ queries: [String] = []) { self.queries = queries }

    init(rawValue: String) {
        queries = (try? JSONDecoder().decode([String].self, from: Data(rawValue.utf8))) ?? []
    }

    var rawValue: String {
        (try? String(data: JSONEncoder().encode(queries), encoding: .utf8)) ?? "[]"
    }

    /// Saves `query` (trimmed) at the top. Re-saving an existing query, in any case, moves it
    /// up rather than adding a duplicate. Empty queries are ignored.
    mutating func save(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queries.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        queries.insert(trimmed, at: 0)
        if queries.count > Self.limit { queries.removeLast(queries.count - Self.limit) }
    }

    mutating func remove(_ query: String) {
        queries.removeAll { $0 == query }
    }

    func contains(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return queries.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }
}
