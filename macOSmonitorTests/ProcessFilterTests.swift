import Testing
import Darwin
import Foundation
@testable import macOSmonitor

struct ProcessFilterTests {
    // One row per kind of owner. 262 is a real `_`-service uid on macOS; 502 is a second
    // person's account, which separates "other users" from "not me".
    private let me: uid_t = 501
    private var rows: [ProcessInfoRow] {
        [ProcessInfoRow(pid: 10, name: "mine", cpuPercent: 3, memoryBytes: 1, uid: 501),
         ProcessInfoRow(pid: 11, name: "root", cpuPercent: 0, memoryBytes: nil, uid: 0),
         ProcessInfoRow(pid: 12, name: "service", cpuPercent: nil, memoryBytes: nil, uid: 262),
         ProcessInfoRow(pid: 13, name: "nobody", cpuPercent: nil, memoryBytes: nil, uid: uid_t(bitPattern: -2)),
         ProcessInfoRow(pid: 14, name: "otherPerson", cpuPercent: nil, memoryBytes: nil, uid: 502),
         ProcessInfoRow(pid: 15, name: "vanished", cpuPercent: nil, memoryBytes: nil, uid: nil)]
    }

    private func names(_ filter: ProcessFilter) -> [String] {
        rows.filter { filter.includes($0, currentUID: me) }.map(\.name)
    }

    @Test func eachPresetSelectsItsOwners() {
        #expect(names(ProcessFilter(preset: .all)).count == 6)
        #expect(names(ProcessFilter(preset: .mine)) == ["mine"])
        #expect(names(ProcessFilter(preset: .system)) == ["root", "service", "nobody"])
        #expect(names(ProcessFilter(preset: .otherUsers)) == ["otherPerson"])
    }

    @Test func hideSystemCombinesWithPresetsAndKeepsUnknownOwners() {
        #expect(names(ProcessFilter(preset: .all, hidesSystem: true))
                == ["mine", "otherPerson", "vanished"])
        #expect(names(ProcessFilter(preset: .mine, hidesSystem: true)) == ["mine"])
    }

    /// Hiding system processes while showing only them would empty the table; the switch
    /// is ignored for that preset instead.
    @Test func hideSystemDoesNotEmptyTheSystemPreset() {
        #expect(names(ProcessFilter(preset: .system, hidesSystem: true))
                == ["root", "service", "nobody"])
    }

    /// The switch is enabled only where it can change the table. Under Active it can only
    /// when system processes' CPU is readable (as root): otherwise they never show as active.
    @Test func hideSystemAppliesOnlyWhereItCanChangeTheTable() {
        func applies(_ preset: ProcessFilter.Preset, root: Bool) -> Bool {
            ProcessFilter(preset: preset, canReadSystemCPU: root).hidesSystemApplies
        }
        #expect(ProcessFilter.Preset.allCases.filter { applies($0, root: false) } == [.all])
        #expect(ProcessFilter.Preset.allCases.filter { applies($0, root: true) } == [.all, .active])
    }

    /// As root a busy system process is active, and the switch then hides it.
    @Test func hideSystemHidesActiveSystemProcessesWhenTheirCPUIsReadable() {
        let busyRoot = ProcessInfoRow(pid: 20, name: "busyRoot", cpuPercent: 4, memoryBytes: 1, uid: 0)
        let asRoot = ProcessFilter(preset: .active, hidesSystem: true, canReadSystemCPU: true)
        #expect(!asRoot.includes(busyRoot, currentUID: 0))
        #expect(ProcessFilter(preset: .active, canReadSystemCPU: true).includes(busyRoot, currentUID: 0))
    }

    @Test func disabledSwitchExplainsWhy() {
        let active = ProcessFilter(preset: .active, canReadSystemCPU: false)
        #expect(active.hideSystemHelp.contains("CPU"))
        #expect(ProcessFilter(preset: .mine).hideSystemHelp.contains("already leaves out"))
        #expect(ProcessFilter(preset: .all).hideSystemHelp.hasPrefix("Hides"))
    }

    /// CPU% arrives computed (delta / wall time), so the fixtures are computed too. A
    /// `> 0` implementation would keep the 0.01% row, which the table shows as "0.0".
    @Test func activeMeansItShowsAtLeastPointOne() {
        let wall = 1_000_000_000.0
        let busy = ProcessInfoRow(pid: 1, name: "busy", cpuPercent: 100 * 1_000_000 / wall, memoryBytes: 1)   // 0.1
        let idle = ProcessInfoRow(pid: 2, name: "idle", cpuPercent: 100 * 100_000 / wall, memoryBytes: 1)     // 0.01
        let zero = ProcessInfoRow(pid: 3, name: "zero", cpuPercent: 0, memoryBytes: 1)
        let unknown = ProcessInfoRow(pid: 4, name: "unknown", cpuPercent: nil, memoryBytes: nil)
        let active = ProcessFilter(preset: .active)
        #expect([busy, idle, zero, unknown].filter { active.includes($0, currentUID: me) }.map(\.name)
                == ["busy"])
        #expect(String(format: "%.1f", idle.cpuPercent!) == "0.0")
    }

    @Test func sectionsApplyTheFilterBeforeTheSearch() {
        let sections = ProcessTableSection.make(rows: rows, searchText: "o",
                                                filter: ProcessFilter(preset: .system),
                                                currentUID: me, sortOrder: [KeyPathComparator(\.pid)])
        // "o" alone matches root, nobody, otherPerson; the filter leaves the system two.
        #expect(sections.flatMap(\.rows).map(\.name) == ["root", "nobody"])
    }
}

struct SavedSearchesTests {
    @Test func savesTrimmedNewestFirstWithoutDuplicates() {
        var saved = SavedSearches()
        saved.save("  Safari ")
        saved.save("mds")
        saved.save("SAFARI")          // same search, other case: moves to the top, no copy
        saved.save("   ")             // ignored
        #expect(saved.queries == ["SAFARI", "mds"])
        #expect(saved.contains("safari "))
    }

    @Test func keepsOnlyTheNewestUpToTheLimit() {
        var saved = SavedSearches()
        for n in 1...(SavedSearches.limit + 3) { saved.save("q\(n)") }
        #expect(saved.queries.count == SavedSearches.limit)
        #expect(saved.queries.first == "q\(SavedSearches.limit + 3)")
        #expect(!saved.contains("q3") && saved.contains("q4"))
    }

    @Test func removeDropsOnlyThatQuery() {
        var saved = SavedSearches(["a", "b", "c"])
        saved.remove("b")
        #expect(saved.queries == ["a", "c"])
    }

    /// @AppStorage round-trips through rawValue; a query with quotes and non-ASCII must survive.
    @Test func roundTripsThroughStorageAndToleratesGarbage() {
        let saved = SavedSearches(["say \"hi\"", "Café", "pid:771"])
        #expect(SavedSearches(rawValue: saved.rawValue) == saved)
        #expect(SavedSearches(rawValue: "not json").queries.isEmpty)
    }
}
