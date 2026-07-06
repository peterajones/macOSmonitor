import Testing
@testable import macOSmonitor

struct ProcessPortTests {
    @Test func displayTextListeningTCP() {
        let p = ProcessPort(protocolName: "TCP", localAddress: "*", localPort: 443,
                            remoteAddress: nil, remotePort: nil, state: "LISTEN")
        #expect(p.displayText == "TCP  *:443 (LISTEN)")
    }

    @Test func displayTextConnectedTCP() {
        let p = ProcessPort(protocolName: "TCP", localAddress: "127.0.0.1", localPort: 8080,
                            remoteAddress: "93.184.216.34", remotePort: 443, state: "ESTABLISHED")
        #expect(p.displayText == "TCP  127.0.0.1:8080 → 93.184.216.34:443 (ESTABLISHED)")
    }

    @Test func displayTextUDPNoState() {
        let p = ProcessPort(protocolName: "UDP", localAddress: "*", localPort: 5353,
                            remoteAddress: nil, remotePort: nil, state: nil)
        #expect(p.displayText == "UDP  *:5353")
    }
}
