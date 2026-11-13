import Testing
import Foundation
import Darwin
@testable import macOSmonitor

/// Everything the helper can report about one process, with values that would show up wrong
/// if any field were dropped or swapped on the way through XPC.
private let rootInspection = PrivilegedInspection(
    details: ProcessDetails(path: "/usr/sbin/syslogd", parentPID: 1, startDate: Date(timeIntervalSince1970: 1_700_000_000),
                            threadCount: 4, user: "root", status: "Running"),
    ports: [ProcessPort(protocolName: "UDP", localAddress: "*", localPort: 514, remoteAddress: nil, remotePort: nil, state: nil)],
    commandLine: ProcessCommandLine(arguments: ["/usr/sbin/syslogd"], environment: ["SECRET=1"]),
    openFiles: [OpenFile(fd: 3, kind: .socket("UDP"), detail: "*:514"), OpenFile(fd: 4, kind: .file, detail: "/var/log/system.log")],
    threads: [ThreadInfo(id: 9, name: "main", cpuTimeNanos: 5_000, cpuPercent: 1.5)],
    usage: ProcessResourceUsage(diskBytesRead: 10, diskBytesWritten: 20, energyNanojoules: 30,
                                billedCPUNanos: 40, servicedCPUNanos: 50))

struct PrivilegedInspectionWireTests {
    /// The helper never hands over another user's environment (tokens, keys…): macOS shows a
    /// user only their own processes' environments, and the helper mustn't widen that. The
    /// rule lives in the shared type, so no helper build can send one. Arguments stay: `ps`
    /// already shows every process's command line to every user.
    @Test func environmentsAreNeverCarried() throws {
        let inspection = PrivilegedInspection(details: nil, ports: [],
                                              commandLine: ProcessCommandLine(arguments: ["/usr/sbin/x", "-v"],
                                                                              environment: ["API_TOKEN=secret"]),
                                              openFiles: nil, threads: nil, usage: nil)
        #expect(inspection.commandLine?.environment == [])
        #expect(inspection.commandLine?.arguments == ["/usr/sbin/x", "-v"])
        let wire = String(decoding: HelperWire.encodeInspection(inspection), as: UTF8.self)
        #expect(!wire.contains("API_TOKEN"))
    }

    @Test func inspectionRoundTripsThroughTheWireFormat() throws {
        let decoded = try #require(HelperWire.decodeInspection(HelperWire.encodeInspection(rootInspection)))
        #expect(decoded == rootInspection)
        #expect(HelperWire.decodeInspection(Data("junk".utf8)) == nil)
    }
}

/// Answers `inspect` from a table; counts calls.
final class FakeInspectingHelper: PrivilegedProcessAccess, @unchecked Sendable {
    var inspections: [pid_t: PrivilegedInspection] = [:]
    private(set) var inspected: [pid_t] = []
    /// Runs while the helper is "answering", before the reply arrives.
    var whileAnswering: (@Sendable () async -> Void)?
    func taskSamples(pids: [pid_t]) async -> [pid_t: ProcTaskSample] { [:] }
    func sendSignal(_ signal: Int32, to pid: pid_t) -> Int32? { nil }
    func inspect(pid: pid_t) async -> PrivilegedInspection? {
        inspected.append(pid)
        await whileAnswering?()
        return inspections[pid]
    }
}

@MainActor
struct PrivilegedInspectorModelTests {
    /// A model whose own (unprivileged) readers are all denied, like for a root process.
    private func deniedModel(helper: FakeInspectingHelper?) -> ProcessListModel {
        ProcessListModel(sampler: FakeSampler(),
                         detailProvider: FakeDetailProvider(),             // nil = denied
                         portProvider: FakePortProvider(),                 // [] = denied
                         commandLineProvider: FakeCommandLineProvider(),   // nil
                         fileProvider: FakeFileProvider(),                 // nil
                         threadProvider: FakeThreadProvider(),             // nil
                         usageProvider: FakeUsageProvider(),               // nil
                         privileged: helper)
    }

    @Test func deniedDetailsAreFilledInByTheHelper() async {
        let helper = FakeInspectingHelper()
        helper.inspections = [300: rootInspection]
        let model = deniedModel(helper: helper)
        model.selectedPID = 300
        model.refreshSelection()
        await model.refreshPrivileged()

        #expect(helper.inspected == [300])
        #expect(model.selectedDetails == rootInspection.details)
        #expect(model.selectedPorts == rootInspection.ports)
        #expect(model.selectedCommandLine == rootInspection.commandLine)
        #expect(model.selectedOpenFiles == rootInspection.openFiles)
        #expect(model.selectedThreads == rootInspection.threads)
        #expect(model.selectedUsage == rootInspection.usage)
        #expect(model.isSelectionFromHelper)
    }

    @Test func readableProcessesNeverGoToTheHelper() async {
        let helper = FakeInspectingHelper()
        let details = FakeDetailProvider()
        details.result = rootInspection.details                           // our own process: readable
        let model = ProcessListModel(sampler: FakeSampler(), detailProvider: details, privileged: helper)
        model.selectedPID = 42
        model.refreshSelection()
        await model.refreshPrivileged()
        #expect(helper.inspected.isEmpty)
        #expect(!model.isSelectionFromHelper)
    }

    @Test func withoutTheHelperDeniedStaysDenied() async {
        let model = deniedModel(helper: nil)
        model.selectedPID = 300
        model.refreshSelection()
        await model.refreshPrivileged()
        #expect(model.selectedDetails == nil)
        #expect(model.selectedUsage == nil)
    }

    @Test func anAnswerForAnEarlierSelectionIsDropped() async {
        // The helper answers asynchronously; if the selection moved meanwhile, one process's
        // details (environment included) must never show under another.
        let helper = FakeInspectingHelper()
        helper.inspections = [300: rootInspection]
        let model = deniedModel(helper: helper)
        model.selectedPID = 300
        model.refreshSelection()
        helper.whileAnswering = {
            await MainActor.run {
                model.selectedPID = 301
                model.refreshSelection()
            }
        }
        await model.refreshPrivileged()
        #expect(model.selectedDetails == nil)
        #expect(model.selectedCommandLine == nil)
    }

    @Test func helperUsageGivesRatesOnTheSecondTick() async {
        let helper = FakeInspectingHelper()
        helper.inspections = [300: rootInspection]
        let clock = FakeClock()
        let model = ProcessListModel(sampler: FakeSampler(), detailProvider: FakeDetailProvider(),
                                     usageProvider: FakeUsageProvider(), privileged: helper,
                                     now: { clock.now })
        model.selectedPID = 300
        clock.now = 1_000_000_000
        model.refreshSelection()
        await model.refreshPrivileged()
        #expect(model.selectedUsageRates == nil)

        helper.inspections = [300: PrivilegedInspection(
            details: rootInspection.details, ports: [], commandLine: nil, openFiles: nil, threads: nil,
            usage: ProcessResourceUsage(diskBytesRead: 2_010, diskBytesWritten: 20, energyNanojoules: 30))]
        clock.now = 2_000_000_000
        model.refreshSelection()
        await model.refreshPrivileged()
        #expect(model.selectedUsageRates?.readBytesPerSec == 2_000)
    }
}
