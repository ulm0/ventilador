import Foundation
import os

/// A value reachable only while holding its lock, so no code path can touch it unsynchronized.
final class Guarded<Value> {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

/// Runs inside the root helper. XPC requests (connection queues), watchdog ticks and the termination signal
/// (main queue) all go through one lock. The connection that armed an override owns it: only its heartbeats
/// keep it alive, only its disconnect or revert ends it, and other clients can't take it over.
final class HelperService: NSObject, FanHelperProtocol {
    private struct State {
        var watchdog = WatchdogCore()
        var owner: ObjectIdentifier?
        var stopping = false
    }

    let clock: () -> Date
    private let controller: FanControlling
    private let build: Int
    private let state = Guarded(State())
    private let logger = Logger(subsystem: HelperConstants.machServiceName, category: "watchdog")

    init(controller: FanControlling, build: Int = 0, clock: @escaping () -> Date = monotonicNow) {
        self.controller = controller
        self.build = build
        self.clock = clock
    }

    var overrideActive: Bool {
        state.withLock { $0.watchdog.overrideActive }
    }

    var revertPending: Bool {
        state.withLock { $0.watchdog.revertPending }
    }

    /// Unconditional return to automatic, used when the helper starts (a previous instance may have died mid-override).
    func reset(reason: String) {
        state.withLock { _ = revert(&$0, reason: reason) }
    }

    /// SIGTERM path: refuse new writes, revert, and keep retrying a failed revert (launchd allows ~20 s) before exit.
    func shutdown(attempts: Int = 20, retryDelay: TimeInterval = 0.5) {
        var remaining = attempts
        while stopAndRevert() != nil && remaining > 1 {
            remaining -= 1
            Thread.sleep(forTimeInterval: retryDelay)
        }
    }

    private func stopAndRevert() -> String? {
        state.withLock { state in
            state.stopping = true
            return revert(&state, reason: "helper stopping")
        }
    }

    func setTargetRPM(fanID: String, rpm: Int, reply: @escaping (String?) -> Void) {
        let caller = Self.currentClient()
        reply(state.withLock { state in
            if state.stopping { return "The fan helper is stopping." }
            if state.watchdog.overrideActive, state.owner != caller {
                return "Fan control is in use by another session."
            }
            do {
                guard let fan = try controller.discoverFans().first(where: { $0.id == fanID }) else {
                    throw FanControlError.writeFailed(detail: "unknown fan \(fanID)")
                }
                try controller.setTargetRPM(fanID: fanID, rpm: clamp(target: rpm, to: fan))
                state.watchdog.overrideStarted(at: clock())
                state.owner = caller
                return nil
            } catch {
                revert(&state, reason: "write failed")
                return describe(error)
            }
        })
    }

    func revertToAutomatic(reply: @escaping (String?) -> Void) {
        let caller = Self.currentClient()
        reply(state.withLock { state in
            guard !state.watchdog.overrideActive || state.owner == caller else { return nil }
            return revert(&state, reason: "client request")
        })
    }

    func heartbeat(reply: @escaping (Int) -> Void) {
        let caller = Self.currentClient()
        reply(state.withLock { state in
            guard state.owner == caller else { return HeartbeatReply.noOverride }
            if state.watchdog.revertPending { return HeartbeatReply.revertPending }
            return state.watchdog.heartbeat(at: clock()) ? HeartbeatReply.active : HeartbeatReply.noOverride
        })
    }

    func version(reply: @escaping (Int) -> Void) {
        reply(build)
    }

    func tick() {
        state.withLock { state in
            let retry = state.watchdog.revertPending
            if state.watchdog.tick(at: clock()) {
                revert(&state, reason: retry ? "retrying a failed revert" : "heartbeat lost or system slept")
            }
        }
    }

    func clientDisconnected(_ client: ObjectIdentifier) {
        state.withLock { state in
            if state.watchdog.overrideActive, state.owner == client { revert(&state, reason: "client disconnected") }
        }
    }

    /// Caller holds the lock. A failed revert stays pending (and keeps its owner, so the owner hears about it);
    /// the next tick tries again.
    @discardableResult
    private func revert(_ state: inout State, reason: String) -> String? {
        do {
            try controller.revertToAutomatic()
            state.watchdog.revertSucceeded()
            state.owner = nil
            logger.notice("Fans returned to automatic: \(reason, privacy: .public)")
            return nil
        } catch {
            state.watchdog.revertFailed()
            logger.error("Revert failed (\(reason, privacy: .public)), retrying every tick: \(describe(error), privacy: .public)")
            return describe(error)
        }
    }

    /// The XPC connection delivering the current message; nil for in-process calls.
    private static func currentClient() -> ObjectIdentifier? {
        NSXPCConnection.current().map { ObjectIdentifier($0) }
    }
}

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: HelperService
    private let requirement: (() -> String)?

    init(service: HelperService, requirement: (() -> String)? = nil) {
        self.service = service
        self.requirement = requirement
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        if let requirement { connection.setCodeSigningRequirement(requirement()) }
        connection.exportedInterface = NSXPCInterface(with: FanHelperProtocol.self)
        connection.exportedObject = service
        let client = ObjectIdentifier(connection)
        connection.invalidationHandler = { [service] in service.clientDisconnected(client) }
        connection.resume()
        return true
    }
}
