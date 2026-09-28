import Foundation

/// Wires the root helper process. Compiled into the app target too, so its ordering and timing are tested:
/// reset to automatic before accepting any client, tick the watchdog, check every client's signature, and
/// on the termination signal (launchd sends SIGTERM when the helper is switched off in Login Items or the
/// app is removed) stop accepting clients, revert — retrying — and only then exit.
final class HelperRuntime: @unchecked Sendable {  // immutable after init; dispatch sources are thread-safe
    /// With HelperConstants.heartbeatTimeout (3 s) this bounds a hang revert at 4 s, inside SC-003's 5 s.
    static let tickInterval: TimeInterval = 1

    private let listener: NSXPCListener
    private let delegate: HelperListenerDelegate
    private let timer: DispatchSourceTimer
    private let termination: DispatchSourceSignal
    private let terminationSignal: Int32

    init(service: HelperService, listener: NSXPCListener, clientRequirement: @escaping () -> String,
         tickInterval: TimeInterval = HelperRuntime.tickInterval, queue: DispatchQueue = .main,
         terminationSignal: Int32 = SIGTERM, exit: @escaping () -> Void) {
        self.listener = listener
        self.terminationSignal = terminationSignal
        delegate = HelperListenerDelegate(service: service, requirement: clientRequirement)
        service.reset(reason: "helper started")

        signal(terminationSignal, SIG_IGN)
        termination = DispatchSource.makeSignalSource(signal: terminationSignal, queue: queue)
        termination.setEventHandler { [listener, service] in
            listener.invalidate()
            service.shutdown()
            exit()
        }
        termination.resume()

        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + tickInterval, repeating: tickInterval)
        timer.setEventHandler { [service] in service.tick() }
        timer.resume()

        listener.delegate = delegate
        listener.resume()
    }

    func stop() {
        listener.invalidate()
        timer.cancel()
        termination.cancel()
        signal(terminationSignal, SIG_DFL)
    }
}
