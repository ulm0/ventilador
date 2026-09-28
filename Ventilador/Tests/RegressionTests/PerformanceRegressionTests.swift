@testable import Ventilador
import XCTest

/// SC-001 / SC-002 timing bounds [D1]. SC-005 (first-run UX time) is a manual quickstart check.
@MainActor final class PerformanceRegressionTests: XCTestCase {
    // SC-001
    func test_liveStatus_visibleWithin2Seconds() {
        let h = Harness(fans: [.stub(currentRPM: 1400)])
        let started = Date()

        h.status.start()
        defer { h.status.stop() }

        XCTAssertTrue(waitUntil(timeout: 2) { h.status.state == .ok })
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(h.status.fans.first?.currentRPM, 1400)
    }

    // SC-002, through the real XPC path to the helper
    func test_manualOverride_beginsMovingWithin2Seconds() {
        let xpc = XPCHarness()
        let client = xpc.makeClient()
        let controller = xpc.appController(client: client)
        let heartbeat = HeartbeatEmitter(interval: 60, beat: client.heartbeat)
        let store = ControlModeStore(controller: controller, log: ControlEventLog(fileURL: temporaryLogURL()), heartbeat: heartbeat)
        defer { heartbeat.stop() }
        StatusViewModel(controller: controller, store: store).refresh()
        let requested = Date()

        store.setManual(targets: ["0": 2600])

        XCTAssertEqual(xpc.smc.value("F0Tg"), 2600)
        XCTAssertLessThan(Date().timeIntervalSince(requested), 2)
    }
}
