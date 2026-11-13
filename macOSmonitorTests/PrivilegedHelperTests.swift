import Testing
import Foundation
import Darwin
@testable import macOSmonitor

/// Stands in for the installed helper.
final class FakePrivilegedAccess: PrivilegedProcessAccess, @unchecked Sendable {
    var samples: [pid_t: ProcTaskSample] = [:]
    var signalResult: Int32? = 0                 // errno from the helper; nil = helper unavailable
    private(set) var askedForSamples: [[pid_t]] = []
    private(set) var signalsSent: [(signal: Int32, pid: pid_t)] = []
    func taskSamples(pids: [pid_t]) async -> [pid_t: ProcTaskSample] {
        askedForSamples.append(pids)
        return samples.filter { pids.contains($0.key) }
    }
    func sendSignal(_ signal: Int32, to pid: pid_t) -> Int32? {
        signalsSent.append((signal, pid))
        return signalResult
    }
}

/// A terminator that always gets the given answer from the kernel.
private struct FixedTerminator: ProcessTerminating {
    let result: TerminationResult
    func send(_ signal: ProcessSignal, to pid: pid_t) -> TerminationResult { result }
}

struct HelperRulesTests {
    @Test func refusesLaunchdTheKernelAndItself() {
        #expect(HelperRules.refusal(signal: SIGKILL, pid: 1, helperPID: 900) == EPERM)
        #expect(HelperRules.refusal(signal: SIGKILL, pid: 0, helperPID: 900) == EPERM)
        #expect(HelperRules.refusal(signal: SIGKILL, pid: -1, helperPID: 900) == EPERM)   // kill(-1) = everyone
        #expect(HelperRules.refusal(signal: SIGKILL, pid: 900, helperPID: 900) == EPERM)
    }

    @Test func allowsOnlyTheAppsSignals() {
        for signal in [SIGTERM, SIGKILL, SIGSTOP, SIGCONT, SIGHUP] {
            #expect(HelperRules.refusal(signal: signal, pid: 500, helperPID: 900) == nil)
        }
        #expect(HelperRules.refusal(signal: SIGSEGV, pid: 500, helperPID: 900) == EINVAL)
        #expect(HelperRules.refusal(signal: 0, pid: 500, helperPID: 900) == EINVAL)
    }

    @Test func samplesRoundTripThroughTheWireFormat() throws {
        let sent: [pid_t: ProcTaskSample] = [88: ProcTaskSample(residentBytes: 12_345, cpuTimeNanos: 6_789)]
        let decoded = try #require(HelperWire.decodeSamples(HelperWire.encodeSamples(sent)))
        #expect(decoded[88]?.residentBytes == 12_345)
        #expect(decoded[88]?.cpuTimeNanos == 6_789)
        #expect(HelperWire.decodeSamples(Data("junk".utf8)) == nil)
    }
}

final class TestClock: @unchecked Sendable { var nanos: UInt64 = 0 }

struct PrivilegedSamplingTests {
    @Test func deniedProcessesAreFilledInByTheHelper() async {
        let procs = FakeProcInfo()
        procs.pids = [1, 42]
        procs.names = [1: "launchd", 42: "mine"]
        procs.results = [42: ProcTaskSample(residentBytes: 100, cpuTimeNanos: 0)]   // 1 is denied
        let helper = FakePrivilegedAccess()
        helper.samples = [1: ProcTaskSample(residentBytes: 9_000, cpuTimeNanos: 1_000_000)]
        let clock = TestClock()
        let sampler = ProcessSampler(source: procs, apps: FakeRegularApps(), privileged: helper,
                                     now: { clock.nanos })

        let first = await sampler.sample()
        #expect(helper.askedForSamples == [[1]])          // only the denied process
        #expect(first.first { $0.pid == 1 }?.memoryBytes == 9_000)
        #expect(first.first { $0.pid == 1 }?.canTerminate == true)

        // 0.5 s of CPU over 1 s of wall time.
        helper.samples = [1: ProcTaskSample(residentBytes: 9_000, cpuTimeNanos: 501_000_000)]
        clock.nanos = 1_000_000_000
        let second = await sampler.sample()
        #expect(second.first { $0.pid == 1 }?.cpuPercent == 50)
    }

    @Test func withoutTheHelperDeniedProcessesStayBlank() async {
        let procs = FakeProcInfo()
        procs.pids = [1]
        procs.names = [1: "launchd"]
        let sampler = ProcessSampler(source: procs, apps: FakeRegularApps(), privileged: nil, now: { 0 })
        let rows = await sampler.sample()
        #expect(rows.first?.memoryBytes == nil)
        #expect(rows.first?.canTerminate == false)
    }
}

struct HelperBackedTerminatorTests {
    @Test func aDeniedSignalIsRetriedThroughTheHelper() {
        let helper = FakePrivilegedAccess()
        let terminator = HelperBackedTerminator(local: FixedTerminator(result: .denied), helper: helper)
        #expect(terminator.send(.kill, to: 77) == .success)
        #expect(helper.signalsSent.map(\.pid) == [77])
        #expect(helper.signalsSent.map(\.signal) == [SIGKILL])
    }

    @Test func theHelperIsOnlyAskedWhenTheKernelSaysNo() {
        let helper = FakePrivilegedAccess()
        let terminator = HelperBackedTerminator(local: FixedTerminator(result: .success), helper: helper)
        #expect(terminator.send(.terminate, to: 77) == .success)
        #expect(helper.signalsSent.isEmpty)
        // Other answers aren't permission problems: the helper couldn't do better.
        #expect(HelperBackedTerminator(local: FixedTerminator(result: .noSuchProcess), helper: helper)
            .send(.terminate, to: 77) == .noSuchProcess)
        #expect(HelperBackedTerminator(local: FixedTerminator(result: .refusedSelfPause), helper: helper)
            .send(.stop, to: 77) == .refusedSelfPause)
        #expect(helper.signalsSent.isEmpty)
    }

    @Test func helperAnswersMapToResults() {
        let helper = FakePrivilegedAccess()
        let terminator = HelperBackedTerminator(local: FixedTerminator(result: .denied), helper: helper)
        helper.signalResult = ESRCH
        #expect(terminator.send(.kill, to: 77) == .noSuchProcess)
        helper.signalResult = EPERM                     // the helper's own refusal (launchd, itself)
        #expect(terminator.send(.kill, to: 77) == .denied)
        helper.signalResult = nil                       // not installed or not approved
        #expect(terminator.send(.kill, to: 77) == .denied)
    }
}
