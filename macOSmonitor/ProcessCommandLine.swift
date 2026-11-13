import Darwin

/// A process's launch arguments (argv, including argv[0]) and environment ("NAME=value"),
/// as they were at exec time.
struct ProcessCommandLine: Equatable, Sendable, Codable {
    let arguments: [String]
    let environment: [String]
}

/// What the inspector's Environment section shows for a process.
enum EnvironmentDisplay: Equatable {
    /// The kernel refused the read (another user's process).
    case unavailable
    /// Readable, but empty: macOS withholds the environment of its own platform binaries
    /// (zsh, cfprefsd, …) from other processes. A genuinely empty environment is very rare.
    case hiddenByMacOS
    /// The variables, sorted by name.
    case variables([String])

    init(_ commandLine: ProcessCommandLine?) {
        guard let commandLine else { self = .unavailable; return }
        self = commandLine.environment.isEmpty ? .hiddenByMacOS : .variables(commandLine.environment.sorted())
    }
}

/// Fetches a process's command line. Implemented by `ProcInfo`; behind a protocol so the
/// model can be tested with a fake.
protocol ProcessCommandLineProviding: Sendable {
    /// `nil` when the kernel refuses (another user's process) or the process has exited.
    func commandLine(pid: pid_t) -> ProcessCommandLine?
}

extension ProcessCommandLine {
    /// Parses a `KERN_PROCARGS2` buffer. Layout: native-endian `Int32` argc, the exec path
    /// (NUL-terminated), NUL padding, argc NUL-terminated argv strings, then the environment
    /// strings, ended by an empty string. Apple-internal strings (`executable_path=`, …)
    /// follow that and are not read. Returns `nil` for a malformed header. A truncated
    /// buffer yields what is present, including a final unterminated string.
    static func parse(_ buffer: [UInt8]) -> ProcessCommandLine? {
        let headerSize = MemoryLayout<Int32>.size
        guard buffer.count >= headerSize else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 0 else { return nil }

        var index = headerSize
        // Skip the exec path, then the padding after it. (An empty argv[0] is
        // indistinguishable from padding; the format gives no way to tell them apart.)
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        while index < buffer.count, buffer[index] == 0 { index += 1 }

        /// Reads one NUL-terminated string at `index` and steps past its terminator.
        func nextString() -> String {
            let start = index
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            defer { index += 1 }
            return String(decoding: buffer[start..<index], as: UTF8.self)
        }

        var arguments: [String] = []
        while arguments.count < Int(argc), index < buffer.count {
            arguments.append(nextString())
        }

        var environment: [String] = []
        while index < buffer.count, buffer[index] != 0 {   // an empty string ends the list
            environment.append(nextString())
        }
        return ProcessCommandLine(arguments: arguments, environment: environment)
    }
}

extension ProcInfo: ProcessCommandLineProviding {
    func commandLine(pid: pid_t) -> ProcessCommandLine? {
        // KERN_ARGMAX bounds the size of any process's argument area.
        var argmax: Int32 = 0
        var argmaxSize = MemoryLayout<Int32>.size
        var argmaxMIB: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&argmaxMIB, 2, &argmax, &argmaxSize, nil, 0) == 0, argmax > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        var size = buffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        // Fails (EINVAL/EPERM) for other users' processes and for vanished PIDs.
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return ProcessCommandLine.parse(Array(buffer.prefix(size)))
    }
}
