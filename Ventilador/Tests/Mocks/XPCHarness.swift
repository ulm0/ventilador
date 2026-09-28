@testable import Ventilador
import Foundation

/// The real helper stack (HelperService → IOKitSMCController → FakeSMCConnection) behind an in-process
/// anonymous XPC listener, reached through the app's real HelperClient. The app side reads the same fake
/// SMC through a read-only view, like a non-root process reading the one real SMC.
@MainActor final class XPCHarness {
    let smc: FakeSMCConnection
    let helperClock = TestClock()
    let service: HelperService
    private nonisolated(unsafe) let listener = NSXPCListener.anonymous()
    private let delegate: HelperListenerDelegate
    private(set) var connectionsOpened = 0

    init(fans: [(min: Double, max: Double, actual: Double)] = [(1000, 4900, 1200)], ftst: Bool = false, requirement: String? = nil) {
        smc = .appleSilicon(fans: fans, ftst: ftst)
        service = HelperService(controller: IOKitSMCController(connection: smc), clock: helperClock.read)
        delegate = HelperListenerDelegate(service: service)
        if let requirement { listener.setConnectionCodeSigningRequirement(requirement) }
        listener.delegate = delegate
        listener.resume()
    }

    deinit {
        listener.invalidate()
    }

    var endpoint: NSXPCListenerEndpoint { listener.endpoint }

    func makeClient() -> HelperClient {
        HelperClient { [weak self, listener] in
            self?.connectionsOpened += 1
            return NSXPCConnection(listenerEndpoint: listener.endpoint)
        }
    }

    /// The app-side controller, as AppEnvironment.live builds it: reads via SMC, writes via the helper.
    func appController(client: HelperClient) -> PrivilegedFanController {
        PrivilegedFanController(reader: IOKitSMCController(connection: smc.readOnlyView()), helper: client)
    }

    /// Stops accepting new connections, so the next client call fails like a dead helper.
    func stopListening() {
        listener.invalidate()
    }

    /// Reads helper state under its lock, so the fake SMC is safe to inspect once this is false.
    func waitForRevert(timeout: TimeInterval = 5) -> Bool {
        waitUntil(timeout: timeout) { !service.overrideActive }
    }
}
