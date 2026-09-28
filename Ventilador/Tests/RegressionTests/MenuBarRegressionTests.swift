@testable import Ventilador
import SwiftUI
import XCTest

/// The menu bar shows what the user chose next to a template icon, and remembers the choice.
@MainActor final class MenuBarRegressionTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "com.ulm0.ventilador.tests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    private let readings = [
        TemperatureReading(sourceLabel: "Battery", celsius: 31, readAt: Date()),
        TemperatureReading(sourceLabel: "CPU", celsius: 62.4, readAt: Date()),
        TemperatureReading(sourceLabel: "GPU", celsius: 47.6, readAt: Date()),
    ]

    func test_menuBar_showsNothingBesidesTheIconByDefault() {
        let settings = MenuBarSettings(defaults: freshDefaults())
        XCTAssertFalse(settings.showCPUTemperature)
        XCTAssertFalse(settings.showGPUTemperature)
        XCTAssertFalse(settings.showFanSpeed)
        XCTAssertEqual(settings.unit, .celsius)
        XCTAssertEqual(settings.text(temperatures: readings, fans: [.stub(currentRPM: 1850)]), "")
    }

    func test_menuBar_showsEachChosenReadingInOrder() {
        let settings = MenuBarSettings(defaults: freshDefaults())
        let fans = [Fan.stub(id: "0", currentRPM: 1850)]

        settings.showCPUTemperature = true
        XCTAssertEqual(settings.text(temperatures: readings, fans: fans), "CPU 62°")
        settings.showGPUTemperature = true
        XCTAssertEqual(settings.text(temperatures: readings, fans: fans), "CPU 62° GPU 48°")
        settings.showFanSpeed = true
        XCTAssertEqual(settings.text(temperatures: readings, fans: fans), "CPU 62° GPU 48° 1850 rpm")
        settings.showCPUTemperature = false
        XCTAssertEqual(settings.text(temperatures: readings, fans: fans), "GPU 48° 1850 rpm")
        settings.showGPUTemperature = false
        XCTAssertEqual(settings.text(temperatures: readings, fans: fans), "1850 rpm")
    }

    func test_menuBar_convertsToFahrenheit() {
        let settings = MenuBarSettings(defaults: freshDefaults())
        settings.showCPUTemperature = true
        settings.showGPUTemperature = true
        settings.unit = .fahrenheit
        XCTAssertEqual(settings.text(temperatures: readings, fans: []), "CPU 144° GPU 118°")
        XCTAssertEqual(TemperatureUnit.fahrenheit.convert(0), 32)
        XCTAssertEqual(TemperatureUnit.celsius.convert(100), 100)
        XCTAssertEqual(TemperatureUnit.allCases.map(\.label), ["°C", "°F"])
    }

    func test_menuBar_leavesOutWhatIsNotAvailable() {
        let settings = MenuBarSettings(defaults: freshDefaults())
        settings.showCPUTemperature = true
        settings.showGPUTemperature = true
        settings.showFanSpeed = true

        XCTAssertEqual(settings.text(temperatures: [readings[1]], fans: []), "CPU 62°", "no GPU group, no fans (fanless Mac)")
        XCTAssertEqual(settings.text(temperatures: [], fans: []), "")
    }

    func test_menuBar_showsTheFastestFanOnAMultiFanMac() {
        let settings = MenuBarSettings(defaults: freshDefaults())
        settings.showFanSpeed = true
        let fans = [Fan.stub(id: "0", currentRPM: 1800), Fan.stub(id: "1", currentRPM: 2400)]
        XCTAssertEqual(settings.text(temperatures: [], fans: fans), "2400 rpm")
    }

    func test_menuBar_remembersTheChoiceAcrossLaunches() {
        let defaults = freshDefaults()
        let first = MenuBarSettings(defaults: defaults)
        first.showCPUTemperature = true
        first.showFanSpeed = true
        first.unit = .fahrenheit

        let relaunched = MenuBarSettings(defaults: defaults)

        XCTAssertTrue(relaunched.showCPUTemperature)
        XCTAssertFalse(relaunched.showGPUTemperature)
        XCTAssertTrue(relaunched.showFanSpeed)
        XCTAssertEqual(relaunched.unit, .fahrenheit)

        relaunched.showGPUTemperature = true
        XCTAssertTrue(MenuBarSettings(defaults: defaults).showGPUTemperature)
    }

    func test_menuBar_ignoresAnUnknownSavedUnit() {
        let defaults = freshDefaults()
        defaults.set("kelvin", forKey: MenuBarSettings.Key.unit)
        XCTAssertEqual(MenuBarSettings(defaults: defaults).unit, .celsius)
    }

    /// Tests must never read or change what the real app saved (the test host shares the app's preferences domain).
    func test_menuBar_testHostNeverTouchesTheRealPreferences() {
        let keys = [MenuBarSettings.Key.cpu, MenuBarSettings.Key.gpu, MenuBarSettings.Key.fan, MenuBarSettings.Key.unit]
        let before = keys.map { UserDefaults.standard.object(forKey: $0) as? NSObject }

        let settings = MenuBarSettings()
        settings.showCPUTemperature.toggle()
        settings.showGPUTemperature.toggle()
        settings.showFanSpeed.toggle()
        settings.unit = .fahrenheit

        XCTAssertEqual(keys.map { UserDefaults.standard.object(forKey: $0) as? NSObject }, before)
        XCTAssertFalse(MenuBarSettings().showCPUTemperature, "each use starts from a clean scratch store, whatever the real app saved")
        XCTAssertEqual(MenuBarSettings().unit, .celsius)
    }

    func test_menuBar_iconIsATemplateSymbolThatFillsDuringAnOverride() {
        XCTAssertEqual(MenuBarLabel.symbolName(for: .automatic), "fan")
        XCTAssertEqual(MenuBarLabel.symbolName(for: .manual(targets: ["0": 2000])), "fan.fill")
        XCTAssertEqual(MenuBarLabel.symbolName(for: .profile("gaming")), "fan.fill")
        XCTAssertNotNil(NSImage(systemSymbolName: "fan", accessibilityDescription: nil))
        XCTAssertNotNil(NSImage(systemSymbolName: "fan.fill", accessibilityDescription: nil))
    }

    func test_menuBar_labelFollowsLiveReadingsAndSettings() {
        let h = Harness(fans: [.stub(currentRPM: 2100)], temperatures: ["CPU": 66, "GPU": 52])
        h.status.refresh()
        let label = MenuBarLabel(environment: h.env)
        XCTAssertEqual(label.text, "", "icon only until the user opts in")
        render(label)

        h.env.menuBar.showCPUTemperature = true
        h.env.menuBar.showFanSpeed = true
        XCTAssertEqual(label.text, "CPU 66° 2100 rpm")
        render(label)

        h.setTemperatures(["CPU": 71, "GPU": 52])
        h.status.refresh()
        XCTAssertEqual(label.text, "CPU 71° 2100 rpm")

        h.smc.readError = .sensorUnavailable(detail: "gone")
        h.status.refresh()
        XCTAssertEqual(label.text, "", "no stale numbers in the menu bar when sensors fail")
    }

    func test_menuBar_settingsAppearInThePopover() {
        let h = Harness()
        h.status.refresh()
        render(StatusView(environment: h.env))
        render(MenuBarSettingsView(settings: h.env.menuBar))
        XCTAssertIdentical(StatusView(environment: h.env).menuBar, h.env.menuBar)
    }
}
