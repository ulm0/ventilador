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

/// App-side XPC client for the privileged helper.
// ponytail: synchronous XPC on the caller's thread; switch to async replies if the helper ever does slow work.
final class HelperClient {
    private let makeConnection: () -> NSXPCConnection
    private var connection: NSXPCConnection?

    init(makeConnection: @escaping () -> NSXPCConnection) {
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
        var replyError: String?
        try check(exchange { $0.setTargetRPM(fanID: fanID, rpm: rpm) { replyError = $0 } }, replyError)
    }

    func revertToAutomatic() throws {
        var replyError: String?
        try check(exchange { $0.revertToAutomatic { replyError = $0 } }, replyError)
    }

    func heartbeat() -> HeartbeatStatus {
        var reply = HeartbeatReply.noOverride
        guard exchange({ $0.heartbeat { reply = $0 } }) == nil else { return .helperUnreachable }
        switch reply {
        case HeartbeatReply.active: return .active
        case HeartbeatReply.revertPending: return .revertPending
        default: return .overrideEnded
        }
    }

    func invalidate() {
        connection?.invalidate()
        connection = nil
    }

    private func check(_ transportError: String?, _ replyError: String?) throws {
        if let transportError { throw FanControlError.writeFailed(detail: transportError) }
        if let replyError { throw FanControlError.helperRejected(message: replyError) }
    }

    /// One synchronous round trip. Returns the transport error message; a failed link is dropped so the next call reconnects.
    private func exchange(_ body: (FanHelperProtocol) -> Void) -> String? {
        var transportError: String?
        let link = connection ?? open()
        let proxy = link.synchronousRemoteObjectProxyWithErrorHandler { transportError = "privileged helper unavailable (\($0.localizedDescription))" }
        body(proxy as! FanHelperProtocol)
        if transportError != nil { invalidate() }
        return transportError
    }

    private func open() -> NSXPCConnection {
        let link = makeConnection()
        link.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)
        link.resume()
        connection = link
        return link
    }
}
