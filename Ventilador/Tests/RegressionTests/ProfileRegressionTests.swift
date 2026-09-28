@testable import Ventilador
import XCTest

/// spec.md User Story 3 — Apply a Named Fan Profile (FR-008/009, FR-013).
@MainActor final class ProfileRegressionTests: XCTestCase {
    // US3 Acceptance Scenario 1 — Balanced: (50,0) (70,0.35) (85,0.75) (95,1) over a 1000–4900 RPM fan
    func test_profile_followsCurveAsTemperatureChanges() {
        let h = Harness(temperatures: ["CPU": 50])
        h.status.refresh()

        h.store.selectProfile("balanced")
        XCTAssertEqual(h.smc.targets, ["0": 1000], "applied immediately, not on the next poll")
        XCTAssertEqual(h.store.mode.displayName, "Balanced")
        XCTAssertTrue(h.heartbeat.isRunning)

        h.setTemperatures(["CPU": 60, "GPU": 77.5])
        h.status.refresh()
        XCTAssertEqual(h.smc.targets, ["0": 3145], "hottest group drives the curve, interpolated")

        h.setTemperatures(["CPU": 85])
        h.status.refresh()
        XCTAssertEqual(h.smc.targets, ["0": 3925])

        h.setTemperatures(["CPU": 105])
        h.status.refresh()
        XCTAssertEqual(h.smc.targets, ["0": 4900], "never beyond the fan's safe maximum")
        XCTAssertEqual(h.log.filter { $0.kind == .modeChanged }.count, 1, "curve-driven speed changes are not manual changes")
    }

    // US3 Acceptance Scenario 2
    func test_profile_stopsInfluencingSpeed_onModeSwitch() {
        let h = Harness(temperatures: ["CPU": 85])
        h.status.refresh()
        h.store.selectProfile("quiet")
        XCTAssertEqual(h.smc.targets, ["0": 2885])

        h.store.selectProfile("performance")
        XCTAssertEqual(h.smc.targets, ["0": 4900], "the new profile's curve takes over at once")
        XCTAssertEqual(h.log.last?.detail, "Quiet → Performance (user)")

        h.store.setManual(targets: ["0": 2000])
        h.setTemperatures(["CPU": 95])
        h.status.refresh()
        XCTAssertEqual(h.smc.targets, ["0": 2000], "manual mode ignores the curve")

        h.store.selectProfile("balanced")
        h.store.revertToAutomatic()
        let writes = h.smc.writes.count
        h.status.refresh()
        XCTAssertEqual(h.smc.writes.count, writes, "automatic mode writes nothing")
        XCTAssertEqual(h.store.mode, .automatic)
    }

    func test_profile_selectionClearsNoticesFromEarlierOverrides() {
        let h = Harness(temperatures: ["CPU": 70])
        h.status.refresh()
        h.store.setManual(targets: ["0": 9000])
        XCTAssertNotNil(h.store.clampNotice)
        h.smc.writeError = .writeFailed(detail: "transient")
        h.store.setManual(targets: ["0": 2000])
        XCTAssertNotNil(h.store.lastError)
        h.smc.writeError = nil

        h.store.setManual(targets: ["0": 9000])
        h.store.selectProfile("balanced")

        XCTAssertNil(h.store.clampNotice, "a manual clamp notice doesn't belong to the profile")
        h.smc.writeError = .writeFailed(detail: "transient")
        h.store.setManual(targets: ["0": 2000])
        h.smc.writeError = nil
        h.store.selectProfile("balanced")
        XCTAssertNil(h.store.lastError, "a successful selection clears the earlier error")
    }

    /// Gaming cools ahead of the load: a high floor at idle, full speed by 70 °C (fan range 1000–4900 RPM).
    func test_profile_gamingCoolsAheadOfTheLoad() {
        let h = Harness(temperatures: ["CPU": 35, "GPU": 35])
        h.status.refresh()

        h.store.selectProfile("gaming")
        XCTAssertEqual(h.smc.targets, ["0": 2560], "40% of the range even at idle")
        XCTAssertEqual(h.store.mode.displayName, "Gaming")

        h.setTemperatures(["CPU": 55, "GPU": 61])
        h.status.refresh()
        XCTAssertEqual(h.smc.targets, ["0": 4374], "the hotter of CPU and GPU drives it: 61 °C → 0.865")

        h.setTemperatures(["CPU": 70, "GPU": 50])
        h.status.refresh()
        XCTAssertEqual(h.smc.targets, ["0": 4900], "full speed at 70 °C")
        XCTAssertGreaterThan(BuiltInProfiles.gaming.evaluate(atCelsius: 40), BuiltInProfiles.performance.evaluate(atCelsius: 40))
        XCTAssertGreaterThan(BuiltInProfiles.gaming.evaluate(atCelsius: 60), BuiltInProfiles.performance.evaluate(atCelsius: 60))
    }

    func test_profile_reselectingTheSameProfileIsNotLogged() {
        let h = Harness()
        h.status.refresh()
        h.store.selectProfile("quiet")
        h.store.selectProfile("quiet")
        XCTAssertEqual(h.log.filter { $0.kind == .modeChanged }.count, 1)
    }

    // FR-013 during profile control
    func test_profile_staleReadingRevertsToAutomatic() {
        let h = Harness(temperatures: ["CPU": 70])
        h.status.refresh()
        h.store.selectProfile("balanced")

        h.setTemperatures(["CPU": 70], age: 30)
        h.status.refresh()

        XCTAssertEqual(h.store.mode, .automatic)
        XCTAssertFalse(h.heartbeat.isRunning)
        XCTAssertEqual(h.smc.revertCount, 1)
    }

    func test_profile_writeFailureFailsClosed() {
        let h = Harness(temperatures: ["CPU": 70])
        h.status.refresh()
        h.smc.writeError = .writeFailed(detail: "rejected")

        h.store.selectProfile("balanced")

        XCTAssertEqual(h.store.mode, .automatic)
        XCTAssertEqual(h.store.lastError, "Fan control failed: rejected")
        XCTAssertFalse(h.heartbeat.isRunning)
    }

    /// SAFETY-4: without the CPU group the curve would be driven by cooler sensors — fail closed instead.
    func test_profile_withoutCPUReadingsFailsClosed() {
        let h = Harness(temperatures: ["CPU": 70])
        h.status.refresh()
        h.store.selectProfile("quiet")

        h.setTemperatures(["Battery": 35, "GPU": 40])
        h.status.refresh()

        XCTAssertEqual(h.store.mode, .automatic)
        XCTAssertEqual(h.store.lastError, "Sensor data unavailable: CPU temperature unavailable, profiles cannot run")
        XCTAssertFalse(h.heartbeat.isRunning)
    }

    func test_profile_unknownProfileIsIgnored() {
        let h = Harness()
        h.status.refresh()
        h.store.selectProfile("turbo")
        XCTAssertEqual(h.store.mode, .automatic)
        XCTAssertFalse(h.heartbeat.isRunning)
    }

    func test_profile_waitsForTemperaturesBeforeWriting() {
        let h = Harness(temperatures: ["CPU": 60])
        h.store.selectProfile("quiet")
        XCTAssertTrue(h.smc.writes.isEmpty, "no readings yet, nothing to evaluate")
        h.status.refresh()
        XCTAssertEqual(h.smc.targets, ["0": 1244], "Quiet at 60 °C = 0.0625 of a 1000–4900 RPM span")
    }

    func test_profile_pickerButtonsSelectTheirProfile() {
        let h = Harness()
        h.status.refresh()
        let picker = ProfilePickerView(store: h.store)

        picker.selectAction("performance")()

        XCTAssertEqual(h.store.mode, .profile("performance"))
        render(picker)
        render(StatusView(environment: h.env))
    }
}
