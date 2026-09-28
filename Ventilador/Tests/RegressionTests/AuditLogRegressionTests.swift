@testable import Ventilador
import XCTest

/// FR-010 / SC-006 and Constitution Principle IV: every mode change and manual speed change is
/// logged with timestamp, fan and value — zero missed entries — survives a relaunch, and stays viewable.
@MainActor final class AuditLogRegressionTests: XCTestCase {
    func test_everyModeAndManualSpeedChangeIsLogged() {
        let h = Harness(fans: [.stub(id: "0"), .stub(id: "1")], temperatures: ["CPU": 70])
        h.status.refresh()

        h.store.setManual(targets: ["0": 2000, "1": 2100])   // 2 entries (one per fan)
        h.store.setManual(targets: ["1": 9000])              // clamp + 1 entry
        h.store.selectProfile("quiet")                        // 1
        h.store.selectProfile("balanced")                     // 1
        h.store.setManual(targets: ["0": 3000])              // 1
        h.store.revertToAutomatic()                           // 1

        XCTAssertEqual(h.log.map(\.kind), [.modeChanged, .modeChanged, .clampApplied, .modeChanged, .modeChanged, .modeChanged, .modeChanged, .modeChanged])
        XCTAssertEqual(h.log.map(\.detail), [
            "Automatic → Manual (user)", "Automatic → Manual (user)",
            "Fan 2: 9000 RPM is outside the safe range, using 4900 RPM", "Manual → Manual (user)",
            "Manual → Quiet (user)", "Quiet → Balanced (user)", "Balanced → Manual (user)", "Manual → Automatic (user)",
        ])
        XCTAssertEqual(h.log.map(\.fanID), ["0", "1", "1", "1", nil, nil, "0", nil])
        XCTAssertEqual(h.log.map(\.targetRPM), [2000, 2100, 4900, 4900, nil, nil, 3000, nil])
        XCTAssertEqual(h.log.map(\.mode), ["Manual", "Manual", nil, "Manual", "Quiet", "Balanced", "Manual", "Automatic"])
        XCTAssertTrue(h.log.allSatisfy { $0.timestamp == h.clock.now })
    }

    func test_watchdogRevertIsCreditedToTheWatchdog() {
        let h = Harness()
        h.status.refresh()
        h.store.setManual(targets: ["0": 9000])
        XCTAssertNotNil(h.store.clampNotice)

        h.heartbeat.onOverrideLost?(.overrideEnded)

        XCTAssertEqual(h.log.last?.detail, "Manual → Automatic (safety watchdog)")
        XCTAssertFalse(h.heartbeat.isRunning)
        XCTAssertNil(h.store.clampNotice, "no notice about an override that no longer exists")
        XCTAssertEqual(h.store.lastError, "The safety watchdog returned the fans to automatic control.")
    }

    func test_pendingRevertIsNeverReportedAsDone() {
        let h = Harness()
        h.status.refresh()
        h.store.setManual(targets: ["0": 2500])

        h.heartbeat.onOverrideLost?(.revertPending)

        XCTAssertEqual(h.store.mode, .automatic)
        XCTAssertEqual(h.store.lastError, "Returning the fans to automatic failed; the fan helper keeps retrying every second.")
        XCTAssertEqual(h.log.last?.detail, "Manual → Automatic (safety watchdog)")
    }

    func test_lateWatchdogNoticeInAutomaticChangesNothing() {
        let h = Harness()
        h.status.refresh()

        h.heartbeat.onOverrideLost?(.overrideEnded)
        h.heartbeat.onOverrideLost?(.helperUnreachable)

        XCTAssertNil(h.store.lastError)
        XCTAssertTrue(h.log.isEmpty)
    }

    func test_unreachableHelperMessageDependsOnWhetherTheRevertWorked() {
        let h = Harness()
        h.status.refresh()
        h.store.setManual(targets: ["0": 2500])
        h.heartbeat.onOverrideLost?(.helperUnreachable)
        XCTAssertEqual(h.store.lastError, "Lost contact with the fan helper; fan control returned to automatic.")
        XCTAssertEqual(h.log.last?.detail, "Manual → Automatic (fan helper unreachable)")

        h.store.setManual(targets: ["0": 2500])
        h.smc.revertError = .writeFailed(detail: "unreachable")
        h.heartbeat.onOverrideLost?(.helperUnreachable)
        XCTAssertEqual(h.store.lastError, "Lost contact with the fan helper; fans may keep their last speed until it is available again.")
    }

    func test_logSurvivesRelaunchAndIsViewable() {
        let url = temporaryLogURL()
        let smc = MockSMCController(fans: [.stub()])
        smc.temperatures = [TemperatureReading(sourceLabel: "CPU", celsius: 50, readAt: Date())]
        let first = AppEnvironment(controller: smc, heartbeat: MockHeartbeat(), log: ControlEventLog(fileURL: url), installer: MockHelperInstaller())
        first.status.refresh()
        first.store.setManual(targets: ["0": 2500])
        first.store.revertToAutomatic()

        let relaunched = ControlEventLog(fileURL: url)

        XCTAssertEqual(relaunched.entries, first.log.entries)
        XCTAssertEqual(relaunched.entries.count, 2)
        render(EventLogView(log: relaunched))
    }

    /// SPEC-7: an override the helper ended while the app was gone is recorded on the next launch.
    func test_relaunchAfterACrashRecordsTheOverrideEnding() {
        let url = temporaryLogURL()
        let crashed = Harness()
        let env = AppEnvironment(controller: crashed.smc, heartbeat: MockHeartbeat(), log: ControlEventLog(fileURL: url),
                                 installer: MockHelperInstaller(), clock: crashed.clock.read)
        env.status.refresh()
        env.store.setManual(targets: ["0": 2500])   // then the app "crashes": no revert logged
        XCTAssertEqual(env.log.entries.last?.mode, "Manual")

        let relaunched = AppEnvironment(controller: MockSMCController(fans: [.stub()]), heartbeat: MockHeartbeat(),
                                        log: ControlEventLog(fileURL: url), installer: MockHelperInstaller())
        relaunched.start(workspace: NotificationCenter(), app: NotificationCenter())
        relaunched.status.stop()

        XCTAssertEqual(relaunched.log.entries.map(\.detail), ["Automatic → Manual (user)", "Manual → Automatic (ended while the app was not running)"])
        XCTAssertEqual(relaunched.log.entries.last?.mode, "Automatic")

        relaunched.store.reconcileLog()
        XCTAssertEqual(relaunched.log.entries.count, 2, "reconciling twice adds nothing")
    }

    /// Crash during a profile, and crash after an entry that isn't a mode change (a clamp on an unchanged target).
    func test_relaunchReconcilesProfilesAndLooksPastNonModeEntries() {
        func crashAndRelaunch(_ setUp: (AppEnvironment) -> Void) -> [String] {
            let url = temporaryLogURL()
            let crashed = Harness(temperatures: ["CPU": 60])
            let env = AppEnvironment(controller: crashed.smc, heartbeat: MockHeartbeat(), log: ControlEventLog(fileURL: url),
                                     installer: MockHelperInstaller(), clock: crashed.clock.read)
            env.status.refresh()
            setUp(env)
            let relaunched = AppEnvironment(controller: MockSMCController(fans: [.stub()]), heartbeat: MockHeartbeat(),
                                            log: ControlEventLog(fileURL: url), installer: MockHelperInstaller())
            relaunched.store.reconcileLog()
            return relaunched.log.entries.map(\.detail)
        }

        XCTAssertEqual(crashAndRelaunch { $0.store.selectProfile("balanced") }.last,
                       "Balanced → Automatic (ended while the app was not running)")

        let afterClamp = crashAndRelaunch { env in
            env.store.setManual(targets: ["0": 9000])
            env.store.setManual(targets: ["0": 9000]) // same clamped target: only a clampApplied entry
        }
        XCTAssertEqual(afterClamp.suffix(2), ["Fan 1: 9000 RPM is outside the safe range, using 4900 RPM",
                                              "Manual → Automatic (ended while the app was not running)"])
    }

    func test_logsWithoutModeInformationAreLeftAlone() {
        let log = ControlEventLog(fileURL: temporaryLogURL())
        log.append(ControlEventLogEntry(timestamp: Date(), kind: .modeChanged, fanID: "0", targetRPM: 2000, detail: "legacy entry"))
        let store = ControlModeStore(controller: MockSMCController(fans: [.stub()]), log: log, heartbeat: MockHeartbeat())
        store.reconcileLog()
        XCTAssertEqual(log.entries.count, 1)
    }

    /// SPEC-6: the whole log stays viewable, not just the latest few entries.
    func test_everyEntryStaysViewableNewestFirst() {
        let h = Harness()
        h.status.refresh()
        for rpm in stride(from: 1100, through: 2100, by: 100) { h.store.setManual(targets: ["0": rpm]) }

        let lines = EventLogView.lines(for: h.log)

        XCTAssertEqual(lines.count, 11)
        XCTAssertTrue(lines.first!.hasSuffix("Manual → Manual (user) [fan 0: 2100 RPM]"))
        XCTAssertTrue(lines.last!.hasSuffix("Automatic → Manual (user) [fan 0: 1100 RPM]"), "the oldest entry is still reachable")
        render(EventLogView(log: h.env.log))
    }
}
