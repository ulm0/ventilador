import Foundation

// Calibration knob: points are tuned against Apple Silicon CPU-group averages
// (idle ~40-50 °C, sustained load ~80-95 °C). Re-tune on target hardware.
enum BuiltInProfiles {
    static let quiet = FanProfile(id: "quiet", name: "Quiet", curve: [
        .init(celsius: 55, rpmFraction: 0),
        .init(celsius: 75, rpmFraction: 0.25),
        .init(celsius: 90, rpmFraction: 0.6),
        .init(celsius: 100, rpmFraction: 1),
    ])!

    static let balanced = FanProfile(id: "balanced", name: "Balanced", curve: [
        .init(celsius: 50, rpmFraction: 0),
        .init(celsius: 70, rpmFraction: 0.35),
        .init(celsius: 85, rpmFraction: 0.75),
        .init(celsius: 95, rpmFraction: 1),
    ])!

    static let performance = FanProfile(id: "performance", name: "Performance", curve: [
        .init(celsius: 40, rpmFraction: 0.2),
        .init(celsius: 60, rpmFraction: 0.55),
        .init(celsius: 75, rpmFraction: 0.9),
        .init(celsius: 85, rpmFraction: 1),
    ])!

    // Cools ahead of the load: a high floor from idle and full speed by 70 °C, so sustained gaming
    // never has to wait for the chip to heat up before the fans catch up.
    static let gaming = FanProfile(id: "gaming", name: "Gaming", curve: [
        .init(celsius: 40, rpmFraction: 0.4),
        .init(celsius: 50, rpmFraction: 0.6),
        .init(celsius: 60, rpmFraction: 0.85),
        .init(celsius: 70, rpmFraction: 1),
    ])!

    static let all = [quiet, balanced, performance, gaming]

    static func find(_ id: FanProfile.ID) -> FanProfile? {
        all.first { $0.id == id }
    }
}
