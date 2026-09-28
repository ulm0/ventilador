@testable import Ventilador
import OSLog
import XCTest

/// FR-007 / SC-003 end to end: app store → HelperClient → XPC → HelperService → IOKitSMCController → SMC.
/// Only the SMC itself is simulated, and the app side sees it read-only, as a non-root process does.
@MainActor final class WatchdogRegressionTests: XCTestCase {
    private struct Stack {
        let xpc: XPCHarness
        let client: HelperClient
        let heartbeat: HeartbeatEmitter
        let store: ControlModeStore
        let status: StatusViewModel
    }

    private func makeStack(fans: [(min: Double, max: Double, actual: Double)] = [(1000, 4900, 1200)], ftst: Bool = false) -> Stack {
        let xpc = XPCHarness(fans: fans, ftst: ftst)
        let client = xpc.makeClient()
        let controller = xpc.appController(client: client)
        let heartbeat = HeartbeatEmitter(interval: 60, beat: client.heartbeat)
        let store = ControlModeStore(controller: controller, log: ControlEventLog(fileURL: temporaryLogURL()), heartbeat: heartbeat)
        let status = StatusViewModel(controller: controller, store: store)
        status.refresh()
        addTeardownBlock { heartbeat.stop() }
        return Stack(xpc: xpc, client: client, heartbeat: heartbeat, store: store, status: status)
    }

    func test_manualOverride_reachesHardwareThroughThePrivilegedHelper() {
        let s = makeStack(ftst: true)

        s.store.setManual(targets: ["0": 3000])

        XCTAssertEqual(s.store.mode, .manual(targets: ["0": 3000]))
        XCTAssertTrue(s.xpc.service.overrideActive)
        XCTAssertEqual(s.xpc.smc.value("Ftst"), 1, "unlock written where the key exists")
        XCTAssertEqual(s.xpc.smc.value("F0Md"), 1)
        XCTAssertEqual(s.xpc.smc.value("F0Tg"), 3000)
        XCTAssertTrue(s.heartbeat.isRunning)

        s.status.refresh()
        XCTAssertEqual(s.store.mode, .manual(targets: ["0": 3000]), "our own target read back is not mistaken for another writer")
        XCTAssertFalse(s.store.conflictDetected)
    }

    /// Every app-side revert must go through the helper: the app's own SMC access is read-only.
    func test_userRevert_reachesHardwareThroughTheHelper() {
        let s = makeStack(ftst: true)
        s.store.setManual(targets: ["0": 3000])

        s.store.revertToAutomatic()

        XCTAssertNil(s.store.lastError)
        XCTAssertEqual(s.xpc.smc.value("F0Md"), 0)
        XCTAssertEqual(s.xpc.smc.value("Ftst"), 0)
        XCTAssertFalse(s.xpc.service.overrideActive)
    }

    // FR-012 through the production controller
    func test_anotherToolHoldingTheFansIsDetectedThroughTheRealReader() {
        let s = makeStack()
        s.xpc.smc.set("F0Md", "ui8 ", 1)

        s.status.refresh()

        XCTAssertTrue(s.store.conflictDetected)
    }

    // US2 Acceptance Scenario 4 / SC-003: crash
    func test_watchdog_revertsToAutomatic_onAppCrash_within5s() {
        let s = makeStack()
        s.store.setManual(targets: ["0": 3000])
        XCTAssertEqual(s.xpc.smc.value("F0Md"), 1)

        let crashedAt = Date()
        s.client.invalidate() // the app process vanishing closes its XPC connection

        XCTAssertTrue(s.xpc.waitForRevert(timeout: 5), "helper must revert within the SC-003 window")
        XCTAssertLessThan(Date().timeIntervalSince(crashedAt), 5)
        XCTAssertEqual(s.xpc.smc.value("F0Md"), 0)
    }

    // SC-003 hang / sleep-with-app-not-running: heartbeats stop arriving [C3][A1]
    func test_watchdog_revertsToAutomatic_onStaleHeartbeat_within5s() {
        let s = makeStack()
        s.store.setManual(targets: ["0": 3000])

        s.xpc.helperClock.advance(1)
        s.xpc.service.tick()
        XCTAssertTrue(s.xpc.service.overrideActive, "within the window the override stays")

        s.xpc.helperClock.advance(HelperConstants.heartbeatTimeout)
        s.xpc.service.tick()

        XCTAssertFalse(s.xpc.service.overrideActive)
        XCTAssertEqual(s.xpc.smc.value("F0Md"), 0)
        XCTAssertLessThanOrEqual(HelperConstants.heartbeatTimeout + HelperRuntime.tickInterval, 5, "worst case detection stays inside SC-003")
        XCTAssertLessThan(HeartbeatEmitter.defaultInterval, HelperConstants.heartbeatTimeout, "a healthy app always beats in time")
    }

    func test_watchdog_periodicHeartbeatsKeepTheOverride() {
        let s = makeStack()
        s.store.setManual(targets: ["0": 3000])

        for _ in 0..<5 {
            s.xpc.helperClock.advance(1)
            s.heartbeat.fire()
            s.xpc.service.tick()
        }

        XCTAssertTrue(s.xpc.service.overrideActive)
        XCTAssertEqual(s.xpc.smc.value("F0Md"), 1)
        XCTAssertEqual(s.store.mode, .manual(targets: ["0": 3000]))
    }

    // Edge Case: the whole Mac slept — a tick gap reverts even if the app beats first on wake
    func test_watchdog_revertsAfterSystemSleepGap() {
        let s = makeStack()
        s.store.setManual(targets: ["0": 3000])
        s.xpc.service.tick()

        s.xpc.helperClock.advance(600)
        s.heartbeat.fire()
        s.xpc.service.tick()

        XCTAssertFalse(s.xpc.service.overrideActive)
        XCTAssertEqual(s.xpc.smc.value("F0Md"), 0)
    }

    func test_watchdog_appLearnsOfHelperRevertThroughHeartbeatReply() {
        let s = makeStack()
        s.store.setManual(targets: ["0": 3000])
        s.xpc.helperClock.advance(10)
        s.xpc.service.tick()
        XCTAssertTrue(s.heartbeat.isRunning)

        s.heartbeat.fire()

        XCTAssertEqual(s.store.mode, .automatic)
        XCTAssertEqual(s.store.lastError, "The safety watchdog returned the fans to automatic control.")
        XCTAssertFalse(s.heartbeat.isRunning, "the store stops its own heartbeat")
        XCTAssertEqual(s.store.mode.displayName, "Automatic")
    }

    /// SAFETY-1 / SPEC-3: a revert that fails is retried every tick until it succeeds.
    func test_watchdog_retriesAFailedRevertUntilItSucceeds() {
        let s = makeStack()
        s.store.setManual(targets: ["0": 3000])
        s.xpc.smc.rejectedWrites = ["F0Md"]

        s.xpc.helperClock.advance(10)
        s.xpc.service.tick()
        XCTAssertTrue(s.xpc.service.revertPending)
        XCTAssertEqual(s.xpc.smc.value("F0Md"), 1, "the SMC refused the first attempt")

        s.xpc.service.tick()
        XCTAssertTrue(s.xpc.service.revertPending, "still refused, still pending")

        s.xpc.smc.rejectedWrites = []
        s.xpc.service.tick()
        XCTAssertFalse(s.xpc.service.revertPending)
        XCTAssertEqual(s.xpc.smc.value("F0Md"), 0)
    }

    /// FRESH-3: a revert the helper is still retrying is reported as such, never as done.
    func test_watchdog_pendingRevertIsReportedHonestly() {
        let s = makeStack()
        s.store.setManual(targets: ["0": 3000])
        s.xpc.smc.rejectedWrites = ["F0Md"]
        s.xpc.helperClock.advance(10)
        s.xpc.service.tick()
        XCTAssertTrue(s.xpc.service.revertPending)

        s.heartbeat.fire()

        XCTAssertEqual(s.store.mode, .automatic)
        XCTAssertEqual(s.store.lastError, "Returning the fans to automatic failed; the fan helper keeps retrying every second.")
        XCTAssertFalse(s.heartbeat.isRunning)
        XCTAssertEqual(s.client.heartbeat(), .revertPending, "the owner keeps hearing about it until it succeeds")

        s.xpc.smc.rejectedWrites = []
        s.xpc.service.tick()
        XCTAssertEqual(s.client.heartbeat(), .overrideEnded)
    }

    /// TESTS-3: the helper vanished (switched off, crashed). The app must not claim a revert it never saw.
    func test_unreachableHelperDuringAnOverrideIsReportedHonestly() {
        let s = makeStack()
        s.store.setManual(targets: ["0": 3000])
        s.xpc.stopListening()
        s.client.invalidate()

        s.heartbeat.fire()

        XCTAssertEqual(s.store.mode, .automatic)
        XCTAssertFalse(s.heartbeat.isRunning)
        XCTAssertEqual(s.store.lastError, "Lost contact with the fan helper; fans may keep their last speed until it is available again.")
        XCTAssertEqual(s.store.mode.displayName, "Automatic")
    }

    // Defense in depth: the helper never trusts the client's clamping
    func test_helper_reclampsOutOfRangeRequestsFromAnyClient() throws {
        let s = makeStack()
        try s.client.setTargetRPM(fanID: "0", rpm: 99_999)
        XCTAssertEqual(s.xpc.smc.value("F0Tg"), 4900)
        try s.client.setTargetRPM(fanID: "0", rpm: -5)
        XCTAssertEqual(s.xpc.smc.value("F0Tg"), 1000)
    }

    func test_helper_rejectsUnknownFanAndFailsClosed() throws {
        let s = makeStack()
        try s.client.setTargetRPM(fanID: "0", rpm: 2000)

        XCTAssertThrowsError(try s.client.setTargetRPM(fanID: "7", rpm: 2000)) { error in
            XCTAssertEqual(error as? FanControlError, .helperRejected(message: "Fan control failed: unknown fan 7"))
        }
        XCTAssertFalse(s.xpc.service.overrideActive)
        XCTAssertEqual(s.xpc.smc.value("F0Md"), 0)
    }

    func test_helper_hardwareRejectingAWriteRevertsAndReports() {
        let s = makeStack()
        s.xpc.smc.rejectedWrites = ["F0Tg"]

        s.store.setManual(targets: ["0": 3000])

        XCTAssertEqual(s.store.mode, .automatic)
        XCTAssertEqual(s.store.lastError, "Fan control failed: SMC rejected F0Tg (error 135)")
        XCTAssertEqual(s.xpc.smc.value("F0Md"), 0)
    }

    func test_helper_revertFailureIsReportedToTheApp() {
        let s = makeStack()
        s.xpc.smc.rejectedWrites = ["F0Md"]
        XCTAssertThrowsError(try s.client.revertToAutomatic()) { error in
            XCTAssertEqual(error as? FanControlError, .helperRejected(message: "Fan control failed: SMC rejected F0Md (error 135)"))
        }
    }

    /// SAFETY-6 / PLATFORM-5: the connection that armed an override owns it.
    func test_helper_overrideBelongsToTheConnectionThatSetIt() throws {
        let xpc = XPCHarness()
        let owner = xpc.makeClient()
        let other = xpc.makeClient()
        try owner.setTargetRPM(fanID: "0", rpm: 3000)

        XCTAssertThrowsError(try other.setTargetRPM(fanID: "0", rpm: 1000)) {
            XCTAssertEqual($0 as? FanControlError, .helperRejected(message: "Fan control is in use by another session."))
        }
        XCTAssertEqual(other.heartbeat(), .overrideEnded, "another session's heartbeat neither renews nor claims the override")
        XCTAssertEqual(owner.heartbeat(), .active)
        XCTAssertNoThrow(try other.revertToAutomatic())
        XCTAssertEqual(xpc.smc.value("F0Md"), 1, "another session can't cancel the owner's override")

        for _ in 0..<4 {
            xpc.helperClock.advance(1)
            _ = other.heartbeat()
            xpc.service.tick()
        }
        XCTAssertFalse(xpc.service.overrideActive, "the owner stopped beating; others' heartbeats don't keep it alive")
        XCTAssertEqual(xpc.smc.value("F0Md"), 0)
    }

    func test_helper_onlyTheOwnersDisconnectReverts() throws {
        let xpc = XPCHarness()
        let owner = xpc.makeClient()
        let other = xpc.makeClient()
        try owner.setTargetRPM(fanID: "0", rpm: 3000)
        XCTAssertEqual(other.heartbeat(), .overrideEnded)

        other.invalidate()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(xpc.service.overrideActive)

        owner.invalidate()
        XCTAssertTrue(xpc.waitForRevert())
    }

    // A helper that died mid-override must not leave fans stuck when it restarts
    func test_helper_resetReturnsFansToAutomatic() {
        let xpc = XPCHarness()
        xpc.smc.set("F0Md", "ui8 ", 1)
        xpc.service.reset(reason: "helper started")
        XCTAssertEqual(xpc.smc.value("F0Md"), 0)
    }

    func test_helper_disconnectWithoutOverrideDoesNothing() {
        let xpc = XPCHarness()
        let before = xpc.smc.writeLog.count
        xpc.service.clientDisconnected(ObjectIdentifier(xpc))
        XCTAssertEqual(xpc.smc.writeLog.count, before)
    }

    func test_client_reusesOneConnectionWhileItWorks() throws {
        let xpc = XPCHarness()
        let client = xpc.makeClient()
        try client.setTargetRPM(fanID: "0", rpm: 2000)
        _ = client.heartbeat()
        _ = client.heartbeat()
        try client.revertToAutomatic()
        XCTAssertEqual(xpc.connectionsOpened, 1)
    }

    // Helper not installed / not approved / crashed
    func test_unreachableHelper_failsClosedWithAClearMessage() {
        let xpc = XPCHarness()
        let client = xpc.makeClient()
        xpc.stopListening()

        XCTAssertEqual(client.heartbeat(), .helperUnreachable)
        XCTAssertThrowsError(try client.setTargetRPM(fanID: "0", rpm: 2000)) { error in
            guard case .writeFailed(let detail)? = error as? FanControlError else { return XCTFail("\(error)") }
            XCTAssertTrue(detail.hasPrefix("privileged helper unavailable ("))
            XCTAssertTrue(describe(error).hasPrefix("Fan control failed: privileged helper unavailable"))
        }
        XCTAssertThrowsError(try client.revertToAutomatic())
        XCTAssertEqual(xpc.connectionsOpened, 3, "every failed exchange drops the link so the next call reconnects")
    }

    /// Never reaches the real installed helper: the service name is one that cannot exist.
    func test_privilegedClient_forAnAbsentService_isUnreachable() {
        let client = HelperClient.privileged(machServiceName: "com.ulm0.ventilador.test.absent-\(UUID().uuidString)")
        XCTAssertEqual(client.heartbeat(), .helperUnreachable)
        XCTAssertThrowsError(try client.revertToAutomatic())
    }

    /// The production client targets the daemon's own mach service (never contacted here: not resumed).
    func test_privilegedClient_targetsTheDaemonsMachService() {
        let connection = HelperClient.privilegedConnection()
        XCTAssertEqual(connection.serviceName, HelperConstants.machServiceName)
        connection.invalidate()
    }

    /// FRESH-2: once stopping, the helper refuses new writes, and it keeps retrying a failed revert before exiting.
    func test_helper_shutdownRefusesWritesAndRetriesTheRevert() throws {
        let xpc = XPCHarness()
        let client = xpc.makeClient()
        try client.setTargetRPM(fanID: "0", rpm: 3000)
        xpc.smc.reject("F0Md", times: 2)

        xpc.service.shutdown(attempts: 5, retryDelay: 0.01)

        XCTAssertEqual(xpc.smc.value("F0Md"), 0, "third attempt succeeded")
        XCTAssertFalse(xpc.service.revertPending)
        XCTAssertThrowsError(try client.setTargetRPM(fanID: "0", rpm: 3000)) {
            XCTAssertEqual($0 as? FanControlError, .helperRejected(message: "The fan helper is stopping."))
        }
        XCTAssertEqual(xpc.smc.value("F0Md"), 0, "no write slipped in after the revert")
    }

    /// A failed revert leaves a trace in the system log, where `log stream` (quickstart) shows it.
    func test_helper_failedRevertIsLogged() throws {
        let xpc = XPCHarness()
        try xpc.makeClient().setTargetRPM(fanID: "0", rpm: 3000)
        xpc.smc.rejectedWrites = ["F0Md"]
        let since = Date()

        xpc.helperClock.advance(10)
        xpc.service.tick()

        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let found = waitUntil(timeout: 5) {
            let entries = try? store.getEntries(at: store.position(date: since),
                                                matching: NSPredicate(format: "subsystem == %@", HelperConstants.machServiceName))
            return entries?.contains { $0.composedMessage.hasPrefix("Revert failed (heartbeat lost or system slept), retrying every tick") } ?? false
        }
        XCTAssertTrue(found)
    }

    func test_helper_shutdownGivesUpAfterItsAttempts() throws {
        let xpc = XPCHarness()
        try xpc.makeClient().setTargetRPM(fanID: "0", rpm: 3000)
        xpc.smc.rejectedWrites = ["F0Md"]

        xpc.service.shutdown(attempts: 2, retryDelay: 0.01)

        XCTAssertTrue(xpc.service.revertPending)
        XCTAssertEqual(xpc.smc.writeLog.filter { $0.key == "F0Md" }.count, 1, "only the original manual write succeeded")
    }
}
