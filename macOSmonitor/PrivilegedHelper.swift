import Foundation
import Observation
import ServiceManagement

/// What the root helper can do for the app. Behind a protocol so the sampler and terminator
/// can be tested without installing anything.
protocol PrivilegedProcessAccess: Sendable {
    /// Memory and CPU time for processes the app may not read; empty when the helper isn't
    /// running (not installed, not approved, or it didn't answer).
    func taskSamples(pids: [pid_t]) async -> [pid_t: ProcTaskSample]
    /// Sends `signal` as root. 0 on success, an errno on failure, nil when the helper isn't
    /// available. Synchronous: it backs a user's confirmed Quit, never a timer.
    func sendSignal(_ signal: Int32, to pid: pid_t) -> Int32?
    /// The inspector's data for a process the app may not read; nil when the helper isn't
    /// available or the process is gone.
    func inspect(pid: pid_t) async -> PrivilegedInspection?
    /// Every process's sockets, read as root; nil when the helper isn't available (or is an
    /// older version without this call).
    func allPorts() async -> [pid_t: [ProcessPort]]?
}

/// Talks to the installed helper over XPC. Every call checks the registration first, so an
/// app without the helper approved never waits on a connection that can't succeed.
final class PrivilegedHelperClient: PrivilegedProcessAccess, @unchecked Sendable {
    static let shared = PrivilegedHelperClient()

    private let lock = NSLock()
    private var connection: NSXPCConnection?

    var isEnabled: Bool { SMAppService.daemon(plistName: HelperConstants.plistName).status == .enabled }

    func taskSamples(pids: [pid_t]) async -> [pid_t: ProcTaskSample] {
        guard isEnabled, !pids.isEmpty else { return [:] }
        return await withCheckedContinuation { continuation in
            let once = Once()
            let proxy = connect().remoteObjectProxyWithErrorHandler { [weak self] _ in
                self?.reset()
                if once.claim() { continuation.resume(returning: [:]) }
            } as? PrivilegedHelperProtocol
            guard let proxy else {
                if once.claim() { continuation.resume(returning: [:]) }
                return
            }
            proxy.taskSamples(forPIDs: pids.map { NSNumber(value: $0) }) { data in
                if once.claim() { continuation.resume(returning: HelperWire.decodeSamples(data) ?? [:]) }
            }
        }
    }

    func sendSignal(_ signal: Int32, to pid: pid_t) -> Int32? {
        guard isEnabled else { return nil }
        var answer: Int32?
        let proxy = connect().synchronousRemoteObjectProxyWithErrorHandler { [weak self] _ in
            self?.reset()
        } as? PrivilegedHelperProtocol
        proxy?.sendSignal(signal, toPID: pid) { answer = $0 }
        return answer
    }

    func inspect(pid: pid_t) async -> PrivilegedInspection? {
        guard isEnabled else { return nil }
        return await withCheckedContinuation { continuation in
            let once = Once()
            let proxy = connect().remoteObjectProxyWithErrorHandler { [weak self] _ in
                self?.reset()
                if once.claim() { continuation.resume(returning: nil) }
            } as? PrivilegedHelperProtocol
            guard let proxy else {
                if once.claim() { continuation.resume(returning: nil) }
                return
            }
            proxy.inspect(pid: pid) { data in
                if once.claim() { continuation.resume(returning: HelperWire.decodeInspection(data)) }
            }
        }
    }

    func allPorts() async -> [pid_t: [ProcessPort]]? {
        guard isEnabled else { return nil }
        return await withCheckedContinuation { continuation in
            let once = Once()
            let proxy = connect().remoteObjectProxyWithErrorHandler { [weak self] _ in
                self?.reset()
                if once.claim() { continuation.resume(returning: nil) }
            } as? PrivilegedHelperProtocol
            guard let proxy else {
                if once.claim() { continuation.resume(returning: nil) }
                return
            }
            proxy.allPorts { data in
                if once.claim() { continuation.resume(returning: HelperWire.decodePorts(data)) }
            }
        }
    }

    /// The helper's protocol version, or nil when it doesn't answer.
    func protocolVersion() async -> Int? {
        guard isEnabled else { return nil }
        return await withCheckedContinuation { continuation in
            let once = Once()
            let proxy = connect().remoteObjectProxyWithErrorHandler { [weak self] _ in
                self?.reset()
                if once.claim() { continuation.resume(returning: nil) }
            } as? PrivilegedHelperProtocol
            proxy?.protocolVersion { version in
                if once.claim() { continuation.resume(returning: version) }
            }
        }
    }

    private func connect() -> NSXPCConnection {
        lock.lock(); defer { lock.unlock() }
        if let connection { return connection }
        let connection = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: PrivilegedHelperProtocol.self)
        // Only talk to our own helper: a process squatting on the service name gets nothing.
        connection.setCodeSigningRequirement(HelperConstants.helperRequirement)
        connection.invalidationHandler = { [weak self] in self?.reset() }
        connection.resume()
        self.connection = connection
        return connection
    }

    private func reset() {
        lock.lock(); defer { lock.unlock() }
        connection?.invalidationHandler = nil
        connection?.invalidate()
        connection = nil
    }

    /// XPC can call both the reply and the error handler; a continuation may resume once.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
    }
}

/// Signals through the kernel first; only when the kernel says "permission denied" does it ask
/// the root helper, so the helper is never involved for the user's own processes.
struct HelperBackedTerminator: ProcessTerminating {
    var local: any ProcessTerminating = ProcessTerminator()
    var helper: (any PrivilegedProcessAccess)? = PrivilegedHelperClient.shared

    func send(_ signal: ProcessSignal, to pid: pid_t) -> TerminationResult {
        let result = local.send(signal, to: pid)
        guard result == .denied, let helper, let answer = helper.sendSignal(signal.number, to: pid) else {
            return result
        }
        switch answer {
        case 0:     return .success
        case ESRCH: return .noSuchProcess
        case EPERM: return .denied
        default:    return .failure(String(cString: strerror(answer)))
        }
    }
}

/// The helper's installation state, for the Privileged Helper window.
@MainActor
@Observable
final class PrivilegedHelperModel {
    enum State: Equatable {
        case notInstalled
        case needsApproval
        case running(version: Int?)
        case notFound
    }

    private(set) var state: State = .notInstalled
    private(set) var errorMessage: String?

    private var service: SMAppService { SMAppService.daemon(plistName: HelperConstants.plistName) }

    func refresh() async {
        switch service.status {
        case .notRegistered: state = .notInstalled
        case .requiresApproval: state = .needsApproval
        case .enabled: state = .running(version: await PrivilegedHelperClient.shared.protocolVersion())
        case .notFound: state = .notFound
        @unknown default: state = .notFound
        }
    }

    func install() async {
        errorMessage = nil
        do { try service.register() } catch { errorMessage = error.localizedDescription }
        await refresh()
    }

    func uninstall() async {
        errorMessage = nil
        do { try await service.unregister() } catch { errorMessage = error.localizedDescription }
        await refresh()
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}
