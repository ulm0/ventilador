import Combine
import Foundation

enum TemperatureUnit: String, CaseIterable, Identifiable {
    case celsius
    case fahrenheit

    var id: String { rawValue }
    var label: String { self == .celsius ? "°C" : "°F" }

    func convert(_ celsius: Double) -> Double {
        self == .celsius ? celsius : celsius * 9 / 5 + 32
    }
}

/// What the menu bar shows next to the icon. Everything defaults to off (icon only) and persists across launches.
final class MenuBarSettings: ObservableObject {
    enum Key {
        static let cpu = "menuBar.showCPUTemperature"
        static let gpu = "menuBar.showGPUTemperature"
        static let fan = "menuBar.showFanSpeed"
        static let unit = "menuBar.temperatureUnit"
    }

    static let testHostSuite = "com.ulm0.ventilador.test-host"

    @Published var showCPUTemperature: Bool { didSet { defaults.set(showCPUTemperature, forKey: Key.cpu) } }
    @Published var showGPUTemperature: Bool { didSet { defaults.set(showGPUTemperature, forKey: Key.gpu) } }
    @Published var showFanSpeed: Bool { didSet { defaults.set(showFanSpeed, forKey: Key.fan) } }
    @Published var unit: TemperatureUnit { didSet { defaults.set(unit.rawValue, forKey: Key.unit) } }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = MenuBarSettings.defaultStore()) {
        self.defaults = defaults
        showCPUTemperature = defaults.bool(forKey: Key.cpu)
        showGPUTemperature = defaults.bool(forKey: Key.gpu)
        showFanSpeed = defaults.bool(forKey: Key.fan)
        unit = defaults.string(forKey: Key.unit).flatMap(TemperatureUnit.init(rawValue:)) ?? .celsius
    }

    /// The app's own preferences — except while hosting tests, which get a scratch store wiped on every use
    /// so a test run can never read or change what the real app saved.
    static func defaultStore() -> UserDefaults {
        guard AppEnvironment.isHostingTests else { return .standard }
        UserDefaults.standard.removePersistentDomain(forName: testHostSuite)
        return UserDefaults(suiteName: testHostSuite)!
    }

    /// e.g. "CPU 62° GPU 48° 1850 rpm". A part is left out when its reading isn't available.
    func text(temperatures: [TemperatureReading], fans: [Fan]) -> String {
        var parts: [String] = []
        if showCPUTemperature, let reading = temperatures.first(where: { $0.sourceLabel == TemperatureReading.cpuGroup }) {
            parts.append("CPU \(degrees(reading.celsius))")
        }
        if showGPUTemperature, let reading = temperatures.first(where: { $0.sourceLabel == TemperatureReading.gpuGroup }) {
            parts.append("GPU \(degrees(reading.celsius))")
        }
        if showFanSpeed, let rpm = fans.map(\.currentRPM).max() {
            parts.append("\(rpm) rpm")
        }
        return parts.joined(separator: " ")
    }

    private func degrees(_ celsius: Double) -> String {
        "\(Int(unit.convert(celsius).rounded()))°"
    }
}
