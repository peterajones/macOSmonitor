import Testing
import Darwin
import Foundation
@testable import macOSmonitor

final class FakeFileProvider: ProcessFileProviding, @unchecked Sendable {
    var result: [OpenFile]?
    private(set) var lastPID: pid_t?
    func openFiles(pid: pid_t) -> [OpenFile]? { lastPID = pid; return result }
}

struct OpenFileTests {
    @Test func displayTextJoinsFDKindAndDetail() {
        #expect(OpenFile(fd: 3, kind: .file, detail: "/dev/null").displayText == "3  file  /dev/null")
        #expect(OpenFile(fd: 7, kind: .kqueue, detail: nil).displayText == "7  kqueue")
        #expect(OpenFile(fd: 9, kind: .socket("kernel control"), detail: nil).displayText
                == "9  kernel control")
    }

    @Test func unixSocketDetailShowsWhicheverEndsHavePaths() {
        #expect(OpenFile.unixSocketDetail(local: "", peer: "/var/run/syslog") == "→ /var/run/syslog")
        #expect(OpenFile.unixSocketDetail(local: "/tmp/s", peer: "") == "/tmp/s")
        #expect(OpenFile.unixSocketDetail(local: "/tmp/s", peer: "/tmp/p") == "/tmp/s → /tmp/p")
        #expect(OpenFile.unixSocketDetail(local: "", peer: "") == nil)
    }

    /// Integration: open one of each kind in this (test host) process and find it listed.
    @Test func classifiesThisProcesssDescriptors() throws {
        let folder = URL(fileURLWithPath: "/tmp").appending(path: "mom-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let fileURL = folder.appending(path: "log.txt")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data())
        let file = open(fileURL.path, O_RDONLY); defer { close(file) }
        let directory = open(folder.path, O_RDONLY); defer { close(directory) }
        var pipeFDs: [Int32] = [0, 0]; _ = pipe(&pipeFDs); defer { close(pipeFDs[0]); close(pipeFDs[1]) }
        let queue = kqueue(); defer { close(queue) }
        var pair: [Int32] = [0, 0]; _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &pair)
        defer { close(pair[0]); close(pair[1]) }
        let udp = socket(AF_INET, SOCK_DGRAM, 0); defer { close(udp) }

        // A named Unix socket: bound to a path, so it shows that path.
        let socketPath = folder.appending(path: "s.sock").path
        let named = socket(AF_UNIX, SOCK_STREAM, 0); defer { close(named) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: socketPath.utf8.prefix(buffer.count - 1))
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(named, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bound == 0)

        let files = try #require(ProcInfo().openFiles(pid: getpid()))
        let byFD = Dictionary(files.map { ($0.fd, $0) }, uniquingKeysWith: { a, _ in a })

        #expect(byFD[file]?.kind == .file)
        #expect(byFD[file]?.detail?.hasSuffix("/log.txt") == true)   // /tmp resolves to /private/tmp
        #expect(byFD[directory]?.kind == .directory)
        #expect(byFD[pipeFDs[0]]?.kind == .pipe)
        #expect(byFD[queue]?.kind == .kqueue)
        #expect(byFD[pair[0]]?.kind == .unixSocket)
        #expect(byFD[named]?.kind == .unixSocket)
        #expect(byFD[named]?.detail?.hasSuffix("/s.sock") == true)
        #expect(byFD[udp] == nil, "UDP belongs under Ports")
        #expect(files.map(\.fd) == files.map(\.fd).sorted())
    }

    // Only meaningful as a non-root user.
    @Test(.enabled(if: getuid() != 0))
    func deniedForRootsProcessesIsNilNotEmpty() {
        #expect(ProcInfo().openFiles(pid: 1) == nil)
    }
}

@MainActor
struct OpenFilesModelTests {
    @Test func refreshSelectionPublishesOpenFilesAndClearsWhenNoSelection() {
        let fake = FakeFileProvider()
        fake.result = [OpenFile(fd: 0, kind: .file, detail: "/dev/null")]
        let model = ProcessListModel(sampler: FakeSampler(), fileProvider: fake)

        model.selectedPID = 8
        model.refreshSelection()
        #expect(fake.lastPID == 8)
        #expect(model.selectedOpenFiles == fake.result)

        model.selectedPID = nil
        model.refreshSelection()
        #expect(model.selectedOpenFiles == nil)
    }
}
