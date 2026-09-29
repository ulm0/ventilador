import Foundation

enum HeartbeatStatus: Equatable {
    case active
    /// The helper answered: this client no longer holds an override (it reverted, or another session owns it).
    case overrideEnded
    /// The helper tried to return the fans to automatic, failed, and keeps retrying every tick.
    case revertPending
    /// No answer at all: the helper crashed, was switched off, or was never installed.
    case helperUnreachable
}

/// Why a round trip failed, as the message the user will see.
private struct TransportFailure: Error, Sendable {
    let message: String
}

/// One reply slot shared between the caller and the XPC reply queue. The first outcome wins; anything that
/// arrives after the caller gave up (a late reply) is ignored.
private final class ReplyBox<T: Sendable>: @unchecked Sendable {
    private let condition = NSCondition()
    private var outcome: Result<T, TransportFailure>?

    func fulfil(_ result: Result<T, TransportFailure>) {
        condition.lock()
        if outcome == nil { outcome = result }
        condition.broadcast()
        condition.unlock()
    }

    func wait(timeout: TimeInterval) -> Result<T, TransportFailure>? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while outcome == nil {
            if !condition.wait(until: deadline) { break }
        }
        return outcome
    }
}

/// App-side XPC client for the privileged helper.
///
/// Calls are made from the main thread, so a helper that is stopped, hung or not approved must never be able
/// to freeze the app: every call waits at most `callTimeout`, and after a timeout further calls fail at once
/// for `cooldown` seconds instead of blocking again.
final class HelperClient: @unchecked Sendable {
    static let defaultCallTimeout: TimeInterval = 2
    static let defaultCooldown: TimeInterval = 10
    static let notRespondingMessage = "privileged helper not responding"

    private let makeConnection: () -> NSXPCConnection
    private let callTimeout: TimeInterval
    private let cooldown: TimeInterval
    private let now: () -> Date
    private var connection: NSXPCConnection?
    private var unresponsiveUntil: Date?

    init(callTimeout: TimeInterval = HelperClient.defaultCallTimeout, cooldown: TimeInterval = HelperClient.defaultCooldown,
         now: @escaping () -> Date = Date.init, makeConnection: @escaping () -> NSXPCConnection) {
        self.callTimeout = callTimeout
        self.cooldown = cooldown
        self.now = now
        self.makeConnection = makeConnection
    }

    static func privileged(machServiceName: String = HelperConstants.machServiceName) -> HelperClient {
        HelperClient { privilegedConnection(machServiceName: machServiceName) }
    }

    /// The root helper lives in the system (privileged) bootstrap namespace, not the user's.
    static func privilegedConnection(machServiceName: String = HelperConstants.machServiceName) -> NSXPCConnection {
        NSXPCConnection(machServiceName: machServiceName, options: .privileged)
    }

    func setTargetRPM(fanID: Fan.ID, rpm: Int) throws {
        try check(call { proxy, reply in proxy.setTargetRPM(fanID: fanID, rpm: rpm, reply: reply) })
    }

    func revertToAutomatic() throws {
        try check(call { proxy, reply in proxy.revertToAutomatic(reply: reply) })
    }

    func heartbeat() -> HeartbeatStatus {
        let result: Result<Int, TransportFailure> = call { proxy, reply in proxy.heartbeat(reply: reply) }
        guard case .success(let reply) = result else { return .helperUnreachable }
        switch reply {
        case HeartbeatReply.active: return .active
        case HeartbeatReply.revertPending: return .revertPending
        default: return .overrideEnded
        }
    }

    /// The build number the running helper reports, or nil when it doesn't answer — which is also what a helper
    /// from before this call existed looks like.
    func helperBuild() -> Int? {
        guard case .success(let build) = call({ proxy, reply in proxy.version(reply: reply) }) else { return nil }
        return build
    }

    /// `helperBuild()` over a private, short-lived connection, so it is safe off the main thread and a timeout
    /// here never puts the app's own client into its cooldown.
    func probeBuild() -> Int? {
        let probe = HelperClient(callTimeout: callTimeout, cooldown: cooldown, now: now, makeConnection: makeConnection)
        defer { probe.invalidate() }
        return probe.helperBuild()
    }

    func invalidate() {
        connection?.invalidate()
        connection = nil
    }

    private func check(_ result: Result<String?, TransportFailure>) throws {
        switch result {
        case .failure(let failure): throw FanControlError.writeFailed(detail: failure.message)
        case .success(let replyError?): throw FanControlError.helperRejected(message: replyError)
        case .success(nil): break
        }
    }

    /// One round trip. A failed or silent link is dropped so the next call reconnects (or, after a timeout, fails fast).
    private func call<T: Sendable>(_ invoke: (FanHelperProtocol, @escaping @Sendable (T) -> Void) -> Void) -> Result<T, TransportFailure> {
        if let until = unresponsiveUntil {
            guard now() >= until else { return .failure(TransportFailure(message: Self.notRespondingMessage)) }
            unresponsiveUntil = nil
        }
        let box = ReplyBox<T>()
        let link = connection ?? open()
        let proxy = link.remoteObjectProxyWithErrorHandler { error in
            box.fulfil(.failure(TransportFailure(message: "privileged helper unavailable (\(error.localizedDescription))")))
        }
        invoke(proxy as! FanHelperProtocol) { box.fulfil(.success($0)) }
        guard let result = box.wait(timeout: callTimeout) else {
            invalidate()
            unresponsiveUntil = now().addingTimeInterval(cooldown)
            return .failure(TransportFailure(message: Self.notRespondingMessage))
        }
        if case .failure = result { invalidate() }
        return result
    }

    private func open() -> NSXPCConnection {
        let link = makeConnection()
        link.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)
        link.resume()
        connection = link
        return link
    }
}
