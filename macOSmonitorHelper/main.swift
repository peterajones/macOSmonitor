//
//  main.swift
//  macOSmonitorHelper
//
//  The root half of macOSmonitor: a launchd daemon (registered by the app with
//  SMAppService) that reads and signals processes the app's own user can't. It obeys only
//  the app, checked by code signature on every connection (HelperConstants.clientRequirement),
//  and only within HelperRules. HelperShared.swift is compiled into both targets.
//

import Foundation
import Darwin

final class HelperService: NSObject, PrivilegedHelperProtocol, @unchecked Sendable {
    private let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    func protocolVersion(reply: @escaping (Int) -> Void) {
        reply(HelperConstants.protocolVersion)
    }

    func sendSignal(_ signal: Int32, toPID pid: Int32, reply: @escaping (Int32) -> Void) {
        if let refusal = HelperRules.refusal(signal: signal, pid: pid, helperPID: getpid()) {
            reply(refusal)
            return
        }
        reply(kill(pid, signal) == 0 ? 0 : errno)
    }

    func taskSamples(forPIDs pids: [NSNumber], reply: @escaping (Data) -> Void) {
        var samples: [pid_t: ProcTaskSample] = [:]
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        for number in pids.prefix(4096) {
            let pid = number.int32Value
            var info = proc_taskinfo()
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { continue }
            let ticks = info.pti_total_user &+ info.pti_total_system
            samples[pid] = ProcTaskSample(residentBytes: info.pti_resident_size,
                                          cpuTimeNanos: ticks &* UInt64(timebase.numer) / UInt64(timebase.denom))
        }
        reply(HelperWire.encodeSamples(samples))
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = HelperService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Every message on this connection is checked against the app's signature; a caller
        // that isn't macOSmonitor signed by Peter's team is cut off before any method runs.
        connection.setCodeSigningRequirement(HelperConstants.clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: PrivilegedHelperProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()
dispatchMain()
