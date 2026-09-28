@testable import Ventilador
import Foundation

/// In-memory FanControlling with scriptable failures. Models real hardware closely enough for the control
/// logic: a fan in automatic mode reports Apple's own target (`Fan.stub(target:)`), a fan we wrote reports
/// our target and manual mode. Refuses out-of-range writes like the real contract, but records every
/// attempt first so tests can prove no unclamped value was ever requested.
final class MockSMCController: FanControlling {
    var fans: [Fan]
    var temperatures: [TemperatureReading] = []
    var hardwareManual = false
    var readError: FanControlError?
    var temperatureError: FanControlError?
    var writeError: FanControlError?
    var writeErrors: [Fan.ID: FanControlError] = [:]
    var revertError: FanControlError?
    /// Simulates another tool holding a fan in manual mode at its own target.
    var foreignTargets: [Fan.ID: Int] = [:]
    private(set) var attempts: [(fanID: Fan.ID, rpm: Int)] = []
    private(set) var writes: [(fanID: Fan.ID, rpm: Int, at: Date)] = []
    private(set) var targets: [Fan.ID: Int] = [:]
    private(set) var revertCount = 0
    private(set) var readCount = 0

    init(fans: [Fan]) {
        self.fans = fans
    }

    /// The helper (or the system) put the fans back on automatic without this app doing it.
    func simulateExternalRevert() {
        targets = [:]
        hardwareManual = false
    }

    func discoverFans() throws -> [Fan] {
        readCount += 1
        if let readError { throw readError }
        return fans.map { fan in
            Fan(id: fan.id, label: fan.label, currentRPM: fan.currentRPM, minSafeRPM: fan.minSafeRPM, maxSafeRPM: fan.maxSafeRPM,
                targetRPM: foreignTargets[fan.id] ?? targets[fan.id] ?? fan.targetRPM,
                isManual: foreignTargets[fan.id] != nil || targets[fan.id] != nil)!
        }
    }

    func readTemperatures() throws -> [TemperatureReading] {
        if let error = readError ?? temperatureError { throw error }
        return temperatures
    }

    func setTargetRPM(fanID: Fan.ID, rpm: Int) throws {
        attempts.append((fanID, rpm))
        if let error = writeError ?? writeErrors[fanID] { throw error }
        guard let fan = fans.first(where: { $0.id == fanID }) else { throw FanControlError.writeFailed(detail: "unknown fan \(fanID)") }
        guard (fan.minSafeRPM...fan.maxSafeRPM).contains(rpm) else { throw FanControlError.writeFailed(detail: "out of range") }
        writes.append((fanID, rpm, Date()))
        targets[fanID] = rpm
        hardwareManual = true
    }

    func revertToAutomatic() throws {
        revertCount += 1
        if let revertError { throw revertError }
        simulateExternalRevert()
    }

    func detectsConflictingController() -> Bool {
        hardwareManual
    }
}
