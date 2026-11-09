import Testing
import AppKit
import Darwin
@testable import macOSmonitor

struct ProcessTableSectionTests {
    // PID, CPU, case-sensitive-name and case-insensitive-name order all differ here,
    // so sorting the apps by any of the wrong keys gives a visibly different answer.
    private let rows = [
        ProcessInfoRow(pid: 900, name: "zoom", cpuPercent: 50, memoryBytes: 1, isApplication: true),
        ProcessInfoRow(pid: 100, name: "Mail", cpuPercent: 1, memoryBytes: 3, isApplication: true),
        ProcessInfoRow(pid: 500, name: "arc", cpuPercent: 20, memoryBytes: 2, isApplication: true),
        ProcessInfoRow(pid: 10, name: "a", cpuPercent: 1, memoryBytes: 9),
        ProcessInfoRow(pid: 20, name: "b", cpuPercent: 30, memoryBytes: 7),
        ProcessInfoRow(pid: 30, name: "c", cpuPercent: 5, memoryBytes: 8),
    ]
    private let byCPU = [KeyPathComparator(\ProcessInfoRow.cpuSortKey, order: .reverse)]

    private func pids(_ section: ProcessTableSection) -> [pid_t] { section.rows.map(\.pid) }

    @Test func applicationsComeFirstWithCountsInTheTitles() {
        let sections = ProcessTableSection.make(rows: rows, searchText: "", sortOrder: byCPU)
        #expect(sections.map(\.title) == ["Applications (3)", "Background processes (3)"])
    }

    @Test func applicationsSortByNameIgnoringCaseAndTheClickedColumn() {
        let sections = ProcessTableSection.make(rows: rows, searchText: "", sortOrder: byCPU)
        #expect(sections.first.map(pids) == [500, 100, 900])
    }

    @Test func sameNamedApplicationsKeepAFixedOrder() {
        let twins = [
            ProcessInfoRow(pid: 30, name: "Helper", cpuPercent: 0, memoryBytes: 1, isApplication: true),
            ProcessInfoRow(pid: 20, name: "Helper", cpuPercent: 0, memoryBytes: 1, isApplication: true),
        ]
        let sections = ProcessTableSection.make(rows: twins, searchText: "", sortOrder: byCPU)
        #expect(sections.first.map(pids) == [20, 30])
    }

    @Test func backgroundFollowsTheClickedColumn() {
        let sections = ProcessTableSection.make(rows: rows, searchText: "", sortOrder: byCPU)
        #expect(sections.last.map(pids) == [20, 30, 10])

        let byName = [KeyPathComparator(\ProcessInfoRow.name, order: .reverse)]
        let resorted = ProcessTableSection.make(rows: rows, searchText: "", sortOrder: byName)
        #expect(resorted.last.map(pids) == [30, 20, 10])
    }

    @Test func searchNarrowsTheCountAndHidesAnEmptyBackgroundSection() {
        let sections = ProcessTableSection.make(rows: rows, searchText: "arc", sortOrder: byCPU)
        #expect(sections.map(\.title) == ["Applications (1)"])
        #expect(sections.first.map(pids) == [500])
    }

    @Test func searchHidesAnEmptyApplicationsSection() {
        let sections = ProcessTableSection.make(rows: rows, searchText: "b", sortOrder: byCPU)
        #expect(sections.map(\.title) == ["Background processes (1)"])
    }

    @Test func noMatchesLeaveNoSections() {
        #expect(ProcessTableSection.make(rows: rows, searchText: "qqq", sortOrder: byCPU).isEmpty)
    }
}

struct RegularAppsTests {
    @Test func reportsRegularAppsAndOmitsEveryOtherKind() throws {
        let running = NSWorkspace.shared.runningApplications
        let finder = try #require(NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.finder").first)
        let nonRegular = Set(running.filter { $0.activationPolicy != .regular }.map(\.processIdentifier))

        let pids = RegularApps().regularAppPIDs()

        #expect(pids.contains(finder.processIdentifier))
        #expect(pids.isDisjoint(with: nonRegular))
    }
}
