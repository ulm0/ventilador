@testable import Ventilador
import XCTest

@MainActor final class FanValidationTests: XCTestCase {
    // T017
    func test_fan_rejectsMinGreaterThanMax() {
        XCTAssertNil(Fan(id: "0", label: "Fan 1", currentRPM: 0, minSafeRPM: 5000, maxSafeRPM: 1000))
    }

    func test_fan_acceptsEqualBoundsAndKeepsFields() {
        let fan = Fan(id: "1", label: "Fan 2", currentRPM: 1500, minSafeRPM: 2000, maxSafeRPM: 2000, targetRPM: 2000)
        XCTAssertEqual(fan?.id, "1")
        XCTAssertEqual(fan?.label, "Fan 2")
        XCTAssertEqual(fan?.currentRPM, 1500)
        XCTAssertEqual(fan?.minSafeRPM, 2000)
        XCTAssertEqual(fan?.maxSafeRPM, 2000)
        XCTAssertEqual(fan?.targetRPM, 2000)
        XCTAssertNil(Fan(id: "1", label: "Fan 2", currentRPM: 0, minSafeRPM: 0, maxSafeRPM: 1)?.targetRPM)
    }
}

@MainActor final class StalenessTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000)

    // T018
    func test_staleness_readingOlderThanThresholdIsUnavailable() {
        XCTAssertEqual(stalenessThreshold, 5)
        XCTAssertTrue(isStale(readAt: now - 5.001, asOf: now))
        XCTAssertFalse(isStale(readAt: now - 5, asOf: now), "exactly at the threshold is still current")
        XCTAssertFalse(isStale(readAt: now, asOf: now))
        XCTAssertFalse(isStale(readAt: now + 2, asOf: now), "clock skew forward is not staleness")
        XCTAssertFalse(isStale(readAt: now + 60, asOf: now), "however far forward")
        XCTAssertTrue(isStale(readAt: now - 2, asOf: now, threshold: 1))
    }
}

@MainActor final class ClampingTests: XCTestCase {
    // T031
    func test_clamp_clampsToFanMinMax() {
        let fan = Fan.stub(min: 1000, max: 4900)
        XCTAssertEqual(clamp(target: 200, to: fan), 1000)
        XCTAssertEqual(clamp(target: 9000, to: fan), 4900)
        XCTAssertEqual(clamp(target: 2500, to: fan), 2500)
        XCTAssertEqual(clamp(target: 1000, to: fan), 1000)
        XCTAssertEqual(clamp(target: 4900, to: fan), 4900)
        XCTAssertEqual(clamp(target: 3000, to: .stub(min: 2000, max: 2000)), 2000)
    }
}

@MainActor final class ControlModeTests: XCTestCase {
    // T032 — the data-model.md state machine
    func test_controlMode_transitionKinds() {
        let manualA = ControlMode.manual(targets: ["0": 2000])
        let manualB = ControlMode.manual(targets: ["0": 2500])
        XCTAssertEqual(ControlMode.automatic.transitionKind(to: .automatic), .none)
        XCTAssertEqual(ControlMode.automatic.transitionKind(to: manualA), .modeChanged)
        XCTAssertEqual(ControlMode.automatic.transitionKind(to: .profile("quiet")), .modeChanged)
        XCTAssertEqual(manualA.transitionKind(to: manualA), .none)
        XCTAssertEqual(manualA.transitionKind(to: manualB), .targetsChanged)
        XCTAssertEqual(manualA.transitionKind(to: .profile("quiet")), .modeChanged)
        XCTAssertEqual(manualA.transitionKind(to: .automatic), .modeChanged)
        XCTAssertEqual(ControlMode.profile("quiet").transitionKind(to: .profile("quiet")), .none)
        XCTAssertEqual(ControlMode.profile("quiet").transitionKind(to: .profile("balanced")), .modeChanged)
        XCTAssertEqual(ControlMode.profile("quiet").transitionKind(to: manualA), .modeChanged)
        XCTAssertEqual(ControlMode.profile("quiet").transitionKind(to: .automatic), .modeChanged)
    }

    func test_controlMode_displayNames() {
        XCTAssertEqual(ControlMode.automatic.displayName, "Automatic")
        XCTAssertEqual(ControlMode.manual(targets: [:]).displayName, "Manual")
        XCTAssertEqual(ControlMode.profile("performance").displayName, "Performance")
        XCTAssertEqual(ControlMode.profile("retired-profile").displayName, "retired-profile")
    }
}

@MainActor final class FanProfileCurveTests: XCTestCase {
    private let balanced = BuiltInProfiles.balanced

    // T041
    func test_curve_interpolatesBetweenControlPoints() {
        XCTAssertEqual(balanced.evaluate(atCelsius: 60), 0.175, accuracy: 1e-9)
        XCTAssertEqual(balanced.evaluate(atCelsius: 77.5), 0.55, accuracy: 1e-9)
        XCTAssertEqual(balanced.evaluate(atCelsius: 70), 0.35, accuracy: 1e-9, "exact control point")
        XCTAssertEqual(balanced.evaluate(atCelsius: 50), 0, "first point")
        XCTAssertEqual(BuiltInProfiles.performance.evaluate(atCelsius: 20), 0.2, "flat below the curve")
        XCTAssertEqual(balanced.evaluate(atCelsius: 130), 1, "flat above the curve")
        XCTAssertEqual(balanced.targetRPM(for: .stub(min: 1000, max: 4900), atCelsius: 85), 3925)
    }

    // T042
    func test_curve_rejectsFewerThanTwoPoints_andNonMonotonicFraction() {
        typealias P = FanProfile.Point
        XCTAssertNil(FanProfile(id: "x", name: "X", curve: []))
        XCTAssertNil(FanProfile(id: "x", name: "X", curve: [P(celsius: 50, rpmFraction: 0.5)]))
        XCTAssertNil(FanProfile(id: "x", name: "X", curve: [P(celsius: 50, rpmFraction: 0.6), P(celsius: 70, rpmFraction: 0.4)]), "slows down as it heats up")
        XCTAssertNil(FanProfile(id: "x", name: "X", curve: [P(celsius: 50, rpmFraction: 0.2), P(celsius: 50, rpmFraction: 0.4)]), "celsius must strictly increase")
        XCTAssertNil(FanProfile(id: "x", name: "X", curve: [P(celsius: 70, rpmFraction: 0.2), P(celsius: 50, rpmFraction: 0.4)]), "descending celsius would slow the fan as it heats")
        XCTAssertNil(FanProfile(id: "x", name: "X", curve: [P(celsius: 50, rpmFraction: -0.1), P(celsius: 70, rpmFraction: 0.4)]))
        XCTAssertNil(FanProfile(id: "x", name: "X", curve: [P(celsius: 50, rpmFraction: 0.1), P(celsius: 70, rpmFraction: 1.1)]))
        XCTAssertNotNil(FanProfile(id: "x", name: "X", curve: [P(celsius: 50, rpmFraction: 0.3), P(celsius: 70, rpmFraction: 0.3)]))
    }

    /// Pins every calibration point: each profile ends at full speed, so none can hold fans back when hot.
    func test_builtInProfileCurves() {
        func points(_ profile: FanProfile) -> [[Double]] { profile.curve.map { [$0.celsius, $0.rpmFraction] } }
        XCTAssertEqual(points(BuiltInProfiles.quiet), [[55, 0], [75, 0.25], [90, 0.6], [100, 1]])
        XCTAssertEqual(points(BuiltInProfiles.balanced), [[50, 0], [70, 0.35], [85, 0.75], [95, 1]])
        XCTAssertEqual(points(BuiltInProfiles.performance), [[40, 0.2], [60, 0.55], [75, 0.9], [85, 1]])
        XCTAssertEqual(points(BuiltInProfiles.gaming), [[40, 0.4], [50, 0.6], [60, 0.85], [70, 1]])
        for profile in BuiltInProfiles.all {
            XCTAssertEqual(profile.evaluate(atCelsius: 110), 1, "\(profile.name) must reach full speed at critical temperature")
        }
    }

    func test_profileSummariesDescribeTheCurve() {
        XCTAssertEqual(BuiltInProfiles.quiet.summary, "Ramps from 0% at 55 °C to 100% at 100 °C")
        XCTAssertEqual(BuiltInProfiles.gaming.summary, "Ramps from 40% at 40 °C to 100% at 70 °C")
    }

    func test_builtInProfiles() {
        XCTAssertEqual(BuiltInProfiles.all.map(\.id), ["quiet", "balanced", "performance", "gaming"])
        XCTAssertEqual(BuiltInProfiles.find("quiet")?.name, "Quiet")
        XCTAssertNil(BuiltInProfiles.find("turbo"))
    }
}

@MainActor final class ErrorMessageTests: XCTestCase {
    func test_errorsReadAsSentences() {
        XCTAssertEqual(describe(FanControlError.sensorUnavailable(detail: "x")), "Sensor data unavailable: x")
        XCTAssertEqual(describe(FanControlError.writeFailed(detail: "y")), "Fan control failed: y")
        XCTAssertEqual(describe(FanControlError.unsupportedHardware), "This Mac's fan hardware is not supported.")
        XCTAssertEqual(describe(FanControlError.helperRejected(message: "As phrased.")), "As phrased.")
        XCTAssertEqual(describe(NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "plain"])), "plain")
    }

    func test_unavailableControllerExplainsAndNeverClaimsControl() {
        let controller = UnavailableFanController()
        XCTAssertThrowsError(try controller.discoverFans())
        XCTAssertThrowsError(try controller.readTemperatures())
        XCTAssertThrowsError(try controller.setTargetRPM(fanID: "0", rpm: 2000)) { XCTAssertEqual($0 as? FanControlError, .unsupportedHardware) }
        XCTAssertNoThrow(try controller.revertToAutomatic())
        XCTAssertFalse(controller.detectsConflictingController())
    }

    func test_eventLogLineShowsFanAndValueWhenPresent() {
        let at = Date(timeIntervalSinceReferenceDate: 0)
        let time = at.formatted(date: .abbreviated, time: .standard)
        XCTAssertEqual(EventLogView.line(for: .init(timestamp: at, kind: .modeChanged, fanID: "1", targetRPM: 2400, detail: "Automatic → Manual (user)")),
                       "\(time) Automatic → Manual (user) [fan 1: 2400 RPM]")
        XCTAssertEqual(EventLogView.line(for: .init(timestamp: at, kind: .modeChanged, fanID: nil, targetRPM: nil, detail: "Manual → Quiet (user)")),
                       "\(time) Manual → Quiet (user)")
    }
}
