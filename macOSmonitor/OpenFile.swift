import Darwin

/// One open file descriptor that isn't a TCP/UDP socket (those are listed under Ports).
struct OpenFile: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case file, directory, pipe, kqueue, unixSocket
        /// A socket of another family, e.g. "kernel control".
        case socket(String)
        /// Any other descriptor type, e.g. "shared memory".
        case other(String)

        var label: String {
            switch self {
            case .file:              "file"
            case .directory:         "dir"
            case .pipe:              "pipe"
            case .kqueue:            "kqueue"
            case .unixSocket:        "unix"
            case .socket(let name):  name
            case .other(let name):   name
            }
        }
    }

    let fd: Int32
    let kind: Kind
    /// Path for files and directories; socket path and/or peer for Unix sockets.
    let detail: String?

    /// e.g. "3  file  /dev/null", "4  unix  → /private/var/run/syslog".
    var displayText: String {
        [String(fd), kind.label, detail].compactMap { $0 }.joined(separator: "  ")
    }

    /// A Unix socket's own path, the path of the peer it's connected to, or both. Most
    /// client sockets are unnamed and only have a peer.
    static func unixSocketDetail(local: String, peer: String) -> String? {
        switch (local.isEmpty, peer.isEmpty) {
        case (false, false): "\(local) → \(peer)"
        case (false, true):  local
        case (true, false):  "→ \(peer)"
        case (true, true):   nil
        }
    }
}

/// Lists a process's open file descriptors. Implemented by `ProcInfo`; behind a protocol so
/// the model can be tested with a fake.
protocol ProcessFileProviding: Sendable {
    /// Every descriptor except TCP/UDP sockets, by fd number; nil when denied or exited.
    func openFiles(pid: pid_t) -> [OpenFile]?
}

extension ProcInfo: ProcessFileProviding {
    func openFiles(pid: pid_t) -> [OpenFile]? {
        guard let fds = fileDescriptors(pid: pid) else { return nil }
        return fds.compactMap { openFile(pid: pid, $0) }.sorted { $0.fd < $1.fd }
    }

    /// The process's descriptor table, or nil when it can't be read (another user's process,
    /// or exited). Shared with `ports(pid:)`.
    func fileDescriptors(pid: pid_t) -> [proc_fdinfo]? {
        // First call with a nil buffer asks how many bytes are needed.
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return nil }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / MemoryLayout<proc_fdinfo>.stride)
        let written = fds.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard written > 0 else { return nil }
        return Array(fds.prefix(Int(written) / MemoryLayout<proc_fdinfo>.stride))
    }

    private func openFile(pid: pid_t, _ fd: proc_fdinfo) -> OpenFile? {
        let number = fd.proc_fd
        switch Int32(fd.proc_fdtype) {
        case PROX_FDTYPE_VNODE:
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, number, PROC_PIDFDVNODEPATHINFO, &info, size) == size else {
                return OpenFile(fd: number, kind: .file, detail: nil)   // closed mid-read
            }
            let isDirectory = (info.pvip.vip_vi.vi_stat.vst_mode & S_IFMT) == S_IFDIR
            let path = Self.string(fromTuple: info.pvip.vip_path)
            return OpenFile(fd: number, kind: isDirectory ? .directory : .file,
                            detail: path.isEmpty ? nil : path)

        case PROX_FDTYPE_SOCKET:
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, number, PROC_PIDFDSOCKETINFO, &info, size) == size else {
                return OpenFile(fd: number, kind: .socket("socket"), detail: nil)
            }
            switch info.psi.soi_kind {
            case Int32(SOCKINFO_TCP), Int32(SOCKINFO_IN):
                return nil                                   // listed under Ports
            case Int32(SOCKINFO_UN):
                let un = info.psi.soi_proto.pri_un
                return OpenFile(fd: number, kind: .unixSocket, detail: OpenFile.unixSocketDetail(
                    local: Self.string(fromTuple: un.unsi_addr.ua_sun.sun_path),
                    peer: Self.string(fromTuple: un.unsi_caddr.ua_sun.sun_path)))
            case Int32(SOCKINFO_KERN_CTL):   return OpenFile(fd: number, kind: .socket("kernel control"), detail: nil)
            case Int32(SOCKINFO_KERN_EVENT): return OpenFile(fd: number, kind: .socket("kernel event"), detail: nil)
            case Int32(SOCKINFO_NDRV):       return OpenFile(fd: number, kind: .socket("raw network"), detail: nil)
            default:                         return OpenFile(fd: number, kind: .socket("socket"), detail: nil)
            }

        case PROX_FDTYPE_PIPE:     return OpenFile(fd: number, kind: .pipe, detail: nil)
        case PROX_FDTYPE_KQUEUE:   return OpenFile(fd: number, kind: .kqueue, detail: nil)
        case PROX_FDTYPE_PSHM:     return OpenFile(fd: number, kind: .other("shared memory"), detail: nil)
        case PROX_FDTYPE_PSEM:     return OpenFile(fd: number, kind: .other("semaphore"), detail: nil)
        case PROX_FDTYPE_FSEVENTS: return OpenFile(fd: number, kind: .other("fsevents"), detail: nil)
        case PROX_FDTYPE_NETPOLICY: return OpenFile(fd: number, kind: .other("network policy"), detail: nil)
        case PROX_FDTYPE_CHANNEL:  return OpenFile(fd: number, kind: .other("channel"), detail: nil)
        case PROX_FDTYPE_NEXUS:    return OpenFile(fd: number, kind: .other("nexus"), detail: nil)
        default:                   return OpenFile(fd: number, kind: .other("other"), detail: nil)
        }
    }

    /// A NUL-terminated C string held in a fixed-size C array, which Swift imports as a tuple.
    private static func string<T>(fromTuple tuple: T) -> String {
        withUnsafeBytes(of: tuple) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
