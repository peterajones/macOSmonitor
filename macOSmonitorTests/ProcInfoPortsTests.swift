import Testing
import Darwin
@testable import macOSmonitor

struct ProcInfoPortsTests {
    @Test func portsIncludesOurTCPListener() throws {
        // Open a real TCP listener on 127.0.0.1:<ephemeral>.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bindRc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(bindRc == 0)
        #expect(listen(fd, 1) == 0)

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        let port = UInt16(bigEndian: bound.sin_port)

        let ports = ProcInfo().ports(pid: getpid())
        let match = ports.first { $0.protocolName == "TCP" && $0.localPort == port }
        #expect(match != nil)
        #expect(match?.state == "LISTEN")
        #expect(match?.localAddress == "127.0.0.1")
        #expect(match?.remoteAddress == nil)   // listening: no peer
    }
}
