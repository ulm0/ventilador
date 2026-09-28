@testable import Ventilador
import XCTest

/// spec.md User Story 1 — View Live Fan & Thermal Status (FR-001/002/003/009/011/012/013).
@MainActor final class LiveStatusRegressionTests: XCTestCase {
    // US1 Acceptance Scenario 1
    func test_liveStatus_displaysRPMAndTemperature() {
        let h = Harness(fans: [.stub(currentRPM: 1850)], temperatures: ["CPU": 62.4, "GPU": 48])
        XCTAssertEqual(h.status.state, .loading)
        XCTAssertEqual(StatusView(environment: h.env).sections, [.readingSensors])

        h.status.refresh()

        XCTAssertEqual(h.status.state, .ok)
        XCTAssertEqual(h.status.fans.map(\.currentRPM), [1850])
        XCTAssertEqual(h.status.temperatures.map(\.sourceLabel), ["CPU", "GPU"])
        XCTAssertEqual(h.status.temperatures.first?.celsius, 62.4)
        XCTAssertEqual(h.store.mode.displayName, "Automatic", "FR-009: mode shown from the first poll")
        XCTAssertEqual(StatusView(environment: h.env).sections, [
            .fan(label: "Fan 1", value: "1850 RPM"),
            .temperature(label: "CPU", value: "62 °C"), .temperature(label: "GPU", value: "48 °C"),
            .manualControls, .profiles,
        ])
        render(StatusView(environment: h.env))
    }

    // US1 Acceptance Scenario 2
    func test_liveStatus_updatesOnLoadChange() {
        let h = Harness(fans: [.stub(currentRPM: 1200)], pollInterval: 0.05)
        h.status.start()
        defer { h.status.stop() }
        XCTAssertEqual(h.status.fans.first?.currentRPM, 1200)

        h.smc.fans = [.stub(currentRPM: 3200)]
        h.setTemperatures(["CPU": 88])

        XCTAssertTrue(waitUntil(timeout: 2) { h.status.fans.first?.currentRPM == 3200 }, "no user action needed to see new RPM")
        XCTAssertEqual(h.status.temperatures.first?.celsius, 88)
    }

    /// A slider drag or open menu holds the run loop in tracking mode; polling (and with it every
    /// fail-closed check) must keep running.
    func test_liveStatus_keepsPollingWhileTheUserDragsASlider() {
        let h = Harness(fans: [.stub(currentRPM: 1200)], pollInterval: 0.05)
        h.status.start()
        defer { h.status.stop() }

        h.smc.fans = [.stub(currentRPM: 2600)]
        spinTrackingRunLoop(for: 0.4)

        XCTAssertEqual(h.status.fans.first?.currentRPM, 2600)
    }

    func test_liveStatus_pollsOnceAndStopsCleanly() {
        let h = Harness(pollInterval: 0.1)
        h.status.start()
        h.status.start()
        XCTAssertTrue(h.status.isPolling)
        RunLoop.current.run(until: Date().addingTimeInterval(0.55))
        XCTAssertLessThanOrEqual(h.smc.readCount, 8, "a second start() must not add a second timer")

        h.status.stop()
        XCTAssertFalse(h.status.isPolling)
        let stoppedAt = h.smc.readCount
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(h.smc.readCount, stoppedAt, "stop() must end polling, not just forget the timer")
    }

    // US1 Acceptance Scenario 3 / FR-003
    func test_liveStatus_fanlessMacShowsUnsupported() {
        let h = Harness(fans: [], temperatures: ["CPU": 41])
        h.status.refresh()

        XCTAssertEqual(h.status.state, .noFans)
        XCTAssertTrue(h.status.fans.isEmpty)
        XCTAssertEqual(h.status.temperatures.count, 1, "temperatures still shown on a fanless Mac")
        XCTAssertEqual(StatusView(environment: h.env).sections, [.noFan, .temperature(label: "CPU", value: "41 °C")])
        render(StatusView(environment: h.env))
    }

    // FR-011
    func test_liveStatus_sensorFailureShowsErrorInsteadOfValues() {
        let h = Harness()
        h.status.refresh()
        h.smc.readError = .sensorUnavailable(detail: "I/O failure")

        h.status.refresh()

        XCTAssertEqual(h.status.state, .unavailable("Sensor data unavailable: I/O failure"))
        XCTAssertTrue(h.status.fans.isEmpty, "no stale values left on screen")
        XCTAssertTrue(h.status.temperatures.isEmpty)
        XCTAssertEqual(StatusView(environment: h.env).sections,
                       [.error("Sensor data unavailable: I/O failure"), .lastError("Sensor data unavailable: I/O failure")])
        render(StatusView(environment: h.env))
    }

    // FR-007/FR-011: temperatures fail while fans still read
    func test_liveStatus_temperatureFailureAloneStillFailsClosed() {
        let h = Harness()
        h.status.refresh()
        h.store.setManual(targets: ["0": 3000])
        h.smc.temperatureError = .sensorUnavailable(detail: "thermal keys unreadable")

        h.status.refresh()

        XCTAssertEqual(h.status.state, .unavailable("Sensor data unavailable: thermal keys unreadable"))
        XCTAssertEqual(h.store.mode, .automatic, "no override without thermal monitoring")
    }

    // FR-013 / Edge Case: stuck sensor
    func test_liveStatus_staleReadingIsTreatedAsUnavailable() {
        let h = Harness(temperatures: ["CPU": 60])
        h.setTemperatures(["CPU": 60], age: stalenessThreshold + 1)

        h.status.refresh()
        h.status.refresh()

        XCTAssertEqual(h.status.state, .unavailable("Sensor data unavailable: CPU reading is stale"))
        XCTAssertEqual(h.log.filter { $0.kind == .sensorError }.count, 1, "logged once per outage, not every poll")

        h.setTemperatures(["CPU": 60])
        h.status.refresh()
        XCTAssertEqual(h.status.state, .ok)
        XCTAssertNil(h.store.lastError, "recovery clears the error")

        h.setTemperatures(["CPU": 60], age: stalenessThreshold + 1)
        h.status.refresh()
        XCTAssertEqual(h.log.filter { $0.kind == .sensorError }.count, 2, "a second outage is a second entry")
    }

    func test_liveStatus_everySensorGroupIsCheckedForStaleness() {
        let h = Harness()
        h.smc.temperatures = [
            TemperatureReading(sourceLabel: "CPU", celsius: 60, readAt: h.clock.now),
            TemperatureReading(sourceLabel: "GPU", celsius: 50, readAt: h.clock.now - stalenessThreshold - 1),
        ]
        h.status.refresh()
        XCTAssertEqual(h.status.state, .unavailable("Sensor data unavailable: GPU reading is stale"))
    }

    func test_liveStatus_readingExactlyAtThresholdIsStillCurrent() {
        let h = Harness()
        h.setTemperatures(["CPU": 60], age: stalenessThreshold)
        h.status.refresh()
        XCTAssertEqual(h.status.state, .ok)
    }

    /// FR-013 through the real controller: frozen SMC values are detected, not re-stamped as fresh.
    func test_liveStatus_frozenSMCSensorsFailClosed() {
        let smc = FakeSMCConnection.appleSilicon()
        let clock = TestClock()
        let env = AppEnvironment(controller: IOKitSMCController(connection: smc, clock: clock.read), heartbeat: MockHeartbeat(),
                                 log: ControlEventLog(fileURL: temporaryLogURL()), installer: MockHelperInstaller(), clock: clock.read)
        env.status.refresh()
        XCTAssertEqual(env.status.state, .ok)

        clock.advance(3)
        smc.set("TB0T", "flt ", 31) // battery unchanged too: not change-tracked, never stale by itself
        env.status.refresh()
        XCTAssertEqual(env.status.state, .ok, "3 s of identical values is still inside the window")

        clock.advance(3)
        env.status.refresh()
        XCTAssertEqual(env.status.state, .unavailable("Sensor data unavailable: CPU reading is stale"))

        smc.set("Tp01", "flt ", 71)
        smc.set("Tg0f", "flt ", 56)
        env.status.refresh()
        XCTAssertEqual(env.status.state, .ok, "live values again")
    }

    // Edge Case: AppleSMC missing (e.g. a VM)
    func test_liveStatus_unsupportedHardwareExplainsInsteadOfCrashing() {
        let env = AppEnvironment.live(openConnection: { throw FanControlError.unsupportedHardware },
                                      helper: .privileged(machServiceName: "com.ulm0.ventilador.test.absent"), logURL: temporaryLogURL(),
                                      installer: MockHelperInstaller())
        env.status.refresh()
        XCTAssertEqual(env.status.state, .unavailable("This Mac's fan hardware is not supported."))
    }

    // FR-012
    func test_liveStatus_warnsWhenAnotherProcessDrivesTheFans() {
        let h = Harness()
        h.smc.hardwareManual = true

        h.status.refresh()
        h.status.refresh()

        XCTAssertTrue(h.store.conflictDetected)
        XCTAssertEqual(h.log.filter { $0.kind == .conflictDetected }.count, 1)
        XCTAssertEqual(StatusView(environment: h.env).sections.first, .conflict)
        render(StatusView(environment: h.env))

        h.smc.hardwareManual = false
        h.status.refresh()
        XCTAssertFalse(h.store.conflictDetected)
    }

    func test_liveStatus_ownOverrideIsNotReportedAsConflict() {
        let h = Harness()
        h.status.refresh()
        h.store.setManual(targets: ["0": 2000])
        h.status.refresh()
        XCTAssertTrue(h.smc.detectsConflictingController())
        XCTAssertFalse(h.store.conflictDetected)
    }

    /// Edge Case: never silently fight another controller during our own override.
    func test_liveStatus_anotherWriterDuringAnOverrideIsWarnedAndWeStepBack() {
        let h = Harness()
        h.status.refresh()
        h.store.setManual(targets: ["0": 2000])

        h.smc.foreignTargets = ["0": 4000]
        h.status.refresh()

        XCTAssertTrue(h.store.conflictDetected)
        XCTAssertEqual(h.store.mode, .automatic)
        XCTAssertFalse(h.heartbeat.isRunning)
        XCTAssertEqual(h.log.filter { $0.kind == .conflictDetected }.count, 1, "the conflict episode is on record")
        XCTAssertEqual(h.log.last?.detail, "Manual → Automatic (another process changed the fan speed)")
    }

    func test_liveStatus_anotherWriterOnAnyFanDuringAProfileIsCaught() {
        let h = Harness(fans: [.stub(id: "0", target: 1300), .stub(id: "1", target: 1300)], temperatures: ["CPU": 70])
        h.status.refresh()
        h.store.selectProfile("balanced")

        h.smc.foreignTargets = ["1": 4000]
        h.status.refresh()

        XCTAssertTrue(h.store.conflictDetected)
        XCTAssertEqual(h.store.mode, .automatic)
        XCTAssertEqual(h.log.last?.detail, "Balanced → Automatic (another process changed the fan speed)")
    }

    func test_liveStatus_readBackToleratesOneRPMOfQuantization() {
        let h = Harness()
        h.status.refresh()
        h.store.setManual(targets: ["0": 2000])

        h.smc.foreignTargets = ["0": 2001]
        h.status.refresh()
        XCTAssertEqual(h.store.mode, .manual(targets: ["0": 2000]), "1 RPM off is the SMC rounding, not another writer")

        h.smc.foreignTargets = ["0": 2002]
        h.status.refresh()
        XCTAssertEqual(h.store.mode, .automatic)
    }

    /// FRESH-1: the helper reverted (e.g. after sleep) and a poll noticed first — not "another process".
    func test_liveStatus_overrideEndedOutsideTheAppIsNotBlamedOnAnotherProcess() {
        let h = Harness(fans: [.stub(target: 1300)])
        h.status.refresh()
        h.store.setManual(targets: ["0": 3000])

        h.smc.simulateExternalRevert()
        h.status.refresh()

        XCTAssertEqual(h.store.mode, .automatic)
        XCTAssertFalse(h.store.conflictDetected)
        XCTAssertFalse(h.heartbeat.isRunning)
        XCTAssertEqual(h.store.lastError, "Fan control was returned to automatic by the system or the safety watchdog.")
        XCTAssertFalse(h.log.contains { $0.kind == .conflictDetected })
        XCTAssertEqual(h.log.last?.detail, "Manual → Automatic (returned to automatic outside the app)")
    }

    /// Stale "what we wrote" must never outlive the override it belongs to.
    func test_liveStatus_leavingAProfileForOneFanDoesNotRaiseAFalseConflict() {
        let h = Harness(fans: [.stub(id: "0", target: 1300), .stub(id: "1", target: 1400)], temperatures: ["CPU": 70])
        h.status.refresh()
        h.store.selectProfile("quiet")

        h.store.setManual(targets: ["0": 2500])
        h.status.refresh()

        XCTAssertEqual(h.store.mode, .manual(targets: ["0": 2500]), "fan 2 is on Apple's target again; that's not another writer")
        XCTAssertFalse(h.store.conflictDetected)
    }

    func test_liveStatus_aNewSmallerOverrideDoesNotInheritTheOldOnesTargets() {
        let h = Harness(fans: [.stub(id: "0", target: 1300), .stub(id: "1", target: 1400)])
        h.status.refresh()
        h.store.setManual(targets: ["0": 2000, "1": 2000])
        h.store.revertToAutomatic()

        h.store.setManual(targets: ["0": 2500])
        h.status.refresh()

        XCTAssertEqual(h.store.mode, .manual(targets: ["0": 2500]))
        XCTAssertFalse(h.store.conflictDetected)
    }
}
