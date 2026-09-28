import Foundation

/// Stands in when AppleSMC can't be opened (e.g. a virtual machine): every read reports unsupported hardware.
final class UnavailableFanController: FanControlling {
    func discoverFans() throws -> [Fan] { throw FanControlError.unsupportedHardware }
    func readTemperatures() throws -> [TemperatureReading] { throw FanControlError.unsupportedHardware }
    func setTargetRPM(fanID: Fan.ID, rpm: Int) throws { throw FanControlError.unsupportedHardware }
    func revertToAutomatic() throws {}
    func detectsConflictingController() -> Bool { false }
}
