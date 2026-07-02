import Testing
@testable import macOSmonitor

final class FakeSampler: ProcessSampling, @unchecked Sendable {
    var next: [ProcessInfoRow] = []
    private(set) var callCount = 0
    func sample() async -> [ProcessInfoRow] { callCount += 1; return next }
}

@MainActor
struct ProcessListModelTests {
    @Test func refreshOnceReplacesRowsFromSampler() async {
        let fake = FakeSampler()
        fake.next = [ProcessInfoRow(pid: 1, name: "a", cpuPercent: 12, memoryBytes: 2048)]
        let model = ProcessListModel(sampler: fake)

        #expect(model.rows.isEmpty)
        await model.refreshOnce()

        #expect(fake.callCount == 1)
        #expect(model.rows.count == 1)
        #expect(model.rows.first?.name == "a")
    }
}
