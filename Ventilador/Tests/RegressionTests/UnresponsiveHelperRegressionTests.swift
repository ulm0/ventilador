@testable import Ventilador
import XCTest

/// A helper that is stopped, hung or not approved must never freeze the app: the app talks to it from the
/// main thread, so every call is bounded and, after a timeout, later calls fail at once.
@MainActor final class UnresponsiveHelperRegressionTests: XCTestCase {
    private let timeout: TimeInterval = 0.3
    private let clock = TestClock()

    private func elapsed(_ body: () throws -> Void) -> TimeInterval {
        let start = Date()
        try? body()
        return Date().timeIntervalSince(start)
    }

    private func client(_ helper: SilentHelper, cooldown: TimeInterval = 5) -> HelperClient {
        HelperClient(callTimeout: timeout, cooldown: cooldown, now: clock.read) { helper.makeConnection() }
    }

    func test_silentHelper_callsTimeOutInsteadOfBlockingForever() {
        let helper = SilentHelper()
        let client = client(helper)

        let took = elapsed {
            XCTAssertThrowsError(try client.setTargetRPM(fanID: "0", rpm: 3000)) {
                XCTAssertEqual($0 as? FanControlError, .writeFailed(detail: "privileged helper not responding"))
            }
        }

        XCTAssertGreaterThanOrEqual(took, timeout)
        XCTAssertLessThan(took, timeout + 1.5)
    }

    func test_silentHelper_afterATimeoutEveryCallFailsAtOnce() {
        let helper = SilentHelper()
        let client = client(helper)
        XCTAssertThrowsError(try client.revertToAutomatic())
        let opened = helper.connectionsAccepted

        let took = elapsed {
            XCTAssertThrowsError(try client.setTargetRPM(fanID: "0", rpm: 3000))
            XCTAssertThrowsError(try client.revertToAutomatic())
            XCTAssertEqual(client.heartbeat(), .helperUnreachable)
        }

        XCTAssertLessThan(took, 0.1, "no waiting during the cooldown")
        XCTAssertEqual(helper.connectionsAccepted, opened, "and no new connection attempts")
    }

    func test_silentHelper_isTriedAgainOnceTheCooldownEnds() {
        let helper = SilentHelper()
        let client = client(helper, cooldown: 5)
        XCTAssertThrowsError(try client.revertToAutomatic())

        clock.advance(4.9)
        XCTAssertLessThan(elapsed { XCTAssertThrowsError(try client.revertToAutomatic()) }, 0.1)

        clock.advance(0.2)
        XCTAssertGreaterThanOrEqual(elapsed { XCTAssertThrowsError(try client.revertToAutomatic()) }, timeout, "a real attempt again")
    }

    func test_silentHelper_heartbeatReportsUnreachableWithinTheTimeout() {
        let client = client(SilentHelper())
        var status = HeartbeatStatus.active
        let took = elapsed { status = client.heartbeat() }
        XCTAssertEqual(status, .helperUnreachable)
        XCTAssertLessThan(took, timeout + 1.5)
    }

    /// A reply that arrives after the caller gave up is dropped, not applied to a later call.
    func test_lateReplyAfterTheTimeoutIsIgnored() {
        let helper = SilentHelper(replyDelay: 0.6)
        let client = client(helper, cooldown: 0.1)
        XCTAssertThrowsError(try client.setTargetRPM(fanID: "0", rpm: 3000))

        RunLoop.current.run(until: Date().addingTimeInterval(0.8))   // the late reply lands now

        clock.advance(1)
        XCTAssertThrowsError(try client.setTargetRPM(fanID: "0", rpm: 3000), "still times out; the stale reply didn't leak in")
    }

    func test_productionClockDrivesTheCooldown() {
        let helper = SilentHelper()
        let client = HelperClient(callTimeout: 0.1) { helper.makeConnection() }   // real wall clock, default cooldown
        XCTAssertThrowsError(try client.revertToAutomatic())
        XCTAssertLessThan(elapsed { XCTAssertThrowsError(try client.revertToAutomatic()) }, 0.05, "the 10 s cooldown is active")
        XCTAssertEqual(HelperClient.defaultCooldown, 10)
        XCTAssertEqual(HelperClient.defaultCallTimeout, 2)
    }

    func test_aSlowButLiveHelperStillWorks() throws {
        let helper = SilentHelper(replyDelay: 0.05)
        let client = client(helper)
        XCTAssertNoThrow(try client.setTargetRPM(fanID: "0", rpm: 3000))
        XCTAssertEqual(client.heartbeat(), .active)
    }

    /// The reported bug: choosing a profile or a manual speed with the helper stopped froze the app.
    func test_appStaysResponsive_whenTheHelperIsStopped_forProfilesAndManualSpeed() {
        let helper = SilentHelper()
        let client = client(helper)
        let reader = IOKitSMCController(connection: FakeSMCConnection.appleSilicon().readOnlyView())
        let controller = PrivilegedFanController(reader: reader, helper: client)
        let heartbeat = MockHeartbeat()
        let store = ControlModeStore(controller: controller, log: ControlEventLog(fileURL: temporaryLogURL()), heartbeat: heartbeat)
        let status = StatusViewModel(controller: controller, store: store)
        status.refresh()

        let took = elapsed {
            store.selectProfile("gaming")
            store.setManual(targets: ["0": 3000])
            store.selectProfile("quiet")
            store.setManualForAll(rpm: 2500)
            store.revertToAutomatic()
            status.refresh()
        }

        XCTAssertLessThan(took, timeout + 1.5, "one bounded wait in total; the rest fail at once")
        XCTAssertEqual(store.mode, .automatic, "never left claiming an override that was not applied")
        XCTAssertFalse(heartbeat.isRunning)
        XCTAssertTrue(store.lastError?.contains("not responding") ?? false, store.lastError ?? "nil")
    }
}
