@testable import Ventilador
import Foundation

/// A helper that is reachable but never answers in time — what a stopped, hung or unapproved daemon looks like
/// to the app. `replyDelay == nil` never replies; otherwise it replies that many seconds late.
final class SilentHelper: NSObject, FanHelperProtocol, NSXPCListenerDelegate, @unchecked Sendable {
    private let replyDelay: TimeInterval?
    private let listener = NSXPCListener.anonymous()
    private let lock = NSLock()
    private var connections = 0

    init(replyDelay: TimeInterval? = nil) {
        self.replyDelay = replyDelay
        super.init()
        listener.delegate = self
        listener.resume()
    }

    deinit {
        listener.invalidate()
    }

    var connectionsAccepted: Int {
        lock.lock()
        defer { lock.unlock() }
        return connections
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        lock.lock()
        connections += 1
        lock.unlock()
        connection.exportedInterface = NSXPCInterface(with: FanHelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func makeConnection() -> NSXPCConnection {
        NSXPCConnection(listenerEndpoint: listener.endpoint)
    }

    private func respond<T>(_ reply: @escaping (T) -> Void, with value: T) {
        guard let replyDelay else { return }
        nonisolated(unsafe) let reply = reply
        nonisolated(unsafe) let value = value
        DispatchQueue.global().asyncAfter(deadline: .now() + replyDelay) { reply(value) }
    }

    func setTargetRPM(fanID: String, rpm: Int, reply: @escaping (String?) -> Void) { respond(reply, with: nil) }
    func revertToAutomatic(reply: @escaping (String?) -> Void) { respond(reply, with: nil) }
    func heartbeat(reply: @escaping (Int) -> Void) { respond(reply, with: HeartbeatReply.active) }
}
