@testable import Ventilador
import AppKit
import ServiceManagement
import XCTest

/// What the popover shows in each spec state (asserted on `sections`, including the text of every row),
/// and that every state renders.
@MainActor final class ViewRenderingRegressionTests: XCTestCase {
    private let twoFanRows: [StatusSection] = [
        .fan(label: "Fan 1", value: "1200 RPM"), .fan(label: "Fan 2", value: "1200 RPM"), .temperature(label: "CPU", value: "60 °C"),
    ]

    func test_popover_loadingState() {
        let h = Harness()
        XCTAssertEqual(StatusView(environment: h.env).sections, [.readingSensors])
        render(StatusView(environment: h.env))
    }

    func test_testHostStaysInert() {
        XCTAssertTrue(AppEnvironment.isHostingTests)
        XCTAssertFalse(AppEnvironment.showsMenuBarIcon, "test runs must not flash a menu-bar icon on the user's screen")
    }

    func test_popover_quitButtonIsWiredToQuit() {
        var quits = 0
        let view = StatusView(environment: Harness().env) { quits += 1 }
        render(view)
        view.quit()
        XCTAssertEqual(quits, 1)
    }

    func test_popover_helperStatesGateFanControls() {
        let expected: [(SMAppService.Status, [StatusSection])] = [
            (.enabled, twoFanRows + [.manualControls, .profiles]),
            (.requiresApproval, twoFanRows + [.approveHelper]),
            (.notRegistered, twoFanRows + [.enableHelper]),
            (.notFound, twoFanRows + [.enableHelper]),
        ]
        for (helper, sections) in expected {
            let h = Harness(fans: [.stub(id: "0"), .stub(id: "1")], helper: helper)
            h.status.refresh()
            XCTAssertEqual(StatusView(environment: h.env).sections, sections, "\(helper)")
            render(StatusView(environment: h.env))
        }
    }

    func test_popover_enableFanControlFailureIsShown() {
        let h = Harness(helper: .notRegistered)
        h.installer.registerError = FanControlError.helperRejected(message: "Operation not permitted")
        h.status.refresh()

        h.env.helperInstall.enable()

        XCTAssertEqual(StatusView(environment: h.env).sections,
                       [.fan(label: "Fan 1", value: "1200 RPM"), .temperature(label: "CPU", value: "60 °C"), .enableHelper, .helperError("Operation not permitted")])
        render(StatusView(environment: h.env))
    }

    /// Approving the helper in System Settings shows up as soon as the popover appears or becomes key again.
    func test_popover_refreshesHelperStatusOnAppearAndWhenItBecomesKey() {
        let h = Harness(helper: .requiresApproval)
        h.status.refresh()
        h.installer.status = .notRegistered
        render(StatusView(environment: h.env), keepAlive: true)
        XCTAssertEqual(h.env.helperInstall.status, .notRegistered, "re-read when the popover appears")

        h.installer.status = .enabled
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(h.env.helperInstall.status, .enabled)
    }

    func test_popover_errorsAreShownAfterFailClosed() {
        let h = Harness()
        h.status.refresh()
        h.store.setManual(targets: ["0": 99_999])
        h.smc.readError = .sensorUnavailable(detail: "gone")
        h.status.refresh()

        XCTAssertEqual(StatusView(environment: h.env).sections,
                       [.error("Sensor data unavailable: gone"), .lastError("Sensor data unavailable: gone")])
        render(StatusView(environment: h.env))
    }

    func test_popover_conflictWarningStaysVisibleWhenSensorsAlsoFail() {
        let h = Harness()
        h.smc.hardwareManual = true
        h.status.refresh()
        XCTAssertEqual(StatusView(environment: h.env).sections.first, .conflict)

        h.smc.readError = .sensorUnavailable(detail: "gone")
        h.status.refresh()

        XCTAssertEqual(StatusView(environment: h.env).sections,
                       [.conflict, .error("Sensor data unavailable: gone"), .lastError("Sensor data unavailable: gone")])
        render(StatusView(environment: h.env))
    }

    func test_eventLog_rendersEmptyAndPopulated() {
        let log = ControlEventLog(fileURL: temporaryLogURL())
        render(EventLogView(log: log))
        log.append(ControlEventLogEntry(timestamp: Date(), kind: .modeChanged, fanID: "0", targetRPM: 2000, detail: "Automatic → Manual (user)"))
        log.append(ControlEventLogEntry(timestamp: Date(), kind: .modeChanged, fanID: nil, targetRPM: nil, detail: "Manual → Automatic (user)"))
        render(EventLogView(log: log))
    }
}
