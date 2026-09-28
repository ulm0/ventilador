import Foundation

struct Fan: Identifiable, Equatable {
    let id: String
    let label: String
    let currentRPM: Int
    let minSafeRPM: Int
    let maxSafeRPM: Int
    /// Target the hardware holds right now (nil when unknown); reveals another writer during an override.
    let targetRPM: Int?
    /// Whether the hardware has this fan in manual mode (nil when unknown); reveals an override ended outside the app.
    let isManual: Bool?

    init?(id: String, label: String, currentRPM: Int, minSafeRPM: Int, maxSafeRPM: Int, targetRPM: Int? = nil, isManual: Bool? = nil) {
        guard minSafeRPM <= maxSafeRPM else { return nil }
        self.id = id
        self.label = label
        self.currentRPM = currentRPM
        self.minSafeRPM = minSafeRPM
        self.maxSafeRPM = maxSafeRPM
        self.targetRPM = targetRPM
        self.isManual = isManual
    }
}
