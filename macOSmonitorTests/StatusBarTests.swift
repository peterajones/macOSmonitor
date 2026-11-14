import Testing
@testable import macOSmonitor

/// The window's status bar: helper state, process count, IP address and uptime.
struct StatusBarTests {
    // MARK: Which address is "the Mac's IP"

    @Test func prefersTheBuiltInInterface() {
        let candidates = [("utun3", "10.8.0.2"), ("en1", "192.168.0.90"), ("en0", "192.168.0.81")]
        #expect(PrimaryAddress.pick(candidates) == "192.168.0.81")
    }

    @Test func fallsBackToAnotherEthernetLikeInterface() {
        #expect(PrimaryAddress.pick([("utun3", "10.8.0.2"), ("en7", "192.168.0.5")]) == "192.168.0.5")
    }

    @Test func otherwiseAnyRoutableAddress() {
        #expect(PrimaryAddress.pick([("utun3", "10.8.0.2")]) == "10.8.0.2")
    }

    @Test func skipsLoopbackAndSelfAssignedAddresses() {
        // 169.254.x.x is what macOS gives itself when DHCP fails: not a usable address.
        #expect(PrimaryAddress.pick([("lo0", "127.0.0.1"), ("en0", "169.254.10.4")]) == nil)
        #expect(PrimaryAddress.pick([("en0", "169.254.10.4"), ("en5", "192.168.2.3")]) == "192.168.2.3")
        #expect(PrimaryAddress.pick([]) == nil)
    }

    // MARK: Helper state in a few words

    @Test(arguments: [
        (PrivilegedHelperModel.State.running(version: HelperConstants.protocolVersion), "Helper running", HelperSummary.Tone.good),
        (.running(version: HelperConstants.protocolVersion - 1), "Helper out of date", .warning),
        (.running(version: nil), "Helper not answering", .bad),
        (.needsApproval, "Helper waiting for approval", .warning),
        (.notInstalled, "Helper not installed", .neutral),
        (.notFound, "Helper not installed", .neutral),
    ])
    func helperSummary(state: PrivilegedHelperModel.State, text: String, tone: HelperSummary.Tone) {
        let summary = HelperSummary(state)
        #expect(summary.text == text)
        #expect(summary.tone == tone)
    }

    // MARK: Process count

    @Test func processCountReadsNaturally() {
        #expect(StatusBarView.processCountText(1) == "1 process")
        #expect(StatusBarView.processCountText(872) == "872 processes")
        #expect(StatusBarView.processCountText(0) == "Sampling…")
    }
}
