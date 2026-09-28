import Foundation

/// The single hardware boundary. `Control/` and the UI depend only on this.
protocol FanControlling: AnyObject {
    /// Empty (not an error) on a fanless Mac. Each fan carries its current RPM.
    func discoverFans() throws -> [Fan]
    func readTemperatures() throws -> [TemperatureReading]
    /// Never writes outside the fan's safe range: IOKitSMCController refuses (throws `.writeFailed`);
    /// PrivilegedFanController's helper re-clamps and reports its own failures as `.helperRejected`.
    func setTargetRPM(fanID: Fan.ID, rpm: Int) throws
    func revertToAutomatic() throws
    /// True when the hardware reports manual fan control, whoever set it.
    func detectsConflictingController() -> Bool
}
