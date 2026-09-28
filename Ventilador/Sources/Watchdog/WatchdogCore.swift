import Foundation

/// Continuous monotonic time as a Date: keeps counting through sleep (so sleep gaps are visible) and
/// ignores wall-clock steps (so an NTP or manual clock change can't mask a hang).
func monotonicNow() -> Date {
    Date(timeIntervalSinceReferenceDate: TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000)
}

/// Decides when the helper must return fans to automatic control. Pure logic; the caller supplies time.
struct WatchdogCore {
    let timeout: TimeInterval
    private(set) var overrideActive = false
    /// A revert failed: every tick asks for another attempt until one succeeds.
    private(set) var revertPending = false
    private var lastHeartbeat = Date.distantPast
    private var lastTick: Date?

    init(timeout: TimeInterval = HelperConstants.heartbeatTimeout) {
        self.timeout = timeout
    }

    mutating func overrideStarted(at now: Date) {
        overrideActive = true
        revertPending = false
        lastHeartbeat = now
    }

    mutating func revertSucceeded() {
        overrideActive = false
        revertPending = false
    }

    mutating func revertFailed() {
        overrideActive = false
        revertPending = true
    }

    /// Returns whether an override is still active, so the app learns about reverts it missed.
    mutating func heartbeat(at now: Date) -> Bool {
        lastHeartbeat = now
        return overrideActive
    }

    /// True when a revert must be attempted now: a previous revert failed, heartbeats stopped (app
    /// crashed or hung), or time jumped between ticks (the whole system was asleep or suspended).
    mutating func tick(at now: Date) -> Bool {
        defer { lastTick = now }
        if revertPending { return true }
        guard overrideActive else { return false }
        let heartbeatLost = now.timeIntervalSince(lastHeartbeat) > timeout
        let suspended = lastTick.map { now.timeIntervalSince($0) > timeout } ?? false
        return heartbeatLost || suspended
    }
}
