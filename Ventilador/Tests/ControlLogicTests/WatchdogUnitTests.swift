@testable import Ventilador
import ServiceManagement
import XCTest

@MainActor final class WatchdogCoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 5_000)

    func test_idleWatchdogNeverReverts() {
        var core = WatchdogCore()
        XCTAssertEqual(core.timeout, HelperConstants.heartbeatTimeout)
        XCTAssertFalse(core.tick(at: t0))
        XCTAssertFalse(core.tick(at: t0 + 100))
        XCTAssertFalse(core.heartbeat(at: t0), "no override to keep alive")
    }

    func test_heartbeatLossAsksForARevert() {
        var core = WatchdogCore(timeout: 3)
        core.overrideStarted(at: t0)
        XCTAssertTrue(core.heartbeat(at: t0 + 1))
        XCTAssertFalse(core.tick(at: t0 + 4), "3 s after the last heartbeat is still inside the window")
        XCTAssertTrue(core.tick(at: t0 + 4.51))
        core.revertSucceeded()
        XCTAssertFalse(core.overrideActive)
        XCTAssertFalse(core.tick(at: t0 + 10), "nothing left to revert")
    }

    func test_tickGapMeansTheSystemWasSuspended() {
        var core = WatchdogCore(timeout: 3)
        core.overrideStarted(at: t0)
        XCTAssertFalse(core.tick(at: t0))
        XCTAssertTrue(core.heartbeat(at: t0 + 300))
        XCTAssertTrue(core.tick(at: t0 + 300), "fresh heartbeat after a long gap still reverts")
    }

    func test_aTickGapOfExactlyTheTimeoutIsNotASleep() {
        var core = WatchdogCore(timeout: 3)
        core.overrideStarted(at: t0)
        XCTAssertFalse(core.tick(at: t0))
        XCTAssertTrue(core.heartbeat(at: t0 + 3))
        XCTAssertFalse(core.tick(at: t0 + 3))
    }

    /// Idle ticks keep the gap detector current, so a new override after a quiet period isn't reverted at once.
    func test_newOverrideAfterALongIdlePeriodIsNotMistakenForSleep() {
        var core = WatchdogCore(timeout: 3)
        XCTAssertFalse(core.tick(at: t0))
        for second in 1...20 { XCTAssertFalse(core.tick(at: t0 + Double(second))) }
        core.overrideStarted(at: t0 + 20.5)
        XCTAssertFalse(core.tick(at: t0 + 21))
        XCTAssertTrue(core.overrideActive)
    }

    func test_idleTicksAfterAnEndedOverrideStillCount() {
        var core = WatchdogCore(timeout: 3)
        core.overrideStarted(at: t0)
        XCTAssertFalse(core.tick(at: t0 + 1))
        core.revertSucceeded()
        for second in 2...12 { XCTAssertFalse(core.tick(at: t0 + Double(second))) }

        core.overrideStarted(at: t0 + 12.5)

        XCTAssertFalse(core.tick(at: t0 + 13), "the idle period was ticked through, it wasn't a sleep")
    }

    func test_ticksDuringAPendingRevertStillCount() {
        var core = WatchdogCore(timeout: 3)
        core.overrideStarted(at: t0)
        XCTAssertFalse(core.tick(at: t0 + 0.5))
        core.revertFailed()
        for second in 1...5 { XCTAssertTrue(core.tick(at: t0 + Double(second))) }

        core.overrideStarted(at: t0 + 5.5)

        XCTAssertFalse(core.tick(at: t0 + 6), "a new override after the retries isn't mistaken for a sleep gap")
    }

    func test_failedRevertIsRetriedEveryTickUntilItSucceeds() {
        var core = WatchdogCore(timeout: 3)
        core.overrideStarted(at: t0)
        core.revertFailed()
        XCTAssertFalse(core.overrideActive)
        XCTAssertTrue(core.revertPending)
        XCTAssertFalse(core.heartbeat(at: t0 + 1), "the app learns the override is gone")
        XCTAssertTrue(core.tick(at: t0 + 1))
        XCTAssertTrue(core.tick(at: t0 + 2))
        core.revertSucceeded()
        XCTAssertFalse(core.revertPending)
        XCTAssertFalse(core.tick(at: t0 + 3))

        core.revertFailed()
        core.overrideStarted(at: t0 + 4)
        XCTAssertFalse(core.revertPending, "a new override supersedes the pending revert")
    }

    /// SAFETY-5: the helper's clock keeps counting through sleep and ignores wall-clock steps.
    func test_helperClockIsMonotonic() {
        let first = monotonicNow()
        let second = monotonicNow()
        XCTAssertGreaterThanOrEqual(second, first)
        XCTAssertEqual(first.timeIntervalSinceReferenceDate,
                       TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000, accuracy: 1)
    }

    func test_helperServiceUsesTheMonotonicClockByDefault() {
        let service = HelperService(controller: MockSMCController(fans: [.stub()]))
        XCTAssertEqual(service.clock().timeIntervalSince(monotonicNow()), 0, accuracy: 1)
        XCTAssertGreaterThan(abs(service.clock().timeIntervalSinceNow), 60 * 60 * 24 * 365, "not the wall clock")
        var reply = -1
        service.heartbeat { reply = $0 }
        XCTAssertEqual(reply, HeartbeatReply.noOverride)
        service.tick()
        XCTAssertFalse(service.overrideActive)
        XCTAssertFalse(service.revertPending)
    }
}

@MainActor final class GuardedTests: XCTestCase {
    /// The helper's one lock: concurrent XPC queues and the main-queue tick must never interleave.
    func test_withLockSerializesConcurrentAccess() {
        let counter = Guarded(0)
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0..<20_000 { counter.withLock { $0 += 1 } }
        }
        XCTAssertEqual(counter.withLock { $0 }, 160_000)
    }
}

@MainActor final class HeartbeatEmitterTests: XCTestCase {
    func test_reportsEveryAnswerButActive() {
        var answer = HeartbeatStatus.active
        var reported: [HeartbeatStatus] = []
        let emitter = HeartbeatEmitter(beat: { answer })
        emitter.onOverrideLost = { reported.append($0) }

        emitter.fire()
        answer = .overrideEnded
        emitter.fire()
        answer = .revertPending
        emitter.fire()
        answer = .helperUnreachable
        emitter.fire()

        XCTAssertEqual(reported, [.overrideEnded, .revertPending, .helperUnreachable])
    }

    private final class RecordingActivities: ActivityHolding {
        var begun: [ProcessInfo.ActivityOptions] = []
        var ended: [NSObjectProtocol] = []
        let token = NSObject()
        func beginActivity(options: ProcessInfo.ActivityOptions, reason: String) -> NSObjectProtocol {
            begun.append(options)
            return token
        }
        func endActivity(_ activity: NSObjectProtocol) { ended.append(activity) }
    }

    func test_beatsPeriodicallyUntilStoppedAndHoldsOffAppNap() {
        var beats = 0
        let activities = RecordingActivities()
        let emitter = HeartbeatEmitter(interval: 0.02, activities: activities) { beats += 1; return .active }

        emitter.start()
        emitter.start()
        XCTAssertTrue(emitter.isRunning)
        XCTAssertEqual(activities.begun, [.userInitiatedAllowingIdleSystemSleep], "one activity that App Nap respects")
        XCTAssertTrue(waitUntil(timeout: 2) { beats >= 3 }, "periodic, not one-shot")

        emitter.stop()
        XCTAssertFalse(emitter.isRunning)
        XCTAssertEqual(activities.ended.count, 1)
        XCTAssertTrue(activities.ended.first === activities.token, "the activity begun is the one ended")
        let stoppedAt = beats
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(beats, stoppedAt)
        emitter.stop()
        XCTAssertEqual(activities.ended.count, 1, "stopping twice ends nothing twice")
    }

    func test_realProcessInfoHoldsTheActivity() {
        let emitter = HeartbeatEmitter(interval: 60) { .active }
        emitter.start()
        emitter.stop()
        XCTAssertFalse(emitter.isRunning)
        XCTAssertEqual(HeartbeatEmitter.activityOptions, .userInitiatedAllowingIdleSystemSleep, "App Nap-proof, sleep still allowed")
    }

    /// A slider drag holds the run loop in tracking mode for as long as the user drags.
    func test_keepsBeatingWhileTheUserDragsASlider() {
        var beats = 0
        let emitter = HeartbeatEmitter(interval: 0.05) { beats += 1; return .active }
        emitter.start()
        defer { emitter.stop() }

        spinTrackingRunLoop(for: 0.4)

        XCTAssertGreaterThanOrEqual(beats, 3)
    }

    func test_defaultIntervalStaysInsideTheHelperTimeout() {
        XCTAssertEqual(HeartbeatEmitter.defaultInterval, 1)
        XCTAssertLessThan(HeartbeatEmitter.defaultInterval * 2, HelperConstants.heartbeatTimeout, "one late beat still arrives in time")
    }
}

@MainActor final class HelperInstallTests: XCTestCase {
    /// Never reaches SMAppService.register(): even a missing plist must not be registered from a test.
    func test_systemInstaller_reportsAMissingDaemon() {
        var opened = 0
        var registered: [SMAppService] = []
        let installer = SMAppServiceHelperInstaller(plistName: "com.ulm0.ventilador.missing.plist",
                                                    registerService: { registered.append($0); throw CocoaError(.fileNoSuchFile) },
                                                    openSettings: { opened += 1 })

        XCTAssertEqual(installer.status, .notFound)
        XCTAssertThrowsError(try installer.register())
        XCTAssertEqual(registered.count, 1)
        installer.openSystemSettings()
        XCTAssertEqual(opened, 1)
    }

    func test_systemInstaller_registersTheBundledDaemonService() throws {
        var registered: [SMAppService] = []
        let installer = SMAppServiceHelperInstaller(registerService: { registered.append($0) }, openSettings: {})

        try installer.register()

        XCTAssertEqual(registered.count, 1)
        XCTAssertEqual(HelperConstants.plistName, "com.ulm0.ventilador.helper.plist")
    }

    func test_installModel_enableFlowAndErrors() {
        let installer = MockHelperInstaller()
        let model = HelperInstallModel(installer: installer)
        XCTAssertEqual(model.status, .notRegistered)

        model.enable()
        XCTAssertEqual(model.status, .requiresApproval)
        XCTAssertNil(model.errorMessage)

        installer.registerError = FanControlError.helperRejected(message: "denied")
        model.enable()
        XCTAssertEqual(model.errorMessage, "denied")

        installer.registerError = nil
        model.enable()
        XCTAssertNil(model.errorMessage, "a later success clears the error")

        model.openSettings()
        XCTAssertEqual(installer.openCount, 1)

        installer.status = .enabled
        model.refresh()
        XCTAssertEqual(model.status, .enabled)
    }
}

@MainActor final class ManualControlModelTests: XCTestCase {
    func test_syncKeepsDraftsAcrossPollsAndTracksFanChanges() {
        let h = Harness(fans: [.stub(id: "0", currentRPM: 1500)])
        XCTAssertTrue(h.env.manual.rows.isEmpty)
        XCTAssertEqual(h.env.manual.allRange, 0...1)
        XCTAssertFalse(h.env.manual.showsBulkControl)

        h.status.refresh()
        h.env.manual.rows[0].draft = 3333
        h.smc.fans = [.stub(id: "0", currentRPM: 1800), .stub(id: "1", currentRPM: 2100)]
        h.status.refresh()

        XCTAssertEqual(h.env.manual.rows.map(\.draft), [3333, 2100], "in-progress draft kept, new fan starts at current speed")
        XCTAssertEqual(h.env.manual.allDraft, 1500, "set once, not reset by later polls")
        XCTAssertEqual(h.env.manual.rows[1].range, 1000...4900)
        XCTAssertTrue(h.env.manual.showsBulkControl)

        h.smc.fans = [.stub(id: "1", currentRPM: 2100)]
        h.status.refresh()
        XCTAssertEqual(h.env.manual.rows.map(\.id), ["1"], "a fan that disappears loses its row")
    }
}
