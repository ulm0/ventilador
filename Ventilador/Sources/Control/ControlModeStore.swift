import Combine
import Foundation

/// Owns the active ControlMode. Every write is clamped first; every failure fails closed to automatic;
/// every mode change and manual speed change is logged with its fan and value.
final class ControlModeStore: ObservableObject {
    @Published private(set) var mode: ControlMode = .automatic
    @Published private(set) var clampNotice: String?
    @Published private(set) var lastError: String?
    @Published private(set) var conflictDetected = false
    private(set) var fans: [Fan] = []
    private var temperatures: [TemperatureReading] = []
    /// What this app last wrote per fan during an override; a different hardware target means another writer.
    private var lastWritten: [Fan.ID: Int] = [:]
    private var readFailing = false
    private let controller: FanControlling
    private let log: ControlEventLog
    private let heartbeat: HeartbeatEmitting
    private let clock: () -> Date

    init(controller: FanControlling, log: ControlEventLog, heartbeat: HeartbeatEmitting, clock: @escaping () -> Date = Date.init) {
        self.controller = controller
        self.log = log
        self.heartbeat = heartbeat
        self.clock = clock
        heartbeat.onOverrideLost = { [weak self] status in self?.helperReported(status) }
    }

    // MARK: Poll results

    func ingest(fans: [Fan], temperatures: [TemperatureReading], hardwareManual: Bool) {
        self.fans = fans
        self.temperatures = temperatures
        if readFailing {
            readFailing = false
            lastError = nil
        }
        let check = mode == .automatic ? OverrideCheck.intact : checkOverride(fans)
        if check == .endedElsewhere { return overrideEndedOutsideTheApp() }
        let conflict = mode == .automatic ? hardwareManual : check == .anotherWriter
        if conflict && !conflictDetected { record(.conflictDetected, "Another process is controlling the fans") }
        conflictDetected = conflict
        if conflict && mode != .automatic {
            forceAutomatic(reason: "another process changed the fan speed")
            return
        }
        if case .profile(let id) = mode { applyProfile(id) }
    }

    /// Nothing may be written from data we could not read: the fan list and readings are dropped too.
    func ingestFailure(_ error: Error) {
        fans = []
        temperatures = []
        lastError = describe(error)
        if !readFailing {
            readFailing = true
            record(.sensorError, describe(error))
        }
        if mode != .automatic { forceAutomatic(reason: "sensor data unavailable") }
    }

    // MARK: User actions

    func setManual(targets: [Fan.ID: Int]) {
        let requests = fans.compactMap { fan in targets[fan.id].map { (fan, $0) } }
        guard !requests.isEmpty else { return }
        if case .profile = mode {
            // Fans not named here must return to Apple's curve, not stay at the profile's last speed.
            do { try controller.revertToAutomatic() } catch { return failClosed(error) }
            lastWritten = [:]
        }
        var applied: [Fan.ID: Int] = [:]
        var notices: [String] = []
        for (fan, requested) in requests {
            let rpm = clamp(target: requested, to: fan)
            if rpm != requested {
                let notice = "\(fan.label): \(requested) RPM is outside the safe range, using \(rpm) RPM"
                notices.append(notice)
                record(.clampApplied, notice, fanID: fan.id, rpm: rpm)
            }
            do { try controller.setTargetRPM(fanID: fan.id, rpm: rpm) } catch { return failClosed(error, fanID: fan.id, rpm: rpm) }
            applied[fan.id] = rpm
            lastWritten[fan.id] = rpm
        }
        var current: [Fan.ID: Int] = [:]
        if case .manual(let existing) = mode { current = existing }
        transition(to: .manual(targets: current.merging(applied) { $1 }), reason: "user", changed: applied.filter { current[$0.key] != $0.value })
        clampNotice = notices.isEmpty ? nil : notices.joined(separator: "\n")
        lastError = nil
        heartbeat.start()
    }

    func setManualForAll(rpm: Int) {
        setManual(targets: Dictionary(uniqueKeysWithValues: fans.map { ($0.id, rpm) }))
    }

    func selectProfile(_ id: FanProfile.ID) {
        guard BuiltInProfiles.find(id) != nil else { return }
        transition(to: .profile(id), reason: "user")
        clampNotice = nil
        lastError = nil
        heartbeat.start()
        applyProfile(id)
    }

    func revertToAutomatic() {
        revert(reason: "user")
    }

    // MARK: System events

    /// Overrides never silently survive sleep: the user must re-confirm after wake.
    func systemDidWake() {
        if mode != .automatic { forceAutomatic(reason: "system woke from sleep") }
    }

    func appWillTerminate() {
        if mode != .automatic { revert(reason: "app quit") }
    }

    /// The helper answered a heartbeat with anything but "active".
    func helperReported(_ status: HeartbeatStatus) {
        guard mode != .automatic else { return }
        switch status {
        case .helperUnreachable:
            let reverted = forceAutomatic(reason: "fan helper unreachable")
            lastError = reverted
                ? "Lost contact with the fan helper; fan control returned to automatic."
                : "Lost contact with the fan helper; fans may keep their last speed until it is available again."
        case .revertPending:
            endOverride(reason: "safety watchdog", message: "Returning the fans to automatic failed; the fan helper keeps retrying every second.")
        default:
            endOverride(reason: "safety watchdog", message: "The safety watchdog returned the fans to automatic control.")
        }
    }

    /// The helper can revert while the app is not running (crash, force quit); record that so the log
    /// never ends in an override that no longer exists.
    func reconcileLog() {
        guard let last = log.entries.last(where: { $0.kind == .modeChanged }), let lastMode = last.mode,
              lastMode != ControlMode.automatic.displayName else { return }
        record(.modeChanged, "\(lastMode) → Automatic (ended while the app was not running)", mode: .automatic)
    }

    // MARK: Private

    private enum OverrideCheck {
        case intact
        /// A fan we control is back in automatic mode: the helper (or the system) ended the override.
        case endedElsewhere
        /// A fan we control is still manual but holds a target we didn't write: another process drives it.
        case anotherWriter
    }

    private func checkOverride(_ fans: [Fan]) -> OverrideCheck {
        let ours = fans.filter { lastWritten[$0.id] != nil }
        if ours.contains(where: { $0.isManual == false }) { return .endedElsewhere }
        let foreign = ours.contains { fan in
            guard let target = fan.targetRPM else { return false }
            return abs(target - lastWritten[fan.id]!) > 1
        }
        return foreign ? .anotherWriter : .intact
    }

    /// Usually the helper's watchdog after a sleep gap, seen by a poll before the heartbeat reply arrives.
    private func overrideEndedOutsideTheApp() {
        endOverride(reason: "returned to automatic outside the app",
                    message: "Fan control was returned to automatic by the system or the safety watchdog.")
    }

    private func endOverride(reason: String, message: String) {
        heartbeat.stop()
        clampNotice = nil
        lastError = message
        transition(to: .automatic, reason: reason)
    }

    /// Profiles need the CPU group: driving fans from whatever cooler sensors remain would under-cool.
    private func applyProfile(_ id: FanProfile.ID) {
        guard let profile = BuiltInProfiles.find(id), !temperatures.isEmpty else { return }
        guard temperatures.contains(where: { $0.sourceLabel == TemperatureReading.cpuGroup }) else {
            return failClosed(FanControlError.sensorUnavailable(detail: "CPU temperature unavailable, profiles cannot run"))
        }
        let hottest = temperatures.map(\.celsius).max()!
        for fan in fans {
            let rpm = clamp(target: profile.targetRPM(for: fan, atCelsius: hottest), to: fan)
            do { try controller.setTargetRPM(fanID: fan.id, rpm: rpm) } catch { return failClosed(error, fanID: fan.id, rpm: rpm) }
            lastWritten[fan.id] = rpm
        }
    }

    private func revert(reason: String) {
        do {
            try controller.revertToAutomatic()
            lastError = nil
        } catch {
            lastError = describe(error)
            record(.sensorError, "Revert failed: \(describe(error))")
        }
        clampNotice = nil
        heartbeat.stop()
        transition(to: .automatic, reason: reason)
    }

    private func failClosed(_ error: Error, fanID: Fan.ID? = nil, rpm: Int? = nil) {
        lastError = describe(error)
        record(.sensorError, describe(error), fanID: fanID, rpm: rpm)
        forceAutomatic(reason: "fan control error")
    }

    /// Stops the heartbeat first: if the revert below fails, the helper's watchdog still reverts.
    @discardableResult
    private func forceAutomatic(reason: String) -> Bool {
        heartbeat.stop()
        clampNotice = nil
        var reverted = true
        do {
            try controller.revertToAutomatic()
        } catch {
            reverted = false
            record(.sensorError, "Revert failed: \(describe(error))")
        }
        transition(to: .automatic, reason: reason)
        return reverted
    }

    private func transition(to next: ControlMode, reason: String, changed: [Fan.ID: Int] = [:]) {
        let previous = mode
        mode = next
        if next == .automatic { lastWritten = [:] }
        guard previous.transitionKind(to: next) != .none else { return }
        let detail = "\(previous.displayName) → \(next.displayName) (\(reason))"
        if changed.isEmpty { record(.modeChanged, detail, mode: next) }
        for (fanID, rpm) in changed.sorted(by: { $0.key < $1.key }) {
            record(.modeChanged, detail, fanID: fanID, rpm: rpm, mode: next)
        }
    }

    private func record(_ kind: ControlEventLogEntry.Kind, _ detail: String, fanID: Fan.ID? = nil, rpm: Int? = nil, mode: ControlMode? = nil) {
        log.append(ControlEventLogEntry(timestamp: clock(), kind: kind, fanID: fanID, targetRPM: rpm, detail: detail, mode: mode?.displayName))
    }
}
