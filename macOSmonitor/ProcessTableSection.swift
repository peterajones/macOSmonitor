import Darwin
import Foundation

/// One titled group of rows in the process table.
struct ProcessTableSection: Identifiable {
    enum Kind { case applications, background }

    let kind: Kind
    let rows: [ProcessInfoRow]

    var id: Kind { kind }

    var title: String {
        switch kind {
        case .applications: return "Applications (\(rows.count))"
        case .background:   return "Background processes (\(rows.count))"
        }
    }

    /// Splits the rows passing `filter` and matching `searchText` into sections, omitting
    /// any left empty.
    ///
    /// Applications always sort by name so they hold their place as CPU figures change
    /// each tick; only Background processes follow the clicked column. The PID tiebreak
    /// keeps same-named apps from swapping places.
    static func make(rows: [ProcessInfoRow],
                     searchText: String,
                     filter: ProcessFilter = ProcessFilter(),
                     currentUID: uid_t = getuid(),
                     sortOrder: [KeyPathComparator<ProcessInfoRow>]) -> [ProcessTableSection] {
        let matching = rows.filter { filter.includes($0, currentUID: currentUID) && $0.matches(searchText) }
        let applications = matching.filter(\.isApplication).sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.pid < $1.pid : order == .orderedAscending
        }
        let background = matching.filter { !$0.isApplication }.sorted(using: sortOrder)
        return [ProcessTableSection(kind: .applications, rows: applications),
                ProcessTableSection(kind: .background, rows: background)]
            .filter { !$0.rows.isEmpty }
    }
}
