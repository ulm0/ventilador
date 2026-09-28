import Foundation

protocol HeartbeatEmitting: AnyObject {
    /// Called with the helper's answer whenever it is anything but `.active`.
    var onOverrideLost: ((HeartbeatStatus) -> Void)? { get set }
    func start()
    func stop()
}

/// The slice of ProcessInfo that holds off App Nap.
protocol ActivityHolding {
    func beginActivity(options: ProcessInfo.ActivityOptions, reason: String) -> NSObjectProtocol
    func endActivity(_ activity: NSObjectProtocol)
}

extension ProcessInfo: ActivityHolding {}

/// Proves liveness to the helper every second while an override is active. Periodic, not one-shot,
/// so a hung app stops beating and the helper reverts.
final class HeartbeatEmitter: HeartbeatEmitting {
    /// Must stay well below HelperConstants.heartbeatTimeout.
    static let defaultInterval: TimeInterval = 1
    /// Keeps App Nap from stretching the interval past the helper's timeout; idle sleep stays allowed
    /// because the helper treats a sleep gap as a reason to revert anyway.
    static let activityOptions: ProcessInfo.ActivityOptions = .userInitiatedAllowingIdleSystemSleep

    var onOverrideLost: ((HeartbeatStatus) -> Void)?
    private let interval: TimeInterval
    private let beat: () -> HeartbeatStatus
    private let activities: ActivityHolding
    private var timer: Timer?
    private var activity: NSObjectProtocol?

    init(interval: TimeInterval = HeartbeatEmitter.defaultInterval, activities: ActivityHolding = ProcessInfo.processInfo,
         beat: @escaping () -> HeartbeatStatus) {
        self.interval = interval
        self.activities = activities
        self.beat = beat
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        activity = activities.beginActivity(options: Self.activityOptions, reason: "Fan override heartbeat")
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.fire() }
        // .common keeps beating while a slider drag holds the run loop in tracking mode.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let activity { activities.endActivity(activity) }
        activity = nil
    }

    func fire() {
        let status = beat()
        if status != .active { onOverrideLost?(status) }
    }
}
