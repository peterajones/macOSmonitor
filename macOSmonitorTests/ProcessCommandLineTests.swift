import Testing
import Darwin
import Foundation
@testable import macOSmonitor

/// Builds a KERN_PROCARGS2-shaped buffer: native-endian Int32 argc, the exec path,
/// NUL padding, argc NUL-terminated argv strings, then environment strings. Real buffers
/// then hold NUL padding and Apple-internal strings, which `trailer` reproduces.
private func procargs(argc: Int32, execPath: String, padding: Int,
                      argv: [String], env: [String], trailer: [String] = []) -> [UInt8] {
    var bytes = withUnsafeBytes(of: argc) { Array($0) }
    bytes += Array(execPath.utf8) + [0]
    bytes += [UInt8](repeating: 0, count: padding)
    for s in argv + env { bytes += Array(s.utf8) + [0] }
    if !trailer.isEmpty {
        bytes += [0, 0, 0]
        for s in trailer { bytes += Array(s.utf8) + [0] }
    }
    return bytes
}

struct ProcessCommandLineParseTests {
    @Test func parsesArgvAndStopsBeforeEnvironment() {
        // argv[0] differs from the exec path, one arg is empty, one has spaces, and env
        // follows: ignoring argc would leak env; skipping all NULs would drop the "".
        let buffer = procargs(argc: 4, execPath: "/usr/bin/real", padding: 3,
                              argv: ["-zsh", "", "two words", "--flag=1"],
                              env: ["HOME=/Users/me", "PATH=/bin"])
        #expect(ProcessCommandLine.parse(buffer)?.arguments == ["-zsh", "", "two words", "--flag=1"])
    }

    @Test func environmentFollowsArgvAndStopsBeforeAppleStrings() {
        // A parser reading to the end would pick up the trailer; one splitting on every
        // NUL would also lose the "=" with an empty value.
        let buffer = procargs(argc: 2, execPath: "/bin/x", padding: 2,
                              argv: ["x", "-v"],
                              env: ["HOME=/Users/me", "EMPTY=", "PATH=/bin:/usr/bin"],
                              trailer: ["executable_path=/bin/x", "ptr_munge="])
        let parsed = ProcessCommandLine.parse(buffer)
        #expect(parsed?.arguments == ["x", "-v"])
        #expect(parsed?.environment == ["HOME=/Users/me", "EMPTY=", "PATH=/bin:/usr/bin"])
    }

    @Test func environmentRunningToTheEndOfTheBufferIsKept() {
        let buffer = procargs(argc: 1, execPath: "/bin/x", padding: 0,
                              argv: ["x"], env: ["A=1", "B=2"])
        #expect(ProcessCommandLine.parse(buffer)?.environment == ["A=1", "B=2"])
    }

    @Test func truncatedBufferReturnsTheArgumentsItHas() {
        var buffer = procargs(argc: 3, execPath: "/bin/x", padding: 1,
                              argv: ["x", "a"], env: [])
        buffer += Array("partial".utf8)   // third arg cut off before its NUL
        let parsed = ProcessCommandLine.parse(buffer)
        #expect(parsed?.arguments == ["x", "a", "partial"])
        #expect(parsed?.environment == [])
    }

    @Test func malformedBuffersReturnNil() {
        #expect(ProcessCommandLine.parse([]) == nil)
        #expect(ProcessCommandLine.parse([1, 0]) == nil)   // shorter than argc
        #expect(ProcessCommandLine.parse(procargs(argc: -1, execPath: "/x", padding: 0,
                                                  argv: [], env: [])) == nil)
    }

    @Test func zeroArgcGivesNoArgumentsButKeepsEnvironment() {
        let buffer = procargs(argc: 0, execPath: "/bin/x", padding: 2, argv: [], env: ["A=1"])
        #expect(ProcessCommandLine.parse(buffer) == ProcessCommandLine(arguments: [], environment: ["A=1"]))
    }
}

struct EnvironmentDisplayTests {
    @Test func deniedProcessIsUnavailable() {
        #expect(EnvironmentDisplay(nil) == .unavailable)
    }

    @Test func emptyEnvironmentIsHiddenByMacOS() {
        // What a platform binary returns: arguments readable, environment withheld.
        let commandLine = ProcessCommandLine(arguments: ["/bin/zsh"], environment: [])
        #expect(EnvironmentDisplay(commandLine) == .hiddenByMacOS)
    }

    @Test func variablesAreSortedByName() {
        let commandLine = ProcessCommandLine(arguments: ["x"],
                                             environment: ["PATH=/bin", "HOME=/Users/me", "A=1"])
        #expect(EnvironmentDisplay(commandLine) == .variables(["A=1", "HOME=/Users/me", "PATH=/bin"]))
    }
}

struct ProcInfoCommandLineTests {
    let sut = ProcInfo()

    @Test func commandLineForSelfIncludesArgvZero() {
        let commandLine = sut.commandLine(pid: getpid())
        #expect(commandLine?.arguments.first?.isEmpty == false)
        #expect(commandLine?.arguments.count == Int(CommandLine.argc))
    }

    /// The test host edits its own environment after launch, so its live environment is no
    /// oracle for the launch-time one. A child launched with a known environment is.
    /// macOS withholds the environment of Apple platform binaries (/bin/sleep shows none),
    /// so the child is an ad-hoc re-signed copy of sleep, which is not one.
    @Test func commandLineForChildMatchesWhatItWasLaunchedWith() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sleepCopy = directory.appendingPathComponent("sleep")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: sleepCopy)

        // ChildProcess, not Foundation's Process: see ChildProcess.swift for the hang it avoids.
        let codesign = try ChildProcess("/usr/bin/codesign", ["--force", "--sign", "-", sleepCopy.path])
        try #require(codesign.wait() == .exited(0))

        let child = try ChildProcess(sleepCopy.path, ["5"],
                                     environment: ["ALPHA": "1", "EMPTY": "", "PATH_LIKE": "/a:/b"])
        defer { child.kill() }

        let commandLine = sut.commandLine(pid: child.pid)
        #expect(commandLine?.arguments == [sleepCopy.path, "5"])
        // Sorted: a dictionary's environment entries come in no fixed order.
        #expect(commandLine?.environment.sorted() == ["ALPHA=1", "EMPTY=", "PATH_LIKE=/a:/b"])
    }

    /// The other half of the re-signed-copy test above: Apple's own /bin/sleep, launched with
    /// the same environment, comes back with none. The inspector's "hidden by macOS for
    /// system processes" message rests on this; if a future macOS stops withholding it,
    /// this fails and the message needs revisiting.
    @Test func platformBinaryEnvironmentIsWithheld() throws {
        let child = try ChildProcess("/bin/sleep", ["5"], environment: ["ALPHA": "1", "BETA": "2"])
        defer { child.kill() }

        let commandLine = sut.commandLine(pid: child.pid)
        #expect(commandLine?.arguments == ["/bin/sleep", "5"])   // still readable
        #expect(commandLine?.environment == [])
        #expect(EnvironmentDisplay(commandLine) == .hiddenByMacOS)
    }

    // Other users' processes refuse KERN_PROCARGS2 to a normal user; skipped under root.
    @Test(.enabled(if: getuid() != 0))
    func deniedProcessHasNoCommandLine() {
        #expect(sut.commandLine(pid: 1) == nil)   // pid 1 = launchd
    }
}
