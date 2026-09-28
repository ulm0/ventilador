import Foundation

struct ControlEventLogEntry: Codable, Equatable {
    enum Kind: String, Codable {
        case modeChanged
        case clampApplied
        case sensorError
        case conflictDetected
    }

    let timestamp: Date
    let kind: Kind
    /// Required whenever the event concerns one fan (Constitution Principle IV).
    let fanID: Fan.ID?
    /// Required whenever the event has a concrete RPM (Constitution Principle IV).
    let targetRPM: Int?
    let detail: String
    /// The mode in force after a `modeChanged` event (display name); absent in older entries.
    var mode: String? = nil
}
