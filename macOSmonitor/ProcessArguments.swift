import Darwin

/// Fetches a process's command-line arguments (argv, including argv[0]). Implemented by
/// `ProcInfo`; behind a protocol so the model can be tested with a fake.
protocol ProcessArgumentProviding: Sendable {
    /// `nil` when the kernel refuses (another user's process) or the process has exited.
    func arguments(pid: pid_t) -> [String]?
}

enum ProcessArguments {
    /// Parses a `KERN_PROCARGS2` buffer. Layout: native-endian `Int32` argc, the exec path
    /// (NUL-terminated), NUL padding, then argc NUL-terminated argv strings, then the
    /// environment, which is deliberately not read. Returns `nil` for a malformed header.
    /// A truncated buffer yields the arguments present, including a final unterminated one.
    static func parse(_ buffer: [UInt8]) -> [String]? {
        let headerSize = MemoryLayout<Int32>.size
        guard buffer.count >= headerSize else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 0 else { return nil }

        var index = headerSize
        // Skip the exec path, then the padding after it. (An empty argv[0] is
        // indistinguishable from padding; the format gives no way to tell them apart.)
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        while index < buffer.count, buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        while arguments.count < Int(argc), index < buffer.count {
            let start = index
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1   // step over the terminating NUL
        }
        return arguments
    }
}

extension ProcInfo: ProcessArgumentProviding {
    func arguments(pid: pid_t) -> [String]? {
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
        return ProcessArguments.parse(Array(buffer.prefix(size)))
    }
}
