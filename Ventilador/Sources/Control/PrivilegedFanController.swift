import Foundation

/// App-side controller: reads go straight to SMC (no privileges needed), writes go to the root helper.
final class PrivilegedFanController: FanControlling {
    private let reader: FanControlling
    private let helper: HelperClient

    init(reader: FanControlling, helper: HelperClient) {
        self.reader = reader
        self.helper = helper
    }

    func discoverFans() throws -> [Fan] { try reader.discoverFans() }
    func readTemperatures() throws -> [TemperatureReading] { try reader.readTemperatures() }
    func setTargetRPM(fanID: Fan.ID, rpm: Int) throws { try helper.setTargetRPM(fanID: fanID, rpm: rpm) }
    func revertToAutomatic() throws { try helper.revertToAutomatic() }
    func detectsConflictingController() -> Bool { reader.detectsConflictingController() }
}
