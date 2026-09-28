import Foundation

struct TemperatureReading: Equatable {
    /// The group profiles must see before they may drive fans.
    static let cpuGroup = "CPU"
    static let gpuGroup = "GPU"

    let sourceLabel: String
    let celsius: Double
    /// When the value was last known to be live: the read time, or for change-tracked groups the
    /// last time any of the group's raw sensor values changed.
    let readAt: Date
}
