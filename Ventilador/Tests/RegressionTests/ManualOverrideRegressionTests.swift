@testable import Ventilador
import AppKit
import XCTest

/// spec.md User Story 2 — Manually Override Fan Speed Safely (FR-004/005/006/007/010/013, SC-004).
@MainActor final class ManualOverrideRegressionTests: XCTestCase {
    private func ready(_ h: Harness) -> Harness {
        h.status.refresh()
        return h
    }

    private func twoFans() -> Harness {
        ready(Harness(fans: [.stub(id: "0", min: 1000, max: 5000), .stub(id: "1", min: 1200, max: 6000)], temperatures: ["CPU": 60]))
    }

    // US2 Acceptance Scenario 1
    func test_manualOverride_movesToRequestedTarget() {
        let h = ready(Harness())

        h.store.setManual(targets: ["0": 3000])

        XCTAssertEqual(h.smc.targets, ["0": 3000])
        XCTAssertEqual(h.store.mode, .manual(targets: ["0": 3000]))
        XCTAssertEqual(h.store.mode.displayName, "Manual")
        XCTAssertTrue(h.heartbeat.isRunning, "helper must see heartbeats while an override is active")
        XCTAssertNil(h.store.clampNotice)
        let entry = h.log.last
        XCTAssertEqual(entry?.kind, .modeChanged)
        XCTAssertEqual(entry?.fanID, "0")
        XCTAssertEqual(entry?.targetRPM, 3000)
        XCTAssertEqual(entry?.mode, "Manual")
        XCTAssertEqual(entry?.detail, "Automatic → Manual (user)")
    }

    // US2 Acceptance Scenario 2 / FR-005 / SC-004
    func test_manualOverride_clampsOutOfRangeTarget() {
        let h = ready(Harness())

        h.store.setManual(targets: ["0": 9000])
        XCTAssertEqual(h.smc.targets, ["0": 4900])
        XCTAssertEqual(h.store.clampNotice, "Fan 1: 9000 RPM is outside the safe range, using 4900 RPM")
        XCTAssertEqual(StatusView(environment: h.env).sections.last, .clampNotice("Fan 1: 9000 RPM is outside the safe range, using 4900 RPM"))

        h.store.setManual(targets: ["0": 10])
        XCTAssertEqual(h.smc.targets, ["0": 1000])
        XCTAssertEqual(h.store.clampNotice, "Fan 1: 10 RPM is outside the safe range, using 1000 RPM", "below-minimum requests are announced too")

        let clamps = h.log.filter { $0.kind == .clampApplied }
        XCTAssertEqual(clamps.map(\.fanID), ["0", "0"])
        XCTAssertEqual(clamps.map(\.targetRPM), [4900, 1000])
        XCTAssertTrue(h.smc.attempts.allSatisfy { (1000...4900).contains($0.rpm) }, "no unclamped value was ever requested from hardware")
        render(StatusView(environment: h.env))
    }

    func test_manualOverride_everyClampedFanIsAnnounced() {
        let h = twoFans()
        h.store.setManual(targets: ["0": 9000, "1": 100])
        XCTAssertEqual(h.store.clampNotice, """
            Fan 1: 9000 RPM is outside the safe range, using 5000 RPM
            Fan 2: 100 RPM is outside the safe range, using 1200 RPM
            """)
    }

    // US2 Acceptance Scenario 3 / FR-006
    func test_manualOverride_revertsToAutomatic_onUserAction() {
        let h = ready(Harness())
        h.store.setManual(targets: ["0": 9000])

        h.store.revertToAutomatic()

        XCTAssertEqual(h.store.mode, .automatic)
        XCTAssertEqual(h.smc.revertCount, 1)
        XCTAssertTrue(h.smc.targets.isEmpty)
        XCTAssertFalse(h.heartbeat.isRunning)
        XCTAssertNil(h.store.clampNotice)
        XCTAssertEqual(h.log.last?.detail, "Manual → Automatic (user)")
        XCTAssertEqual(h.log.last?.mode, "Automatic")
    }

    // FR-007 / FR-013 [C1]
    func test_manualOverride_revertsToAutomatic_onStaleReadingDuringOverride() {
        let h = ready(Harness())
        h.store.setManual(targets: ["0": 9000])

        h.setTemperatures(["CPU": 60], age: stalenessThreshold + 0.5)
        h.status.refresh()

        XCTAssertEqual(h.store.mode, .automatic)
        XCTAssertEqual(h.smc.revertCount, 1)
        XCTAssertFalse(h.heartbeat.isRunning)
        XCTAssertNil(h.store.clampNotice, "a notice about an override that no longer exists is removed")
        XCTAssertTrue(h.log.contains { $0.kind == .sensorError && $0.detail.contains("stale") })
        XCTAssertEqual(h.log.last?.detail, "Manual → Automatic (sensor data unavailable)")
    }

    // FR-007: hardware read error during an override; nothing may be written from data we could not read
    func test_manualOverride_sensorFailureRevertsAndBlocksFurtherWrites() {
        let h = ready(Harness())
        h.store.setManual(targets: ["0": 3000])
        h.smc.readError = .sensorUnavailable(detail: "bus error")

        h.status.refresh()
        let writes = h.smc.attempts.count
        h.store.setManual(targets: ["0": 2500])
        h.store.setManualForAll(rpm: 2500)
        h.store.selectProfile("performance")

        XCTAssertEqual(h.store.mode, .profile("performance"), "the mode can be chosen…")
        XCTAssertEqual(h.smc.attempts.count, writes, "…but nothing is written until readings return")
        XCTAssertEqual(h.smc.revertCount, 1)
    }

    /// Readings from before an outage are forgotten too, so nothing is ever evaluated from them.
    func test_manualOverride_sensorFailureForgetsOldReadings() {
        let h = ready(Harness(temperatures: ["GPU": 50]))
        h.smc.readError = .sensorUnavailable(detail: "bus error")
        h.status.refresh()

        h.store.selectProfile("quiet")

        XCTAssertEqual(h.store.mode, .profile("quiet"), "waits for new readings instead of judging the old ones")
        XCTAssertFalse(h.log.contains { $0.detail.contains("CPU temperature unavailable") })
    }

    // FR-004 / multi-fan Edge Case [C2]
    func test_manualOverride_appliesOneTargetToAllFansAtOnce() {
        let h = twoFans()

        h.store.setManualForAll(rpm: 5500)

        XCTAssertEqual(h.smc.targets, ["0": 5000, "1": 5500], "each fan clamped to its own range")
        XCTAssertEqual(h.store.mode, .manual(targets: ["0": 5000, "1": 5500]))
        XCTAssertEqual(h.store.clampNotice, "Fan 1: 5500 RPM is outside the safe range, using 5000 RPM")
        XCTAssertEqual(h.log.filter { $0.kind == .modeChanged }.map(\.fanID), ["0", "1"], "one entry per fan with its value")
    }

    func test_manualOverride_bulkApplyThroughTheUIModel() {
        let h = ready(Harness(fans: [.stub(id: "0", currentRPM: 1500, min: 1000, max: 5000), .stub(id: "1", min: 1200, max: 6000)]))
        XCTAssertTrue(h.env.manual.showsBulkControl)
        XCTAssertEqual(h.env.manual.allDraft, 1500)
        XCTAssertEqual(h.env.manual.allRange, 1000...6000)

        h.env.manual.allDraft = 2500.6
        h.env.manual.applyAll()

        XCTAssertEqual(h.smc.targets, ["0": 2501, "1": 2501], "the value shown (rounded) is the value applied")
        render(ManualControlView(model: h.env.manual))
    }

    func test_manualOverride_eachRowAppliesItsOwnFan() {
        let h = twoFans()
        XCTAssertEqual(h.env.manual.rows.map(\.draft), [1200, 1200])
        h.env.manual.rows[0].draft = 2222.6
        h.env.manual.rows[1].draft = 3333.2

        ManualControlView(model: h.env.manual).applyAction("1")()   // fan 2's Apply button
        XCTAssertEqual(h.smc.targets, ["1": 3333])

        ManualControlView(model: h.env.manual).applyAction("0")()
        h.env.manual.apply("missing")
        XCTAssertEqual(h.smc.targets, ["0": 2223, "1": 3333])

        h.env.manual.revert()
        XCTAssertEqual(h.store.mode, .automatic)
        XCTAssertEqual(h.log.last?.detail, "Manual → Automatic (user)", "the Revert button is a user action")
    }

    func test_manualOverride_singleFanMacHasNoBulkControl() {
        let h = ready(Harness())
        XCTAssertFalse(h.env.manual.showsBulkControl)
        render(ManualControlView(model: h.env.manual))
    }

    func test_manualOverride_writeFailureFailsClosed() {
        let h = twoFans()
        h.smc.writeError = .writeFailed(detail: "helper not approved")

        h.store.setManual(targets: ["0": 2000, "1": 2000])

        XCTAssertEqual(h.store.mode, .automatic)
        XCTAssertEqual(h.smc.revertCount, 1, "anything partially written is reverted")
        XCTAssertFalse(h.heartbeat.isRunning)
        XCTAssertEqual(h.store.lastError, "Fan control failed: helper not approved")
        let failure = h.log.first { $0.kind == .sensorError }
        XCTAssertEqual(failure?.fanID, "0", "the log says which fan failed…")
        XCTAssertEqual(failure?.targetRPM, 2000, "…and with which value")

        h.status.refresh()
        XCTAssertEqual(h.store.lastError, "Fan control failed: helper not approved", "a write failure stays visible across polls")
    }

    func test_manualOverride_partialWriteFailureRevertsTheFansAlreadyWritten() {
        let h = twoFans()
        h.smc.writeErrors = ["1": .writeFailed(detail: "fan 2 rejected")]

        h.store.setManual(targets: ["0": 2000, "1": 2000])

        XCTAssertEqual(h.smc.writes.map(\.fanID), ["0"], "fan 1 was written before fan 2 failed")
        XCTAssertEqual(h.store.mode, .automatic)
        XCTAssertEqual(h.smc.revertCount, 1)
        XCTAssertTrue(h.smc.targets.isEmpty)
        XCTAssertFalse(h.log.contains { $0.kind == .modeChanged }, "no manual mode was ever entered")
        XCTAssertEqual(h.log.last?.fanID, "1")
    }

    func test_manualOverride_successClearsAnEarlierError() {
        let h = ready(Harness())
        h.smc.writeError = .writeFailed(detail: "transient")
        h.store.setManual(targets: ["0": 2000])
        XCTAssertNotNil(h.store.lastError)

        h.smc.writeError = nil
        h.store.setManual(targets: ["0": 2000])

        XCTAssertNil(h.store.lastError)
    }

    func test_manualOverride_failedRevertIsReportedAndStopsHeartbeatSoHelperReverts() {
        let h = ready(Harness())
        h.store.setManual(targets: ["0": 3000])
        h.smc.revertError = .writeFailed(detail: "helper unreachable")
        h.smc.readError = .sensorUnavailable(detail: "gone")

        h.status.refresh()

        XCTAssertEqual(h.store.mode, .automatic)
        XCTAssertFalse(h.heartbeat.isRunning)
        XCTAssertTrue(h.log.contains { $0.detail == "Revert failed: Fan control failed: helper unreachable" })
    }

    func test_manualOverride_failedUserRevertIsReportedThenClearedByASuccessfulOne() {
        let h = ready(Harness())
        h.store.setManual(targets: ["0": 3000])
        h.smc.revertError = .writeFailed(detail: "helper unreachable")

        h.store.revertToAutomatic()

        XCTAssertEqual(h.store.mode, .automatic)
        XCTAssertFalse(h.heartbeat.isRunning)
        XCTAssertEqual(h.store.lastError, "Fan control failed: helper unreachable")
        XCTAssertTrue(h.log.contains { $0.detail == "Revert failed: Fan control failed: helper unreachable" })

        h.smc.revertError = nil
        h.store.revertToAutomatic()
        XCTAssertNil(h.store.lastError)
    }

    // SPEC-9: only fans whose speed changed are logged
    func test_manualOverride_retargetLogsOnlyChangedFans() {
        let h = twoFans()
        h.store.setManual(targets: ["0": 2000, "1": 3000])
        let before = h.log.count

        h.store.setManualForAll(rpm: 2000)
        XCTAssertEqual(h.store.mode, .manual(targets: ["0": 2000, "1": 2000]))
        XCTAssertEqual(h.log.count, before + 1)
        XCTAssertEqual(h.log.last?.fanID, "1")
        XCTAssertEqual(h.log.last?.detail, "Manual → Manual (user)")

        h.store.setManual(targets: ["1": 2000])
        XCTAssertEqual(h.log.count, before + 1, "re-applying the same speed is not a change")
    }

    func test_manualOverride_unknownFanOrNoFansIsIgnored() {
        let h = Harness()
        h.store.setManual(targets: ["0": 2000])
        XCTAssertTrue(h.smc.attempts.isEmpty, "nothing to control before the first poll")

        h.status.refresh()
        h.store.setManual(targets: ["9": 2000])
        XCTAssertTrue(h.smc.attempts.isEmpty)
        XCTAssertEqual(h.store.mode, .automatic)
        XCTAssertTrue(h.log.isEmpty)
    }

    /// SAFETY-3 / US3 AS2: leaving a profile for one fan's manual speed must not pin the other fans.
    func test_manualOverride_fromAProfileReturnsUntouchedFansToAutomatic() {
        let h = twoFans()
        h.store.selectProfile("quiet")
        XCTAssertEqual(Set(h.smc.targets.keys), ["0", "1"])

        h.env.manual.rows[0].draft = 2500
        h.env.manual.apply("0")

        XCTAssertEqual(h.smc.revertCount, 1)
        XCTAssertEqual(h.smc.targets, ["0": 2500], "fan 2 is back on Apple's curve, not held at the profile's speed")
        XCTAssertEqual(h.store.mode, .manual(targets: ["0": 2500]))
    }

    func test_manualOverride_fromAProfileFailsClosedIfTheRevertFails() {
        let h = twoFans()
        h.store.selectProfile("quiet")
        h.smc.revertError = .writeFailed(detail: "no")

        h.store.setManual(targets: ["0": 2500])

        XCTAssertEqual(h.store.mode, .automatic)
        XCTAssertFalse(h.heartbeat.isRunning)
    }

    // Edge Case: sleep/wake must not silently keep an override (manual or profile)
    func test_override_revertsOnSystemWake() {
        let h = ready(Harness())
        h.store.systemDidWake()
        XCTAssertEqual(h.smc.revertCount, 0, "nothing to revert in automatic")

        h.store.setManual(targets: ["0": 3000])
        h.store.systemDidWake()
        XCTAssertEqual(h.store.mode, .automatic)
        XCTAssertEqual(h.log.last?.detail, "Manual → Automatic (system woke from sleep)")

        h.store.selectProfile("balanced")
        h.store.systemDidWake()
        XCTAssertEqual(h.store.mode, .automatic)
        XCTAssertEqual(h.smc.revertCount, 2)
        XCTAssertEqual(h.log.last?.detail, "Balanced → Automatic (system woke from sleep)")
    }

    // US2 Acceptance Scenario 4: normal quit (manual or profile)
    func test_override_revertsOnAppQuit() {
        let h = ready(Harness())
        h.store.appWillTerminate()
        XCTAssertEqual(h.smc.revertCount, 0)

        h.store.setManual(targets: ["0": 3000])
        h.store.appWillTerminate()
        XCTAssertEqual(h.store.mode, .automatic)
        XCTAssertEqual(h.log.last?.detail, "Manual → Automatic (app quit)")

        h.store.selectProfile("quiet")
        h.store.appWillTerminate()
        XCTAssertEqual(h.smc.revertCount, 2)
        XCTAssertEqual(h.log.last?.detail, "Quiet → Automatic (app quit)")
    }

    func test_override_systemNotificationsReachTheStore() {
        let h = ready(Harness())
        let workspace = NotificationCenter()
        let app = NotificationCenter()
        h.env.start(workspace: workspace, app: app)
        defer { h.status.stop() }
        XCTAssertTrue(h.status.isPolling, "start() begins polling")

        h.store.setManual(targets: ["0": 3000])
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertTrue(waitUntil { h.store.mode == .automatic })
        XCTAssertEqual(h.log.last?.detail, "Manual → Automatic (system woke from sleep)")

        h.store.setManual(targets: ["0": 3000])
        app.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertTrue(waitUntil { h.store.mode == .automatic })
        XCTAssertEqual(h.log.last?.detail, "Manual → Automatic (app quit)")
    }
}
