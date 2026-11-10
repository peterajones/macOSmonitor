import Testing
import Darwin
@testable import macOSmonitor

/// Builds a KERN_PROCARGS2-shaped buffer: native-endian Int32 argc, the exec path,
/// NUL padding, argc NUL-terminated argv strings, then environment strings.
private func procargs(argc: Int32, execPath: String, padding: Int,
                      argv: [String], env: [String]) -> [UInt8] {
    var bytes = withUnsafeBytes(of: argc) { Array($0) }
    bytes += Array(execPath.utf8) + [0]
    bytes += [UInt8](repeating: 0, count: padding)
    for s in argv + env { bytes += Array(s.utf8) + [0] }
    return bytes
}

struct ProcessArgumentsParseTests {
    @Test func parsesArgvAndStopsBeforeEnvironment() {
        // argv[0] differs from the exec path, one arg is empty, one has spaces, and env
        // follows: ignoring argc would leak env; skipping all NULs would drop the "".
        let buffer = procargs(argc: 4, execPath: "/usr/bin/real", padding: 3,
                              argv: ["-zsh", "", "two words", "--flag=1"],
                              env: ["HOME=/Users/me", "PATH=/bin"])
        #expect(ProcessArguments.parse(buffer) == ["-zsh", "", "two words", "--flag=1"])
    }

    @Test func truncatedBufferReturnsTheArgumentsItHas() {
        var buffer = procargs(argc: 3, execPath: "/bin/x", padding: 1,
                              argv: ["x", "a"], env: [])
        buffer += Array("partial".utf8)   // third arg cut off before its NUL
        #expect(ProcessArguments.parse(buffer) == ["x", "a", "partial"])
    }

    @Test func malformedBuffersReturnNil() {
        #expect(ProcessArguments.parse([]) == nil)
        #expect(ProcessArguments.parse([1, 0]) == nil)   // shorter than argc
        #expect(ProcessArguments.parse(procargs(argc: -1, execPath: "/x", padding: 0,
                                                argv: [], env: [])) == nil)
    }

    @Test func zeroArgcGivesEmptyList() {
        let buffer = procargs(argc: 0, execPath: "/bin/x", padding: 2, argv: [], env: ["A=1"])
        #expect(ProcessArguments.parse(buffer) == [])
    }
}

struct ProcInfoArgumentsTests {
    let sut = ProcInfo()

    @Test func argumentsForSelfIncludeArgvZero() {
        let args = sut.arguments(pid: getpid())
        #expect(args?.first?.isEmpty == false)
        #expect(args?.count == Int(CommandLine.argc))
    }

    // Other users' processes refuse KERN_PROCARGS2 to a normal user; skipped under root.
    @Test(.enabled(if: getuid() != 0))
    func deniedProcessHasNoArguments() {
        #expect(sut.arguments(pid: 1) == nil)   // pid 1 = launchd
    }
}
