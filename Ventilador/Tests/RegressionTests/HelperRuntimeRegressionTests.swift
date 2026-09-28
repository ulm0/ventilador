@testable import Ventilador
import XCTest

/// The root helper's process wiring (HelperRuntime), exercised with an anonymous listener in-process.
/// SIGUSR2 stands in for SIGTERM so the test process survives.
@MainActor final class HelperRuntimeRegressionTests: XCTestCase {
    private struct Running {
        let smc: FakeSMCConnection
        let clock: TestClock
        let service: HelperService
        let listener: NSXPCListener
        let runtime: HelperRuntime
        func client() -> HelperClient { HelperClient { [listener] in NSXPCConnection(listenerEndpoint: listener.endpoint) } }
    }

    private func start(requirement: @escaping () -> String = { HelperConstants.clientRequirement(forAppAt: Bundle.main.bundleURL) },
                       tickInterval: TimeInterval? = 0.05, exit: @escaping () -> Void = {}) -> Running {
        let smc = FakeSMCConnection.appleSilicon()
        smc.set("F0Md", "ui8 ", 1) // left behind by a previous helper instance that died mid-override
        let clock = TestClock()
        let service = HelperService(controller: IOKitSMCController(connection: smc), clock: clock.read)
        let listener = NSXPCListener.anonymous()
        let runtime = tickInterval.map {
            HelperRuntime(service: service, listener: listener, clientRequirement: requirement, tickInterval: $0, terminationSignal: SIGUSR2, exit: exit)
        } ?? HelperRuntime(service: service, listener: listener, clientRequirement: requirement, terminationSignal: SIGUSR2, exit: exit)
        addTeardownBlock { runtime.stop() }
        return Running(smc: smc, clock: clock, service: service, listener: listener, runtime: runtime)
    }

    func test_runtime_resetsBeforeAcceptingClientsAndTicksTheWatchdogRepeatedly() throws {
        let r = start()
        XCTAssertEqual(r.smc.value("F0Md"), 0, "fans are back on automatic before any client can connect")

        let client = r.client()
        try client.setTargetRPM(fanID: "0", rpm: 3000)
        XCTAssertEqual(r.smc.value("F0Md"), 1, "the app that ships the helper is accepted")

        RunLoop.current.run(until: Date().addingTimeInterval(0.3)) // several ticks inside the window
        XCTAssertTrue(r.service.overrideActive)

        r.clock.advance(10)
        XCTAssertTrue(waitUntil(timeout: 2) { !r.service.overrideActive }, "the timer keeps ticking, not just once")
        XCTAssertEqual(r.smc.value("F0Md"), 0)
    }

    /// Production uses the default interval: it must tick every second (SC-003's budget).
    func test_runtime_defaultTickIntervalIsOneSecond() throws {
        let r = start(tickInterval: nil)
        try r.client().setTargetRPM(fanID: "0", rpm: 3000)
        r.clock.advance(10)

        XCTAssertTrue(waitUntil(timeout: 1.8) { !r.service.overrideActive })
        XCTAssertEqual(HelperRuntime.tickInterval, 1)
    }

    /// SAFETY-2 / PLATFORM-1: switching the helper off (launchd sends SIGTERM) reverts before exiting.
    func test_runtime_revertsOnTerminationThenExits() throws {
        var exits = 0
        let r = start(exit: { exits += 1 })
        let client = r.client()
        try client.setTargetRPM(fanID: "0", rpm: 3000)

        kill(getpid(), SIGUSR2)

        XCTAssertTrue(waitUntil(timeout: 2) { exits == 1 })
        XCTAssertEqual(r.smc.value("F0Md"), 0)
        XCTAssertFalse(r.service.overrideActive)
        XCTAssertEqual(r.client().heartbeat(), .helperUnreachable, "no new clients once stopping")
    }

    /// PLATFORM-2: a process that isn't the shipping app can't command the root helper.
    func test_runtime_rejectsClientsThatDontMatchTheRequirement() {
        let r = start(requirement: { HelperConstants.denyAllRequirement })
        let client = r.client()

        XCTAssertEqual(client.heartbeat(), .helperUnreachable)
        XCTAssertThrowsError(try client.setTargetRPM(fanID: "0", rpm: 3000))
        XCTAssertEqual(r.smc.value("F0Md"), 0)
    }

    /// FRESH-5: the requirement is evaluated per connection, so a rebuilt app is accepted without a helper restart.
    func test_runtime_evaluatesTheRequirementForEveryNewConnection() throws {
        var allow = false
        let r = start(requirement: { allow ? HelperConstants.clientRequirement(forAppAt: Bundle.main.bundleURL) : HelperConstants.denyAllRequirement })
        XCTAssertEqual(r.client().heartbeat(), .helperUnreachable)

        allow = true

        XCTAssertNoThrow(try r.client().setTargetRPM(fanID: "0", rpm: 3000))
    }

    func test_clientRequirementPinsTheExactContainingApp() {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/com.ulm0.ventilador.helper")
        let app = HelperConstants.containingApp(ofHelperAt: helper)
        XCTAssertEqual(app?.standardizedFileURL, Bundle.main.bundleURL.standardizedFileURL)
        XCTAssertNil(HelperConstants.containingApp(ofHelperAt: nil))

        // Ad-hoc path: the containing app's designated requirement.
        let requirement = HelperConstants.clientRequirement(forAppAt: app, helperTeam: nil)
        XCTAssertNotEqual(requirement, HelperConstants.denyAllRequirement)
        XCTAssertTrue(requirement.contains("cdhash") || requirement.contains("certificate leaf"), "pinned to this build or this team, never identifier alone: \(requirement)")

        XCTAssertEqual(HelperConstants.clientRequirement(forAppAt: nil, helperTeam: nil), HelperConstants.denyAllRequirement)
        XCTAssertEqual(HelperConstants.clientRequirement(forAppAt: URL(fileURLWithPath: "/nonexistent/App.app"), helperTeam: nil),
                       HelperConstants.denyAllRequirement)
    }

    /// FRESH-6: a Team-ID-signed helper trusts only its own team's app, whatever binary sits on disk.
    func test_clientRequirementPinsTheHelpersTeamWhenSigned() {
        XCTAssertEqual(HelperConstants.clientRequirement(forAppAt: nil, helperTeam: "ABCDE12345"),
                       "anchor apple generic and identifier \"\(HelperConstants.appBundleIdentifier)\" and certificate leaf[subject.OU] = \"ABCDE12345\"")
        let team = HelperConstants.ownTeamIdentifier()
        XCTAssertTrue(team == nil || team?.count == 10, "nil when ad-hoc signed, else a 10-character Team ID: \(team ?? "nil")")
    }

    /// The requirement the real, team-signed app gets is one it satisfies (checked by the runtime tests above
    /// through a live XPC connection); a different team is refused.
    func test_runtime_refusesAnotherTeam() {
        let r = start(requirement: { HelperConstants.clientRequirement(forAppAt: nil, helperTeam: "ZZZZZZZZZZ") })
        XCTAssertEqual(r.client().heartbeat(), .helperUnreachable)
    }
}
